import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// What `LeaseDriverPublisher.stream(of:add:remove:)` does when a stream ends (#514, #526).
/// Nothing in the other suites reads either half, so a later edit could drop either and leave
/// them green.
///
/// 1. **A stream that ends leaves**, whether it ends after its observer is registered or before.
///    Its termination handler takes the observer out of the driver's publisher, on the driver's
///    actor, once the registration has run. Without that, every ended stream's continuation
///    stays registered, and every later transition yields to it.
///    `aCancelledReaderRemovesItsObserver()` ends streams that have registered.
///    `droppedStreamsLeaveNoObserver(_:)` drops streams as they are made, so many end first.
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
/// closed**: a renamed property makes the count `nil`, and every test that reads a count requires
/// one before it claims anything, so a rename is a red there and never a count of zero.
/// `theDriverIsHeldWeakly()` reads no count.
///
/// ## The waits
///
/// The positive waits (an observer leaving, a driver being freed, a driver held by its test
/// alone) are steps counted, not time: `pollWithinSteps(_:)` and `untilOnlyTheCallerHolds(_:)`
/// sleep one short step at a time for at most `patience` of them. Nothing can announce any of
/// these, so there is no event to wait on, and a fixed number of actor hops would prove only an
/// absence (`LeaseScene.settle()` says the same). A mutant that never does one is a red after
/// `patience` steps, not a hang; a runner's stall costs one step.
@Suite(
    "LeaseDriver — a stream that ends leaves, and the driver is held weakly",
    .timeLimit(.minutes(1)))
struct LeaseDriverStreamTerminationTests {

    /// Two streams, one of the states and one of the reports, are subscribed and then read by
    /// tasks that are cancelled. The count of observers must fall back to what the scene alone
    /// subscribed, and the scene's own observers must still be published to.
    ///
    /// **Mutation (P5, no removal):** in `LeaseDriverPublisher.stream(of:add:remove:)`, delete the
    /// `await remove(driver, token)` line from the handler's task. Run: red at `left == before`, a
    /// `#require`, so the test ends there after `patience` steps (about 4 s here), with the two
    /// ended streams' observers still registered. `droppedStreamsLeaveNoObserver(_:)` goes red
    /// too, and `theDriverIsHeldWeakly()` stays green. The same assertion goes red when the token
    /// handed to `remove` is a fresh `UUID()` (P5b), and when `stateUpdates()`'s or
    /// `reportUpdates()`'s own `remove` closure in `LeaseDriver.swift` does nothing (W2, W1), so
    /// the driver's wiring is pinned as well as the handler.
    @Test("Cancelling a stream's reader removes its observer, and a later transition adds none")
    func aCancelledReaderRemovesItsObserver() async throws {
        let scene = await LeaseScene()
        let before = try #require(Self.observerCounts(of: scene.driver), Self.noSeam)

        let received = LeaseLedger()
        let readers = [
            Self.read(scene.driver.stateUpdates(), into: received, at: scene.clock) { .state($0) },
            Self.read(scene.driver.reportUpdates(), into: received, at: scene.clock) {
                .report($0)
            },
        ]
        // Each has the value now, which is yielded in the step that registers the observer.
        await received.waitFor { !$0.states.isEmpty && !$0.reports.isEmpty }
        let joined = try #require(Self.observerCounts(of: scene.driver), Self.noSeam)
        try #require(
            joined == ObserverCounts(states: before.states + 1, reports: before.reports + 1),
            "the count did not see the two subscriptions: \(before), then \(joined)")

        for reader in readers { reader.cancel() }
        _ = await Self.pollWithinSteps {
            Self.observerCounts(of: scene.driver) == before
        }
        let left = try #require(Self.observerCounts(of: scene.driver), Self.noSeam)
        try #require(
            left == before, "the cancelled readers' observers are still registered: \(left)")

        // A later transition, through the observers that stayed. The scene's own are among them,
        // so this ends only if they are still being published to.
        await scene.take(try LeaseScene.target([0: 3000]))
        let after = try #require(Self.observerCounts(of: scene.driver), Self.noSeam)
        #expect(
            after == before,
            "after a later transition the scene is not the only one registered: \(after)")
        await scene.finish()
    }

    /// A driver that nothing holds is freed while a reader still follows each of its streams.
    ///
    /// **Mutation (P6, strong capture):** in `stream(of:add:remove:)`, replace the handler
    /// `{ [weak driver] _ in guard let driver else { return } ... }` with `{ [driver] _ in ... }`.
    /// Run: red at `freed`, after `patience` steps; the other two tests stay green.
    ///
    /// **Mutation (M2, a registration that outlives `add`):** in `stream(of:add:remove:)`, have
    /// the registration's task sleep for an hour after `add`
    /// (`try? await Task.sleep(for: .seconds(3_600))`). The handler holds that task, and the task
    /// holds the driver. Run: red at `freed`; the other two tests go red too, at `left == before`
    /// and at `quiet`. So a registration's task that still held the driver after `add` is a red
    /// here.
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

    /// Streams dropped as soon as they are made, `churned` of each kind. A stream that is dropped
    /// ends at once, often before the task that registers its observer has run. Every observer
    /// must be gone once every task the streams started has ended.
    ///
    /// **Two ways to drop them** (`Churn`). Dropped where they are made, each stream's two tasks
    /// are started one after the other from this test's task. Made on a task at `.low` and dropped
    /// here, the registrations are started from that task and the removals from this one. Each
    /// found the leak where the other did not. Before #526's fix, at 5,000 of each kind:
    ///
    /// | Build | Runs red | Dropped where made | Dropped above the maker's priority |
    /// |---|---|---|---|
    /// | debug | 10 of 10 | red in 10, with 98 to 457 of a kind left | red in 8 |
    /// | release | 10 of 10 | red in 10, with 235 to 351 of a kind left | red in 1 |
    /// | debug, pool of one thread | 5 of 5 | red in none | red in 5 |
    /// | release, pool of one thread | 5 of 5 | red in none | red in 5 |
    ///
    /// The pool of one thread is `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. The fix passed the same
    /// runs: 10 of 10 in each build, and 5 of 5 in each on one thread.
    ///
    /// **When to count.** Nothing announces that a dropped stream's registration has run, and a
    /// count taken before it ran would read the baseline on code that leaks. So the count first
    /// waits until this test's reference is the driver's only strong one
    /// (`untilOnlyTheCallerHolds(_:)`). The tasks that register and remove each hold the driver
    /// strongly until they end, and the termination handler holds it weakly, so today that is when
    /// every one of them has ended. Anything else that held the driver would run the wait out: a
    /// red at `quiet` (M2 shows it), never a count read early.
    ///
    /// **The count no longer rests on the removal tasks' capture; the wait still orders it after
    /// every registration (#534).** The registration tasks hold the driver strongly until they
    /// end, so the wait cannot end before they have run. A removal task that held the driver
    /// weakly would be correct code, and it would end that wait with its removals still queued.
    /// So the count is then polled for until it equals `before`, within `patience` steps, and
    /// only then asserted. A poll that runs out fails the assertion, which also reads the count
    /// that is left and names the budget, so a leak is a red either way. See R3 below.
    ///
    /// **Mutation (M1, unordered removal):** in `stream(of:add:remove:)`, delete
    /// `await registration.value` from the handler's task. Run: red at `after == before` in 5 of
    /// 5 debug runs, dropped where made in all 5 and above the maker's priority in 4; the other
    /// two tests stay green. Run again with the poll (#534), debug, 5 runs on the default pool and
    /// 5 on one thread: red in 10 of 10, each test taking about 4 to 5 s, because the poll runs
    /// its `patience` steps out.
    ///
    /// **Mutation (R3, a removal task that holds the driver weakly, which is correct code):** in
    /// `stream(of:add:remove:)`, make the handler's task `Task { [weak driver] in`, and take the
    /// driver out of it with `guard let driver else { return }` after `await registration.value`.
    /// The wait for the driver to be held by the test alone then ends with removals still queued.
    /// On a pool of one thread, before the poll: red at `after == before` in 1 of 15 debug runs
    /// and 4 of 10 release runs, each with all 5,000 observers of each kind counted. With the
    /// poll: green in 10 of 10 debug runs and 10 of 10 release runs. M1 is the leak the poll must
    /// still catch; R3 is the false failure it must not raise.
    @Test(
        "Streams dropped as soon as they are made leave no observer, however their tasks run",
        arguments: Churn.allCases)
    func droppedStreamsLeaveNoObserver(_ churn: Churn) async throws {
        let clock = HandWoundClock()
        var driver = LeaseDriver(
            control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()),
            holderDescription: LeaseScene.holder, clock: clock)
        let before = try #require(Self.observerCounts(of: driver), Self.noSeam)

        switch churn {
        case .droppedWhereMade:
            for _ in 0..<Self.churned {
                _ = driver.stateUpdates()
                _ = driver.reportUpdates()
            }
        case .droppedAboveTheirMakersPriority:
            await Self.dropStreams(madeAt: .low, of: driver)
        }
        let quiet = await Self.untilOnlyTheCallerHolds(&driver)
        try #require(
            quiet, "a dropped stream's task still holds the driver after \(Self.patience) steps")

        // That wait is not an order on the removals: a removal that holds the driver weakly is
        // still queued when it ends. So the counts are polled for, and then read once more below.
        // The copy is taken after the uniqueness check, which nothing repeats.
        let counted = driver
        let drained = await Self.pollWithinSteps {
            Self.observerCounts(of: counted) == before
        }

        let after = try #require(Self.observerCounts(of: counted), Self.noSeam)
        #expect(
            drained && after == before,
            """
            within \(Self.patience) steps the count \(drained ? "came" : "did not come") back \
            to \(before); read once more, dropped streams left \(after.states - before.states) \
            of \(Self.churned) state observers and \(after.reports - before.reports) of \
            \(Self.churned) report observers registered
            """)
    }

    /// Streams made and held, then dropped, `held` of each kind, with the count read straight
    /// after each step and nothing awaited in between. Every observer must be registered by the
    /// time the streams have been made, and every one gone by the time they have been dropped.
    ///
    /// This is #541's contract, and the churn test cannot see it. A registration or a removal
    /// left to a task would still be correct in the end, and the churn test, which polls, would
    /// pass it. Here nothing waits: the test function is synchronous, and the count is read under
    /// the publisher's lock without a hop (`observerCounts(of:)`), so no task gets a turn between
    /// a step and its count on a pool of one thread.
    @Test("A stream registers in the step that makes it and leaves in the step that drops it")
    func aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt() throws {
        let clock = HandWoundClock()
        let driver = LeaseDriver(
            control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()),
            holderDescription: LeaseScene.holder, clock: clock)
        let before = try #require(Self.observerCounts(of: driver), Self.noSeam)

        do {
            let streams = Streams(
                states: (0..<Self.held).map { _ in driver.stateUpdates() },
                reports: (0..<Self.held).map { _ in driver.reportUpdates() })
            let joined = try #require(Self.observerCounts(of: driver), Self.noSeam)
            #expect(
                joined
                    == ObserverCounts(
                        states: before.states + Self.held, reports: before.reports + Self.held),
                "with \(Self.held) of each kind just made and held, the count is \(joined)")
            withExtendedLifetime(streams) {}
        }

        let left = try #require(Self.observerCounts(of: driver), Self.noSeam)
        #expect(
            left == before,
            """
            with every stream just dropped, \(left.states - before.states) of \(Self.held) state \
            observers and \(left.reports - before.reports) of \(Self.held) report observers are \
            still registered
            """)
    }

    /// How many streams of each kind `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` holds.
    static let held = 1_000

    // MARK: - Churning streams

    /// How `droppedStreamsLeaveNoObserver(_:)` makes its streams and drops them.
    enum Churn: CaseIterable, Sendable, CustomTestStringConvertible {
        /// Each stream is dropped by the statement that makes it, in the test's own task.
        case droppedWhereMade
        /// The streams are made on a task at `.low`, and dropped in the test's task, which Swift
        /// Testing ran at `.medium` here.
        case droppedAboveTheirMakersPriority

        var testDescription: String {
            switch self {
            case .droppedWhereMade: "dropped where made"
            case .droppedAboveTheirMakersPriority: "dropped above their maker's priority"
            }
        }
    }

    /// How many streams of each kind `droppedStreamsLeaveNoObserver(_:)` makes and drops.
    static let churned = 5_000

    /// `churned` streams of each kind of `driver`'s.
    struct Streams: Sendable {
        let states: [AsyncStream<LeaseDriverState>]
        let reports: [AsyncStream<LeaseDriverReport>]
    }

    /// Makes `churned` streams of each kind on a task at `priority`, and drops them in the
    /// caller's task. They come over in a stream, whose iteration ends when the caller is
    /// cancelled, so the wait for them is not a wait on a task's value.
    static func dropStreams(madeAt priority: TaskPriority, of driver: LeaseDriver) async {
        let (made, maker) = AsyncStream.makeStream(of: Streams.self)
        Task(priority: priority) {
            maker.yield(
                Streams(
                    states: (0..<churned).map { _ in driver.stateUpdates() },
                    reports: (0..<churned).map { _ in driver.reportUpdates() }))
            maker.finish()
        }
        for await streams in made { _ = streams }
    }

    // MARK: - Counting the observers

    /// How many observers `driver`'s publisher holds.
    struct ObserverCounts: Equatable, Sendable {
        let states: Int
        let reports: Int
    }

    static let noSeam = Comment(
        rawValue:
            "the observer count cannot be read: `LeaseDriver.streams` was renamed or retyped, and"
            + " this suite reads it by name")

    /// The observers `driver`'s publisher holds now, or `nil` if reflection does not find them.
    ///
    /// **Synchronous, and off the driver's actor.** The observers are under the publisher's lock
    /// (#541), so reading them needs no hop. A read that hopped would also give any task a mutant
    /// left queued a turn to run before the count is taken, which is the one thing
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` must not allow.
    static func observerCounts(of driver: LeaseDriver) -> ObserverCounts? {
        guard
            let streams = Mirror(reflecting: driver).descendant("streams")
                as? LeaseDriverPublisher.Streams
        else { return nil }
        let counts = streams.observerCounts
        return ObserverCounts(states: counts.states, reports: counts.reports)
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

    /// Whether, within `patience` steps of `step`, `driver` came to be held by its caller alone.
    static func untilOnlyTheCallerHolds(_ driver: inout LeaseDriver) async -> Bool {
        for _ in 0..<patience {
            if isKnownUniquelyReferenced(&driver) { return true }
            do { try await Task.sleep(for: step) } catch { break }
        }
        return isKnownUniquelyReferenced(&driver)
    }
}
