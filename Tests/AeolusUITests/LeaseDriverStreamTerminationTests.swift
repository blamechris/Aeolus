import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// What a lease driver's stream does in the steps that make it and end it (#514, #526, #541).
/// Nothing in the other suites reads any of it, so a later edit could break it and leave them
/// green.
///
/// 1. **A stream that ends leaves**, whether it ends at once or after a long read. Its
///    termination handler takes the observer out of the driver's publisher, under the
///    publisher's lock. Without that, every ended stream's continuation stays registered, and
///    every later transition yields to it. `aCancelledReaderRemovesItsObserver()` ends streams
///    that have been read. `droppedStreamsLeaveNoObserver(_:)` drops thousands as they are made.
///    A stream ends when its last holder drops it, or when the task reading it is cancelled
///    while it waits on the stream. A reader cancelled while busy elsewhere has not ended it
///    yet: the observer is removed at that reader's next `next()`, which returns `nil` at once.
///    (Run on its own, a stream whose reader was cancelled during a blocking call had not
///    terminated 0.1 s later, and had after the reader read again.)
/// 2. **It joins and leaves synchronously (#541):** registered by the time the call that makes it
///    returns, and gone by the time whatever drops it returns.
///    `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()`.
/// 3. **Nothing a stream holds reaches the driver, or the observers.** The driver holds the
///    observers, and each observer holds the handler, so a handler that held the driver would make
///    a cycle that keeps the driver alive while its streams are open, and one that held the
///    observers a cycle that keeps them alive after the driver is gone. `theDriverIsHeldWeakly()`
///    and `theObserversAreFreedWithTheirDriver()`.
///
/// ## How the observers are counted
///
/// The driver's `streams` is a `private` property, so there is no count to call on the driver.
/// `observerCounts(of:)` reads it by reflection and asks it for its counts
/// (`LeaseDriverPublisher.Streams.observerCounts`, which is there for this suite);
/// `LeaseDriver.runningHeartbeat` notes that reflection reaches a private property from any
/// module. It adds no access to the driver's code, and **it fails closed**: a renamed or retyped
/// property makes the count `nil`, and every test that reads a count requires one before it
/// claims anything, so a rename is a red there and never a count of zero.
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
    /// **Mutation (P5, no removal):** in `Followers.stream()` in `LeaseDriverPublisher.swift`,
    /// make the termination handler's body `_ = self` in place of the removal. Run, debug: red at
    /// `left == before`, a `#require`, in 3 of 3, so the test ends there after `patience` steps,
    /// with the two ended streams' observers still registered. Both cases of
    /// `droppedStreamsLeaveNoObserver(_:)` and `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()`
    /// go red too, and `theDriverIsHeldWeakly()` stays green.
    ///
    /// Before #541 the same assertion also went red when the token handed to `remove` was a fresh
    /// `UUID()` (P5b), and when `stateUpdates()`'s or `reportUpdates()`'s `remove` closure did
    /// nothing (W2, W1). Those closures are gone: the token never leaves `Followers.stream()`.
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
    /// **Mutation (P6, a handler that holds the driver):** give `Followers.stream()` a parameter
    /// `holding anchor: (any Sendable)?` that the termination handler captures strongly, pass it
    /// through `Streams.stateUpdates(holding:)` and `reportUpdates(holding:)`, and have the
    /// driver's `stateUpdates()` and `reportUpdates()` pass `self`. Run, debug: red at `freed` in
    /// 3 of 3; every other test here stays green. Before #541 the handler named the driver, and
    /// the same red came from writing its `[weak driver]` as `[driver]`.
    ///
    /// **Mutation (P6F, the same on a stream that has already ended):** P6, and
    /// `continuation.finish()` after the handler is set. The handler runs inside the stream's
    /// initialiser and lets go of the driver, so the driver is freed however the handler holds it.
    /// Run, debug: red in 3 of 3 at the count `subscribeAndLetGo()` checks, with no observer
    /// registered. `aCancelledReaderRemovesItsObserver()` and the join-and-leave test go red too,
    /// at their counts after subscribing. The first elements still arrive, because the
    /// registration yields them before the stream is finished, so waiting for them does not show
    /// that the streams are open.
    ///
    /// M2, a registration task that outlived its registration, was a red here before #541. There
    /// is no registration task now.
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

    /// The observers a driver's publisher holds are freed with the driver, while a reader still
    /// follows each of its streams.
    ///
    /// `theDriverIsHeldWeakly()` cannot see this. The termination handler of a stream names the
    /// observers, not the driver, so a handler that held the observers strongly would make a cycle
    /// (the set holds each observer, each observer holds its handler, the handler holds the set)
    /// that leaves the driver free and keeps the set, and everything in it, for as long as a
    /// stream stays open.
    ///
    /// **Mutation (A, a handler that holds the observers):** in `Followers.stream()`, write the
    /// termination handler as `{ [self] _ in self.state.withLock { … } }` in place of
    /// `{ [weak self] _ in self?.state.withLock { … } }`. Run, debug, with
    /// `LeaseDriverPublisherTests` and `LeaseDriverPublishOrderTests`: red in 5 of 5 at `freed`,
    /// after `patience` steps (about 4 s), with "the driver is freed and 2 of its 2 sets of
    /// observers are not". The other 9 tests stay green, `theDriverIsHeldWeakly()` among them.
    /// Before this test, A was green on all of them.
    @Test(
        "The observers of a driver that nothing holds are freed with it while its streams are open")
    func theObserversAreFreedWithTheirDriver() async throws {
        let subscribed = await Self.subscribeAndLetGo()
        try #require(
            subscribed.observers.count == 2,
            "reflection found \(subscribed.observers.count) of the publisher's 2 sets of observers")
        let freed = await Self.pollWithinSteps {
            subscribed.driver == nil && subscribed.observers.allSatisfy(\.isFreed)
        }
        #expect(
            freed,
            """
            after \(Self.patience) steps, with its streams open, the driver is \
            \(subscribed.driver == nil ? "freed" : "alive") and \
            \(subscribed.observers.filter { !$0.isFreed }.count) of its 2 sets of observers are not
            """)
        for reader in subscribed.readers { reader.cancel() }
    }

    /// Streams dropped as soon as they are made, `churned` of each kind. A stream that is dropped
    /// ends at once. Every observer must be gone once every stream has been dropped.
    ///
    /// **Two ways to drop them** (`Churn`). Before #541 each stream started two tasks, one to
    /// register and one to remove. Dropped where they are made, both were started one after the
    /// other from this test's task. Made on a task at `.low` and dropped here, the registrations
    /// were started from that task and the removals from this one. Each found the leak where the
    /// other did not. Before #526's fix, at 5,000 of each kind:
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
    /// **When to count.** Before #541, nothing announced that a dropped stream's registration had
    /// run, so the count first waits until this test's reference is the driver's only strong one
    /// (`untilOnlyTheCallerHolds(_:)`): the tasks that registered and removed each held the
    /// driver until they ended. #534 added the poll after it, so that a removal task that held the
    /// driver weakly, which would be correct code, could not end that wait with its removals still
    /// queued. A poll that runs out fails the assertion, which also reads the count that is left
    /// and names the budget.
    ///
    /// Since #541 nothing is queued, and both end at their first check. They stay, so that a later
    /// design whose tasks hold the driver is counted after them. They do not wait for a task that
    /// holds only the publisher's observers: M1 below is counted before any of its tasks has run on
    /// a pool of one thread, and this test passes it there.
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` is what catches it.
    ///
    /// **Mutation (M1, #526's unordered tasks, put back):** in `Followers.stream()`, wrap the
    /// registration in `Task { … }`, and the termination handler's removal in another. Run, debug,
    /// on the default pool: red at `drained && after == before` in 5 of 5, dropped where made in
    /// all 5 and above the maker's priority in 4, and
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` red in 5 of 5. On a pool of one
    /// thread: this test green in 5 of 5, and the join-and-leave test red in 5 of 5.
    ///
    /// Before #541, M1 was deleting `await registration.value` from the handler's task: red here
    /// in 5 of 5 debug runs, and with the poll in 10 of 10, on the default pool and on one thread.
    /// R3, a removal task that held the driver weakly, was green with the poll in 10 of 10 debug
    /// and 10 of 10 release runs. R3 has no counterpart now: there is no removal task.
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
            quiet, "something besides this test still holds the driver after \(Self.patience) steps"
        )

        // Since #541 no task is started for a dropped stream, so nothing is queued and that wait
        // ends at its first check; it is no order on anything. A later design whose removals were
        // tasks that held the driver weakly would have them queued when it ended, so the counts
        // are polled for, and then read once more below. The copy is taken after the uniqueness
        // check, which nothing repeats.
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
    /// This is #541's contract, and the churn test does not see all of it: a removal left to a
    /// task is correct in the end, and the churn test, which polls, passes it. Here nothing
    /// waits. The test function is synchronous, and the count is read under the publisher's lock
    /// without a hop (`observerCounts(of:)`), so on a pool of one thread no task gets a turn
    /// between a step and its count. On the default pool a mutant's tasks can run on other
    /// threads in the meantime, so a red there is likely and not certain.
    ///
    /// **Mutation (M3, a removal left to a task, which is correct in the end):** in
    /// `Followers.stream()`, wrap the termination handler's removal in `Task { … }`. Run, debug:
    /// red at `left == before` in 5 of 5 on the default pool and 3 of 3 on one thread. Every other
    /// test in this suite stays green.
    ///
    /// **Mutation (M2, a registration left to a task):** wrap the registration in `Task { … }`.
    /// Run, debug: red at the count after the streams are made in 5 of 5 on the default pool and
    /// 3 of 3 on one thread. `droppedStreamsLeaveNoObserver(_:)` goes red too, dropped where made,
    /// in 5 of 5 on the default pool, and stays green on one thread.
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
        /// The two sets of observers its publisher holds, one for each kind of stream, held
        /// weakly. Empty if reflection does not find them.
        let observers: [Weak]

        init(driver: LeaseDriver, readers: [Task<Void, Never>], observers: [Weak]) {
            self.driver = driver
            self.readers = readers
            self.observers = observers
        }
    }

    /// An object held weakly, so that the suite can ask whether it has been freed.
    ///
    /// `@unchecked Sendable`: it holds nothing strongly, and a `weak` load is atomic.
    final class Weak: @unchecked Sendable {
        private weak var object: AnyObject?

        init(_ object: AnyObject) { self.object = object }

        var isFreed: Bool { object == nil }
    }

    /// The two sets of observers `driver`'s publisher holds (`LeaseDriverPublisher`'s
    /// `Followers`, which this file cannot name), held weakly, or fewer than two if reflection
    /// does not find a class instance at either name.
    ///
    /// **Nothing here outlives the call**: the reflected values are strong while the function
    /// runs and gone when it returns, so the references it hands back are the weak ones alone.
    static func weakObservers(of driver: LeaseDriver) -> [Weak] {
        guard let streams = Mirror(reflecting: driver).descendant("streams") else { return [] }
        return ["states", "reports"].compactMap { name in
            guard let observers = Mirror(reflecting: streams).descendant(name),
                Mirror(reflecting: observers).displayStyle == .class
            else { return nil }
            return Weak(observers as AnyObject)
        }
    }

    /// Makes a driver over a fake helper, subscribes to both its streams, waits until each has the
    /// value now, checks that each observer is registered, and returns without the driver: this
    /// function holds the last strong reference, and its frame ends here.
    ///
    /// **The count is checked, not only the first elements.** A stream yields its first element
    /// as it registers, so a stream ended at once still hands it over. Its handler would have run
    /// by then, and the cycle a strong capture makes would be broken, so `theDriverIsHeldWeakly()`
    /// would pass on a handler that holds the driver strongly (P6F).
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
        let registered = Self.observerCounts(of: driver)
        #expect(
            registered == ObserverCounts(states: 1, reports: 1),
            "\(String(describing: registered)) registered, so a strong capture makes no cycle")
        // The weak references must point at objects that are alive while the driver is, or a
        // reflection that handed back a copy would read as freed from the start.
        let observers = Self.weakObservers(of: driver)
        #expect(
            observers.count == 2 && !observers.contains { $0.isFreed },
            "the driver's observers are not reachable while the driver is held")
        return Subscribed(driver: driver, readers: readers, observers: observers)
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
