import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// What `LeaseDriverPublisher.stream(of:add:remove:)` does when a stream ends (#514). Nothing in
/// the other suites reads either half, so a later edit could drop either and leave them green.
///
/// 1. **A stream that ends leaves.** Its termination handler takes the observer out of the
///    driver's publisher, on the driver's actor. Without that, every ended stream's continuation
///    stays registered, and every later transition yields to it.
/// 2. **The handler holds the driver weakly.** The driver holds the observer, and the observer
///    holds the handler, so a strong capture would make a cycle that keeps the driver alive while
///    its streams are open.
///
/// ## How the observers are counted
///
/// The publisher's dictionaries are `private`, and the driver's publisher is a `private`
/// property, so there is no count to call. `observerCounts(of:)` reads them by reflection, from
/// inside the driver's actor; `LeaseDriver.runningHeartbeat` notes that reflection reaches a
/// private property from any module. It adds no access to the driver's code, and **it fails
/// closed**: a renamed property makes the count `nil`, and every test requires one before it
/// claims anything, so a rename is a red here and never a count of zero.
///
/// ## The waits
///
/// Both positive waits (an observer leaving, a driver being freed) are steps counted, not time:
/// `pollWithinSteps(_:)` sleeps one short step at a time for at most `patience` of them. Nothing
/// can announce either event, so there is no event to wait on, and a fixed number of actor hops
/// would prove only an absence (`LeaseScene.settle()` says the same). A mutant that never does
/// either is a red after `patience` steps, not a hang; a runner's stall costs one step.
@Suite(
    "LeaseDriver — a stream that ends leaves, and the driver is held weakly",
    .timeLimit(.minutes(1)))
struct LeaseDriverStreamTerminationTests {

    /// Two streams, one of the states and one of the reports, are subscribed and then read by
    /// tasks that are cancelled. The count of observers must fall back to what the scene alone
    /// subscribed, and the scene's own observers must still be published to.
    ///
    /// **Mutation (P5, no removal):** in `LeaseDriverPublisher.stream(of:add:remove:)`, delete the
    /// `Task { await remove(driver, token) }` line. Run: red at `left == before` and at `after ==
    /// before`, with the two ended streams' observers still registered; the other test stays
    /// green. The same two assertions go red when the token handed to `remove` is a fresh `UUID()`
    /// (P5b), and when `stateUpdates()`'s or `reportUpdates()`'s own `remove` closure in
    /// `LeaseDriver.swift` does nothing (W2, W1), so the driver's wiring is pinned as well as the
    /// handler.
    @Test("Cancelling a stream's reader removes its observer, and a later transition adds none")
    func aCancelledReaderRemovesItsObserver() async throws {
        let scene = await LeaseScene()
        let before = try #require(await Self.observerCounts(of: scene.driver), Self.noSeam)

        let received = LeaseLedger()
        let readers = [
            Self.read(scene.driver.stateUpdates(), into: received, at: scene.clock) { .state($0) },
            Self.read(scene.driver.reportUpdates(), into: received, at: scene.clock) {
                .report($0)
            },
        ]
        // Each has the value now, which is yielded in the step that registers the observer.
        await received.waitFor { !$0.states.isEmpty && !$0.reports.isEmpty }
        let joined = try #require(await Self.observerCounts(of: scene.driver), Self.noSeam)
        try #require(
            joined == ObserverCounts(states: before.states + 1, reports: before.reports + 1),
            "the count did not see the two subscriptions: \(before), then \(joined)")

        for reader in readers { reader.cancel() }
        _ = await Self.pollWithinSteps {
            await Self.observerCounts(of: scene.driver) == before
        }
        let left = try #require(await Self.observerCounts(of: scene.driver), Self.noSeam)
        #expect(
            left == before, "the cancelled readers' observers are still registered: \(left)")

        // A later transition, through the observers that stayed. The scene's own are among them,
        // so this ends only if they are still being published to.
        await scene.take(try LeaseScene.target([0: 3000]))
        let after = try #require(await Self.observerCounts(of: scene.driver), Self.noSeam)
        #expect(
            after == before,
            "after a later transition the scene is not the only one registered: \(after)")
        await scene.finish()
    }

    /// A driver that nothing holds is freed while a reader still follows each of its streams.
    ///
    /// **Mutation (P6, strong capture):** in `stream(of:add:remove:)`, replace the handler
    /// `{ [weak driver] _ in guard let driver else { return } ... }` with `{ [driver] _ in ... }`.
    /// Run: red at `freed`, after `patience` steps; the other test stays green.
    ///
    /// **The streams are open on purpose.** With the readers cancelled, and their observers gone,
    /// before the driver was let go, P6 stayed green: the driver was freed. The cycle runs
    /// through the observer the driver holds, and by then none was left. So "after its streams
    /// end", as #514 words it, cannot tell P6 from the original.
    @Test("A driver that nothing holds is freed while its streams are open")
    func theDriverIsHeldWeakly() async {
        let subscribed = await Self.subscribeAndLetGo()
        let freed = await Self.pollWithinSteps { subscribed.driver == nil }
        #expect(
            freed, "the driver is still alive after \(Self.patience) steps, with its streams open")
        for reader in subscribed.readers { reader.cancel() }
    }

    // MARK: - Counting the observers

    /// How many observers `driver`'s publisher holds.
    struct ObserverCounts: Equatable, Sendable {
        let states: Int
        let reports: Int
    }

    static let noSeam = Comment(
        rawValue:
            "the observer count cannot be read: `LeaseDriver.publisher` or the publisher's observer"
            + " dictionaries were renamed or retyped, and this suite reads them by name")

    /// The observers `driver`'s publisher holds now, or `nil` if reflection does not find them.
    static func observerCounts(of driver: isolated LeaseDriver) -> ObserverCounts? {
        guard let publisher = Mirror(reflecting: driver).descendant("publisher") else { return nil }
        let mirror = Mirror(reflecting: publisher)
        guard
            let states = mirror.descendant("stateObservers")
                as? [UUID: AsyncStream<LeaseDriverState>.Continuation],
            let reports = mirror.descendant("reportObservers")
                as? [UUID: AsyncStream<LeaseDriverReport>.Continuation]
        else { return nil }
        return ObserverCounts(states: states.count, reports: reports.count)
    }

    // MARK: - Following a stream

    /// Reads `stream` into `received` on a task of its own, each element as `event` records it.
    /// The task ends when it is cancelled, as an iteration of an `AsyncStream` does.
    static func read<Element: Sendable>(
        _ stream: AsyncStream<Element>, into received: LeaseLedger, at clock: HandWoundClock,
        as event: @escaping @Sendable (Element) -> LeaseLedger.Event
    ) -> Task<Void, Never> {
        Task {
            for await element in stream { await received.record(event(element), at: clock.now) }
        }
    }

    /// A driver, a weak reference to it, and the readers of its two streams.
    ///
    /// **Holds the driver weakly**, so the only strong reference outside the driver's own
    /// objects is the one `subscribeAndLetGo()` drops when it returns.
    struct Subscribed: Sendable {
        private(set) weak var driver: LeaseDriver?
        let readers: [Task<Void, Never>]

        init(driver: LeaseDriver, readers: [Task<Void, Never>]) {
            self.driver = driver
            self.readers = readers
        }
    }

    /// Makes a driver over a fake helper, subscribes to both its streams, waits until each has the
    /// value now (so each observer is registered), and returns without the driver: this function
    /// holds the last strong reference, and its frame ends here.
    ///
    /// The driver is idle, so it has started no task that would hold it.
    static func subscribeAndLetGo() async -> Subscribed {
        let clock = HandWoundClock()
        let driver = LeaseDriver(
            control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()),
            holderDescription: LeaseScene.holder, clock: clock)
        let received = LeaseLedger()
        let readers = [
            Self.read(driver.stateUpdates(), into: received, at: clock) { .state($0) },
            Self.read(driver.reportUpdates(), into: received, at: clock) { .report($0) },
        ]
        await received.waitFor { !$0.states.isEmpty && !$0.reports.isEmpty }
        return Subscribed(driver: driver, readers: readers)
    }

    // MARK: - Waiting for a state of the world

    /// How many steps `pollWithinSteps(_:)` sleeps through before it gives up.
    static let patience = 2_000

    /// One step of `pollWithinSteps(_:)`.
    static let step: Duration = .milliseconds(1)

    /// Whether `holds` came true within `patience` steps of `step`, asking once after each.
    ///
    /// **The patience counts steps slept through, not elapsed time**, as
    /// `LeaseScene.firstFloor(since:)` does: a stall of the process spends one step however long
    /// it lasts. A correct driver never spends it, and ends the wait at the first `true`. A task
    /// cancelled mid-wait stops sleeping and answers once more.
    static func pollWithinSteps(_ holds: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<patience {
            if await holds() { return true }
            do { try await Task.sleep(for: step) } catch { break }
        }
        return await holds()
    }
}
