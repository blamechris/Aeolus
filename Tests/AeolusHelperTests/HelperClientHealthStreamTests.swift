import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// What `HelperClient.healthUpdates()` does in the steps that make a stream and end it (#532,
/// #541). `LeaseDriver` subscribes once per lease and cancels the subscription when the lease
/// ends, so this runs once per lease.
///
/// 1. **A stream that ends leaves**, whether it ends at once or after a long read. Its
///    termination handler takes the observer out of the client's `HealthSignal`, under its lock.
///    Without that, an ended stream kept its observer for good, and every later change of health
///    was yielded to it. `droppedStreamsLeaveNoObserver(_:)` drops thousands as they are made.
///    A stream ends when its last holder drops it, or when the task reading it is cancelled
///    while it waits on the stream. A reader cancelled while busy elsewhere has not ended it
///    yet: the observer is removed at that reader's next `next()`, which returns `nil` at once.
///    (Run on its own, a stream whose reader was cancelled during a blocking call had not
///    terminated 0.1 s later, and had after the reader read again.)
/// 2. **It joins and leaves synchronously (#541):** registered by the time `healthUpdates()`
///    returns, and gone by the time whatever drops it returns.
///    `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()`.
/// 3. **Nothing a stream holds reaches the client, or the observers.** The client holds the
///    observers, and each observer holds the handler, so a handler that held the client would make
///    a cycle that keeps a connection-owning actor alive while any of its streams is open, and one
///    that held the observers a cycle that keeps them alive after the client is gone.
///    `theClientIsHeldWeakly()` and `theObserversAreFreedWithTheClient()`.
///
/// No connection is made here. A stream of the health signal reaches the actor and nothing past
/// it, so the harness's listener is never dialled; it is there because it is how this target
/// builds a client.
///
/// ## How the observers are counted
///
/// `healthStreams` is `private` and the actor has no count to call. `observerCount(of:)` reads it
/// by reflection and asks it for its count (`HealthSignal.Streams.observerCount`, which is there
/// for this suite). That adds nothing to the client: `HelperClientAccessTests` pins every
/// non-private member of this actor, and a test-only property would be a member of the privilege
/// boundary's actor that exists for one suite. **It fails closed**: a renamed or retyped
/// `healthStreams` makes the count `nil`, and every read
/// here is a `#require`, so a rename is a red and never a count of zero. Each test that reads a
/// count also reads one that must be non-zero first, so a seam that read the wrong thing could
/// not pass by reading nothing.
///
/// ## The waits
///
/// Every wait is `waitUntil`, which polls at a fixed interval within a budget of run time, so a
/// runner's stall does not spend it and a mutant that never gets there is a red after the
/// budget, not a hang. Nothing announces any of the events, so there is no event to wait on. A
/// timeout is recorded as an issue, so a wait that runs out fails the test whatever follows it.
@Suite(
    "The XPC client's health stream: one that ends leaves, and the client is held weakly",
    .timeLimit(.minutes(1)))
struct HelperClientHealthStreamTests {

    /// Streams dropped as soon as they are made, `churned` of them. A stream that is dropped ends
    /// at once. Every observer must be gone once every stream has been dropped, and a stream held
    /// open throughout (the witness) must still be registered.
    ///
    /// **Two ways to drop them** (`Churn`), as in `LeaseDriverStreamTerminationTests`. Before #541
    /// each stream started two tasks, one to register and one to remove. Dropped where they are
    /// made, both were started one after the other from this test's task. Made on a task at `.low`
    /// and dropped here, the registrations were started from that task and the removals from this
    /// one. Each found the leak where the other did not. Before #532's fix, at 5,000 streams:
    ///
    /// | Build | Runs red | Dropped where made | Dropped above the maker's priority |
    /// |---|---|---|---|
    /// | debug | 10 of 10 | red in 10, with 279 to 399 left | red in none |
    /// | release | 10 of 10 | red in 10, with 254 to 381 left | red in none |
    /// | debug, pool of one thread | 10 of 10 | red in none | red in 10, with 211 to 1,059 left |
    /// | release, pool of one thread | 10 of 10 | red in none | red in 10, with 270 to 793 left |
    ///
    /// The pool of one thread is `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. The fix passed the same
    /// forty runs. Release is `-c release -Xswiftc -enable-testing`.
    ///
    /// **When to count.** Before #541, nothing announced that a dropped stream's registration had
    /// run, so the count first waits until this test's reference is the client's only strong one:
    /// the tasks that registered and removed each held the client until they ended. #534 added
    /// the poll after it, so that a removal task that held the client weakly, which would be
    /// correct code, could not end that wait with its removals still queued. A budget that runs
    /// out is a recorded issue, and the assertion reads the count that is left.
    ///
    /// Since #541 nothing is queued, and both waits end at their first check. They stay, so that a
    /// later design whose tasks hold the client is counted after them. They do not wait for a
    /// task that holds only the signal's observers: M1 below is counted before any of its tasks
    /// has run on a pool of one thread, and this test passes it there.
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` is what catches it.
    ///
    /// **Mutation (M1, #532's unordered tasks, put back):** in `HealthObservers.stream()`, wrap
    /// the registration in `Task { … }`, and the termination handler's removal in another. Run,
    /// debug, on the default pool: red at `after == joined` in 5 of 5, dropped where made in all 5
    /// and above the maker's priority in 2, each after the 20 s budget;
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` red in 5 of 5. On a pool of one
    /// thread: this test green in 5 of 5, and the join-and-leave test red in 5 of 5.
    ///
    /// Before #541, M1 was deleting `await registration.value` from the handler's task: red here
    /// in 20 of 20 debug and 10 of 10 release runs, and with the poll in 10 of 10, on the default
    /// pool and on one thread. R3, a removal task that held the client weakly, was green with the
    /// poll in 10 of 10 debug and 10 of 10 release runs, and M3, a `Task.yield()` in place of the
    /// order, was red in 20 of 20 debug runs. Neither has a counterpart now: there is no task.
    ///
    /// **Mutation (M4, a removal that takes every observer):** in `HealthObservers.stream()`,
    /// make the termination handler `$0.observers.removeAll()` in place of removing its own
    /// token. Run, debug: red at `after == joined` in 3 of 3, in both ways, with the witness gone.
    /// A count of the churned streams alone would have passed it, as the join-and-leave test,
    /// which has no witness, does.
    @Test(
        "Health streams dropped as they are made leave no observer, however their tasks run",
        arguments: Churn.allCases)
    func droppedStreamsLeaveNoObserver(_ churn: Churn) async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        var client = harness.client()
        let before = try #require(Self.observerCount(of: client), Self.noSeam)

        // The witness: a stream held open across the churn. Its first element is yielded in the
        // step that registers it, so once it arrives the count must have risen by one. That is
        // what shows the count counts.
        var witness = client.healthUpdates().makeAsyncIterator()
        let first = await witness.next()
        try #require(first == .idle, "the witness opened with \(String(describing: first))")
        let joined = try #require(Self.observerCount(of: client), Self.noSeam)
        try #require(
            joined == before + 1, "the count did not see the witness: \(before), then \(joined)")

        switch churn {
        case .droppedWhereMade:
            for _ in 0..<Self.churned { _ = client.healthUpdates() }
        case .droppedAboveTheirMakersPriority:
            await Self.dropStreams(madeAt: .low, of: client)
        }

        try await waitUntil(
            "nothing besides this test holds the client", timeout: Self.patience
        ) { isKnownUniquelyReferenced(&client) }
        try #require(
            isKnownUniquelyReferenced(&client),
            "something besides this test still holds the client, so the count would be read early")

        // Since #541 no task is started for a dropped stream, so nothing is queued and that wait
        // ends at its first check; it is no order on anything. A later design whose removals were
        // tasks that held the client weakly would have them queued when it ended, so the count is
        // polled for, and then read once more below.
        try await waitUntil(
            "every dropped stream's observer has been removed", timeout: Self.patience
        ) { Self.observerCount(of: client) == joined }

        let after = try #require(Self.observerCount(of: client), Self.noSeam)
        #expect(
            after == joined,
            """
            after \(Self.churned) streams were dropped, \(after) observers are registered; \
            only the witness should be, which makes \(joined)
            """)

        // The witness is used here, after the count, so it is open when the count is read. ARC
        // may otherwise end it at its last use above, and its observer would leave with it.
        withExtendedLifetime(witness) {}
    }

    /// A client that nothing holds is freed while one of its health streams is open.
    ///
    /// **The stream is open on purpose.** The cycle a strong capture makes runs through the
    /// observer the client holds, so it exists only while that observer is registered. A test
    /// that ended the stream before letting the client go would free it either way.
    ///
    /// **Mutation (M2, a handler that holds the client):** give `HealthObservers.stream()` a
    /// parameter `holding anchor: (any Sendable)?` that the termination handler captures
    /// strongly, pass it through `Streams.updates(holding:)`, and have `healthUpdates()` pass
    /// `self`. Run, debug: red in 3 of 3 here, at the wait, after its 20 s budget. Both cases of
    /// `droppedStreamsLeaveNoObserver(_:)` go red too, at its wait for the client to be held by
    /// the test alone, because the witness's handler now holds it. Before #541 the handler named
    /// the client, and the same red came from writing its `[weak self]` as `[self]`.
    ///
    /// **Mutation (M2F, the same on a stream that has already ended):** M2, and
    /// `continuation.finish()` after the handler is set. The handler runs inside the stream's
    /// initialiser and lets go of the client, so the client is freed however the handler holds
    /// it. Run, debug: red in 3 of 3, at the count `subscribeAndLetGo()` requires, with 0
    /// observers registered. Before that count was required, this test stayed green in 3 of 3:
    /// the `.idle` it also requires still arrives, because the registration yields it before the
    /// stream is finished. Before #541 the `.idle` was enough, since a registration that ran after
    /// the stream had ended yielded nothing.
    @Test("A client that nothing holds is freed while a health stream is open")
    func theClientIsHeldWeakly() async throws {
        let subscribed = try await Self.subscribeAndLetGo()
        try await waitUntil(
            "the client is freed with its health stream open", timeout: Self.patience
        ) { subscribed.client == nil }
        // Open until the wait is over, for the reason `droppedStreamsLeaveNoObserver` gives.
        withExtendedLifetime(subscribed.updates) {}
    }

    /// The observers of a client's health are freed with the client, while one of its health
    /// streams is open.
    ///
    /// `theClientIsHeldWeakly()` cannot see this. The termination handler of a stream names the
    /// observers, not the client, so a handler that held the observers strongly would make a
    /// cycle (the set holds each observer, each observer holds its handler, the handler holds the
    /// set) that leaves the client free and keeps the set, and everything in it, for as long as
    /// a stream stays open.
    ///
    /// **Mutation (A, a handler that holds the observers):** in `HealthObservers.stream()`, write
    /// the termination handler as `{ [self] _ in self.state.withLock { … } }` in place of
    /// `{ [weak self] _ in self?.state.withLock { … } }`. Run, debug, with `HealthSignalTests`:
    /// red in 5 of 5 at the wait, after its 20 s budget. The other 6 tests stay green,
    /// `theClientIsHeldWeakly()` among them. Before this test, A was green on all of them.
    @Test("A client's observers are freed with it, while a health stream is open")
    func theObserversAreFreedWithTheClient() async throws {
        let subscribed = try await Self.subscribeAndLetGo()
        try await waitUntil(
            "the client and its observers are freed with its health stream open",
            timeout: Self.patience
        ) { subscribed.client == nil && subscribed.observers.isFreed }
        // Open until the wait is over, for the reason `droppedStreamsLeaveNoObserver` gives.
        withExtendedLifetime(subscribed.updates) {}
    }

    /// Health streams made and held, then dropped, `held` of them, with the count read straight
    /// after each step and nothing awaited in between. Every observer must be registered by the
    /// time the streams have been made, and every one gone by the time they have been dropped.
    ///
    /// This is #541's contract, and the churn test does not see all of it: a removal left to a
    /// task is correct in the end, and the churn test, which polls, passes it. Here nothing
    /// waits. The test function is synchronous, and the count is read under `HealthSignal`'s lock
    /// without a hop (`observerCount(of:)`), so on a pool of one thread no task gets a turn
    /// between a step and its count. On the default pool a mutant's tasks can run on other
    /// threads in the meantime, so a red there is likely and not certain.
    ///
    /// **Mutation (M3, a removal left to a task, which is correct in the end):** in
    /// `HealthObservers.stream()`, wrap the termination handler's removal in `Task { … }`. Run,
    /// debug: red at `left == before` in 3 of 5 on the default pool and 3 of 3 on one thread. Every
    /// other test in this suite stays green.
    ///
    /// **Mutation (M2R, a registration left to a task):** wrap the registration in `Task { … }`.
    /// Run, debug: red at the count after the streams are made in 4 of 5 on the default pool and
    /// 3 of 3 on one thread. `droppedStreamsLeaveNoObserver(_:)` goes red too, dropped where made,
    /// in 5 of 5 on the default pool, and stays green on one thread.
    @Test(
        "A health stream registers in the step that makes it and leaves in the step that drops it")
    func aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt() throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        let before = try #require(Self.observerCount(of: client), Self.noSeam)

        do {
            let streams = (0..<Self.held).map { _ in client.healthUpdates() }
            let joined = try #require(Self.observerCount(of: client), Self.noSeam)
            #expect(
                joined == before + Self.held,
                "with \(Self.held) streams just made and held, \(joined) observers are registered")
            withExtendedLifetime(streams) {}
        }

        let left = try #require(Self.observerCount(of: client), Self.noSeam)
        #expect(
            left == before,
            "with every stream just dropped, \(left - before) of \(Self.held) are still registered")
    }

    /// How many streams `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` holds.
    static let held = 1_000

    // MARK: - Churning streams

    /// How `droppedStreamsLeaveNoObserver(_:)` makes its streams and drops them.
    enum Churn: CaseIterable, Sendable, CustomTestStringConvertible {
        /// Each stream is dropped by the statement that makes it, in the test's own task.
        case droppedWhereMade
        /// The streams are made on a task at `.low`, and dropped in the test's task.
        case droppedAboveTheirMakersPriority

        var testDescription: String {
            switch self {
            case .droppedWhereMade: "dropped where made"
            case .droppedAboveTheirMakersPriority: "dropped above their maker's priority"
            }
        }
    }

    /// How many streams `droppedStreamsLeaveNoObserver(_:)` makes and drops.
    static let churned = 5_000

    /// The budget of all three waits: the two in `droppedStreamsLeaveNoObserver(_:)` and the one
    /// in `theClientIsHeldWeakly()`. A correct client ends each wait at its first poll once the
    /// tasks have run, so this bounds only how long a mutant takes to go red. It is not
    /// `waitUntil`'s 5 s default because, in a full debug run of this target on the development
    /// machine, each test here took about 3.5 s, against a few milliseconds when this suite runs
    /// alone, and `HelperClientConnectionTests.theHealthStreamFollowsTheConnection()` took as
    /// long in the same run. It stays under the suite's one-minute time limit.
    static let patience: Duration = .seconds(20)

    /// `churned` health streams of one client's.
    struct Streams: Sendable {
        let streams: [AsyncStream<HelperConnectionHealth>]
    }

    /// Makes `churned` streams on a task at `priority`, and drops them in the caller's task. They
    /// come over in a stream, whose iteration ends when the caller is cancelled, so the wait for
    /// them is not a wait on a task's value.
    static func dropStreams(madeAt priority: TaskPriority, of client: HelperClient) async {
        let (made, maker) = AsyncStream.makeStream(of: Streams.self)
        Task(priority: priority) {
            maker.yield(Streams(streams: (0..<churned).map { _ in client.healthUpdates() }))
            maker.finish()
        }
        for await streams in made { _ = streams }
    }

    // MARK: - Counting the observers

    static let noSeam = Comment(
        rawValue:
            "the observer count cannot be read: `HelperClient.healthStreams` was renamed or"
            + " retyped, and this suite reads it by name")

    /// How many observers `client` holds now, or `nil` if reflection does not find them.
    ///
    /// **Synchronous, and off the client's actor.** The observers are under `HealthSignal`'s lock
    /// (#541), so reading them needs no hop. A read that hopped would also give any task a mutant
    /// left queued a turn to run before the count is taken, which is the one thing
    /// `aStreamJoinsAndLeavesInTheStepsThatMakeAndDropIt()` must not allow.
    static func observerCount(of client: HelperClient) -> Int? {
        let streams = Mirror(reflecting: client).descendant("healthStreams")
        return (streams as? HealthSignal.Streams)?.observerCount
    }

    // MARK: - Letting the client go

    /// A weak reference to a client, and an open health stream of its.
    struct Subscribed {
        weak var client: HelperClient?
        let updates: AsyncStream<HelperConnectionHealth>.Iterator
        /// The client's `HealthObservers`, which this file cannot name, held weakly.
        let observers: Weak
    }

    /// An object held weakly, so that the suite can ask whether it has been freed.
    final class Weak {
        private weak var object: AnyObject?

        init(_ object: AnyObject) { self.object = object }

        var isFreed: Bool { object == nil }
    }

    static let noObservers = Comment(
        rawValue:
            "the client's observers cannot be reached: `HelperClient.healthStreams` or"
            + " `HealthSignal.Streams.observers` was renamed or is no longer a class, and this"
            + " suite reads them by name")

    /// The `HealthObservers` of `client`'s signal, held weakly, or `nil` if reflection does not
    /// find a class instance there.
    ///
    /// **Nothing here outlives the call**: the reflected values are strong while the function
    /// runs and gone when it returns, so the reference it hands back is the weak one alone.
    static func weakObservers(of client: HelperClient) -> Weak? {
        guard
            let observers = Mirror(reflecting: client).descendant("healthStreams", "observers"),
            Mirror(reflecting: observers).displayStyle == .class
        else { return nil }
        return Weak(observers as AnyObject)
    }

    /// Makes a client, opens a health stream, reads its first element, requires its observer to
    /// be registered, and returns without the client: this function holds the last strong
    /// reference, and its frame ends here.
    ///
    /// **The first element must be `.idle`**, as the witness's is in
    /// `droppedStreamsLeaveNoObserver(_:)`, **and the observer must be registered.** A stream that
    /// had already ended would have run its handler, and the cycle a strong capture makes would be
    /// broken, so `theClientIsHeldWeakly()` would pass on a handler that holds the client
    /// strongly. Since #541 such a stream still answers `.idle`, which its registration yielded
    /// before it ended, so only the count tells it apart (M2F).
    static func subscribeAndLetGo() async throws -> Subscribed {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        var updates = client.healthUpdates().makeAsyncIterator()
        let first = await updates.next()
        try #require(first == .idle, "the stream opened with \(String(describing: first))")
        let registered = try #require(Self.observerCount(of: client), Self.noSeam)
        try #require(
            registered == 1,
            "\(registered) observers are registered, so a strong capture would make no cycle")
        let observers = try #require(Self.weakObservers(of: client), Self.noObservers)
        // It must point at an object that is alive while the client is, or a reflection that
        // handed back a copy would read as freed from the start.
        try #require(
            !observers.isFreed, "the client's observers are not reachable while it is held")
        return Subscribed(client: client, updates: updates, observers: observers)
    }
}
