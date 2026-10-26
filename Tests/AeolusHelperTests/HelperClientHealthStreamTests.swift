import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// What `HelperClient.healthUpdates()` does when a stream ends (#532). `LeaseDriver` subscribes
/// once per lease and cancels the subscription when the lease ends, so this runs once per lease.
///
/// 1. **A stream that ends leaves**, whether it ends after its observer is registered or before.
///    Its termination handler takes the observer out of `observers`, on the client's actor, once
///    the registration has run. Without that order, a stream that ended first kept its
///    observer for good, and every later change of health was yielded to it.
///    `droppedStreamsLeaveNoObserver(_:)` drops streams as they are made, so many end first.
/// 2. **The handler holds the client weakly.** The client holds the observer, and the observer
///    holds the handler, so a strong capture would make a cycle that keeps a connection-owning
///    actor alive while any of its streams is open. `theClientIsHeldWeakly()`.
///
/// No connection is made here. A stream of the health signal reaches the actor and nothing past
/// it, so the harness's listener is never dialled; it is there because it is how this target
/// builds a client.
///
/// ## How the observers are counted
///
/// `observers` is `private` and the actor has no count to call. `observerCount(of:)` reads the
/// dictionary by reflection, from inside the client's actor. That adds nothing to the client:
/// `HelperClientAccessTests` pins every non-private member of this actor, and a test-only
/// property would be a member of the privilege boundary's actor that exists for one suite.
/// **It fails closed**: a renamed or retyped `observers` makes the count `nil`, and every read
/// here is a `#require`, so a rename is a red and never a count of zero. Each test that reads a
/// count also reads one that must be non-zero first, so a seam that read the wrong thing could
/// not pass by reading nothing.
///
/// ## The waits
///
/// Both waits are `waitUntil`, which polls at a fixed interval within a budget of run time, so a
/// runner's stall does not spend it and a mutant that never gets there is a red after the
/// budget, not a hang. Nothing announces either event, so there is no event to wait on.
@Suite(
    "The XPC client's health stream: one that ends leaves, and the client is held weakly",
    .timeLimit(.minutes(1)))
struct HelperClientHealthStreamTests {

    /// Streams dropped as soon as they are made, `churned` of them. A stream that is dropped ends
    /// at once, often before the task that registers its observer has run. Every observer must
    /// be gone once every task the streams started has ended, and a stream held open throughout
    /// (the witness) must still be registered.
    ///
    /// **Two ways to drop them** (`Churn`), as in `LeaseDriverStreamTerminationTests`. Dropped
    /// where they are made, each stream's two tasks are started one after the other from this
    /// test's task. Made on a task at `.low` and dropped here, the registrations are started from
    /// that task and the removals from this one. Each found the leak where the other did not.
    /// Before #532's fix, at 5,000 streams:
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
    /// **When to count.** Nothing announces that a dropped stream's registration has run, and a
    /// count taken before it ran would read the baseline on code that leaks. So the count waits
    /// until this test's reference is the client's only strong one. The tasks that register and
    /// remove each hold the client strongly until they end, and the termination handler holds it
    /// weakly, so that is when every one of them has ended. Nothing is left to change the count
    /// then, so it is read once, not polled.
    ///
    /// **Mutation (M1, unordered removal):** in `HelperClient.healthUpdates()`, delete
    /// `await registration.value` from the handler's task. Run: red at `after == joined` in 20 of
    /// 20 debug runs, dropped where made in all 20 and above the maker's priority in 3, and in 10
    /// of 10 release runs, dropped where made in all 10. On a pool of one thread, debug, red in
    /// 10 of 10, above the maker's priority in all 10. `theClientIsHeldWeakly()` stays green.
    ///
    /// **Mutation (M3, a yield for the order):** replace that line with `await Task.yield()`.
    /// Run, debug: red at `after == joined` in 20 of 20, dropped where made, with 3 to 52 left.
    /// On a pool of one thread it passed 20 of 20, so a yield is not an order this test can rely
    /// on the one-thread pool to catch.
    ///
    /// **Mutation (M4, a removal that takes every observer):** in `stopObserving(_:)`, replace
    /// `observers[token] = nil` with `observers.removeAll()`. Run, debug: red at `after == joined`
    /// in 6 of 6, in both ways, with the witness gone. A count of the churned streams alone would
    /// have passed it.
    @Test(
        "Health streams dropped as they are made leave no observer, however their tasks run",
        arguments: Churn.allCases)
    func droppedStreamsLeaveNoObserver(_ churn: Churn) async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        var client = harness.client()
        let before = try #require(await Self.observerCount(of: client), Self.noSeam)

        // The witness: a stream held open across the churn. Its first element is yielded in the
        // step that registers it, so once it arrives the count must have risen by one. That is
        // what shows the count counts.
        var witness = client.healthUpdates().makeAsyncIterator()
        let first = await witness.next()
        try #require(first == .idle, "the witness opened with \(String(describing: first))")
        let joined = try #require(await Self.observerCount(of: client), Self.noSeam)
        try #require(
            joined == before + 1, "the count did not see the witness: \(before), then \(joined)")

        switch churn {
        case .droppedWhereMade:
            for _ in 0..<Self.churned { _ = client.healthUpdates() }
        case .droppedAboveTheirMakersPriority:
            await Self.dropStreams(madeAt: .low, of: client)
        }

        try await waitUntil(
            "every task the dropped streams started has ended", timeout: Self.patience
        ) { isKnownUniquelyReferenced(&client) }
        try #require(
            isKnownUniquelyReferenced(&client),
            "a dropped stream's task still holds the client, so the count would be read early")

        let after = try #require(await Self.observerCount(of: client), Self.noSeam)
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
    /// **Mutation (M2, strong capture):** in `healthUpdates()`, replace the handler's
    /// `{ [weak self] _ in guard let self else { return } ... }` with `{ [self] _ in ... }`. Run,
    /// debug: red in 3 of 3 here, at the wait, after its 20 s budget. Both cases of
    /// `droppedStreamsLeaveNoObserver(_:)` go red too, at its wait for the client to be held by
    /// the test alone, because the witness's handler now holds it.
    @Test("A client that nothing holds is freed while a health stream is open")
    func theClientIsHeldWeakly() async throws {
        let subscribed = await Self.subscribeAndLetGo()
        try await waitUntil(
            "the client is freed with its health stream open", timeout: Self.patience
        ) { subscribed.client == nil }
        // Open until the wait is over, for the reason `droppedStreamsLeaveNoObserver` gives.
        withExtendedLifetime(subscribed.updates) {}
    }

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

    /// The budget of both waits. A correct client ends either wait at its first poll once the
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
            "the observer count cannot be read: `HelperClient.observers` was renamed or retyped,"
            + " and this suite reads it by name")

    /// How many observers `client` holds now, or `nil` if reflection does not find them.
    static func observerCount(of client: isolated HelperClient) -> Int? {
        let observers = Mirror(reflecting: client).descendant("observers")
        return (observers as? [UUID: AsyncStream<HelperConnectionHealth>.Continuation])?.count
    }

    // MARK: - Letting the client go

    /// A weak reference to a client, and an open health stream of its.
    struct Subscribed {
        weak var client: HelperClient?
        let updates: AsyncStream<HelperConnectionHealth>.Iterator
    }

    /// Makes a client, opens a health stream and reads its first element (so its observer is
    /// registered), and returns without the client: this function holds the last strong
    /// reference, and its frame ends here.
    static func subscribeAndLetGo() async -> Subscribed {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let client = harness.client()
        var updates = client.healthUpdates().makeAsyncIterator()
        _ = await updates.next()
        return Subscribed(client: client, updates: updates)
    }
}
