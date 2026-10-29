import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// A caller cancelled while it waits for its connection's handshake comes back at once, and the
/// handshake carries on without it ([#576](https://github.com/blamechris/Aeolus/issues/576)).
///
/// Every gated verb waits for its connection's one `hello`. Until #576 it waited on the shared
/// handshake task's `value`, and that task is the connection's rather than the caller's child, so
/// cancelling the caller did not end the wait: it stayed parked until the `hello` was answered or
/// its deadline ran out. Each test here holds the `hello` reply at the helper
/// (`holdingHandshakeReplies`), so the handshake is certainly unanswered when a caller is
/// cancelled, and the harness's clock is frozen (#421), so nothing but the test can run the
/// handshake's deadline out. A caller that comes back here came back because it was cancelled.
///
/// What each test leaves standing is as much its claim as what it ends. Cancelling a caller is not
/// a teardown (`HelperClient.translate(_:on:)`), and the handshake belongs to the connection.
@Suite("A caller cancelled while it waits for the handshake", .timeLimit(.minutes(1)))
struct HelperClientHandshakeCancellationTests {

    /// A caller parked behind an unanswered `hello` comes back with `CancellationError` when it is
    /// cancelled, and a second caller waiting on the same handshake is answered when the `hello`
    /// is.
    ///
    /// The cancelled caller is the one that started the handshake, so it is certainly parked on it
    /// once the `hello` has reached the helper: the `hello` is sent by the handshake task, which
    /// runs on the client's actor only after the caller that made it has suspended. Its claims are
    /// that it came back without the clock moving and that its `snapshot` was never sent. The
    /// second caller's claims are that the handshake it shares was neither cancelled nor repeated:
    /// it gets its snapshot over the same connection, behind the one `hello`.
    ///
    /// **Mutation:** revert `HelperClient.handshakenConnection()` to `defer { if self.generation
    /// == generation { handshake = nil } }` and `_ = try await task.value`, the code before #576.
    /// Run: red on the wait for the cancelled caller to come back, at 15 s, and on `messageCount`
    /// (3: the cancelled caller's `snapshot` went out once the `hello` was released). Every claim
    /// of the second caller stays green, because the old code never cancelled the handshake
    /// either; what changed is only whether the first caller can leave.
    ///
    /// **Mutation:** in the cancelled branch of `handshakenConnection()`, call `task.cancel()`
    /// before throwing, so that cancelling a caller cancels the handshake. Run: red on the second
    /// caller, which is handed the handshake's own `CancellationError` instead of a snapshot, and
    /// on `health`, `negotiated` and `messageCount` (1: the `hello` alone).
    @Test("A caller cancelled behind an unanswered hello comes back; the one beside it is served")
    func aCancelledCallerLeavesAndTheHandshakeServesTheOther() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client()

        let cancelled = Task { try await client.snapshot() }
        try await waitUntil(
            "the hello is held at the helper and its deadline is running",
            timeout: StallTolerantWait.deliveryBudget
        ) { harness.arrivals == ["hello"] && harness.clock.sleepers == 1 }
        let secondStarted = AsyncSignal()
        let second = Task { () -> SystemSnapshot in
            await secondStarted.signal()
            return try await client.snapshot()
        }
        try await secondStarted.wait()
        let frozenAt = harness.clock.now

        cancelled.cancel()
        let left = try await returnedOutcome(
            of: "the caller cancelled behind the held hello",
            afterCancelling: { await releaseHandshake.signal() },
            { try await cancelled.value })
        guard case .failure(let thrown) = left else {
            Issue.record("a caller cancelled behind an unanswered hello came back with a snapshot")
            return
        }
        #expect(thrown is CancellationError, "the cancelled caller was told \(thrown)")
        #expect(harness.clock.now == frozenAt, "the clock moved, so a deadline may have freed it")

        await releaseHandshake.signal()
        let answered = try await returnedOutcome(of: "the second caller, once hello is answered") {
            try await second.value
        }
        #expect(throws: Never.self, "the handshake it shared did not serve it") {
            _ = try answered.get()
        }
        #expect(harness.sessions.count == 1, "the connection was given up and another built")
        #expect(
            harness.arrivals.filter { $0 == "hello" } == ["hello"],
            "the arrivals were \(harness.arrivals)")
        #expect(await client.health == .handshaken)
        #expect(await client.negotiated != nil)

        let session = try #require(harness.sessions.first)
        let delivered = await session.messageCount
        #expect(
            delivered == 2,
            """
            the session saw \(delivered) messages. Two is the hello and the second caller's \
            snapshot; a third is the cancelled caller's snapshot, sent once the hello it had \
            stopped waiting for was answered.
            """)
    }

    /// A caller that arrives after the only waiter was cancelled joins the handshake still in
    /// flight, and sends no `hello` of its own.
    ///
    /// The cancelled caller must leave `handshake` where it was. The `hello` it names is still at
    /// the helper, so a later caller that found no handshake would send a second `hello` on the
    /// same connection, which the helper refuses for the connection's whole life, and a refused
    /// handshake takes its connection with it. The connection would go because a caller went.
    ///
    /// **Ordered by a round trip, not constructed**, and said so as `racingVerbsShareOneHandshake`
    /// says it. The late caller's task has started before the `hello` is released, and the
    /// handshake can finish only after the reply's whole IPC round trip and a hop onto the client's
    /// actor, which the late caller asked for first. If the late caller reached the actor after
    /// that instead, it would find the handshake finished and short-circuit, and the mutation below
    /// would survive that run.
    ///
    /// **Mutation:** in the cancelled branch of `handshakenConnection()`, clear `handshake` before
    /// throwing, as the `defer` it replaced did on every exit. Run: red on the late caller, which
    /// sends a second `hello` and is refused with `invalidParameter` ("the handshake has already
    /// completed on this connection"), on the arrivals, which hold two `hello`s, and on `health`.
    ///
    /// **Mutation:** the code before #576, as in the first test. Run: red on the wait for the
    /// cancelled caller alone, at 15 s; the late caller, started after the `hello` was released to
    /// end that wait, finds the handshake done.
    @Test("A caller arriving after the only waiter was cancelled joins the same hello")
    func aLateCallerJoinsTheHandshakeACancelledCallerLeft() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client()

        let cancelled = Task { try await client.snapshot() }
        try await waitUntil(
            "the hello is held at the helper and its deadline is running",
            timeout: StallTolerantWait.deliveryBudget
        ) { harness.arrivals == ["hello"] && harness.clock.sleepers == 1 }
        cancelled.cancel()
        let left = try await returnedOutcome(
            of: "the caller cancelled behind the held hello",
            afterCancelling: { await releaseHandshake.signal() },
            { try await cancelled.value })
        #expect(throws: CancellationError.self) { _ = try left.get() }

        let lateStarted = AsyncSignal()
        let late = Task { () -> SystemSnapshot in
            await lateStarted.signal()
            return try await client.snapshot()
        }
        try await lateStarted.wait()
        await releaseHandshake.signal()

        let answered = try await returnedOutcome(of: "the late caller, once hello is answered") {
            try await late.value
        }
        #expect(throws: Never.self, "the late caller was not served") { _ = try answered.get() }
        #expect(
            harness.arrivals.filter { $0 == "hello" } == ["hello"],
            "the arrivals were \(harness.arrivals)")
        #expect(harness.sessions.count == 1, "the connection was given up and another built")
        #expect(await client.health == .handshaken)
    }

    /// When the only waiter is cancelled, the handshake still runs: it holds its connection and
    /// its deadline until that deadline runs out, and then it ends.
    ///
    /// The design decision #576 left open, taken the conservative way. The handshake is not
    /// cancelled with its last waiter, because a handshake ended without a `HelloReply` costs its
    /// connection, and that would make a caller's cancellation a teardown. So after the caller
    /// leaves, the `hello`'s deadline is still the one running, the connection is the same one, and
    /// nothing has been published. When the test runs that deadline out, the handshake ends the way
    /// it would have with a caller there: the connection is discarded as `.unresponsive` and no
    /// deadline is left running. Nothing the handshake started outlives its deadline.
    ///
    /// **Mutation:** in the cancelled branch of `handshakenConnection()`, call `task.cancel()`
    /// before throwing. Run: red on `deadlinesRunning` (0), `sleepers`, `health`, which reads
    /// `.invalidated`, and the generation: the handshake ended with its last waiter and took the
    /// connection with it. The wait for `.unresponsive` then fails as well.
    ///
    /// **Mutation:** the code before #576, as in the first test. Run: red on the wait for the
    /// cancelled caller, at 15 s. That wait releases the `hello` to end it, so the handshake
    /// succeeds, and what follows reads a handshaken connection instead: red on `health`,
    /// `negotiated`, the wait for `.unresponsive` and the generation.
    @Test("A handshake whose only waiter was cancelled runs on to its own deadline")
    func aHandshakeWithNoWaiterRunsToItsDeadline() async throws {
        let releaseHandshake = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(), holdingHandshakeReplies: releaseHandshake)
        let client = harness.client()

        let cancelled = Task { try await client.snapshot() }
        try await waitUntil(
            "the hello is held at the helper and its deadline is running",
            timeout: StallTolerantWait.deliveryBudget
        ) { harness.arrivals == ["hello"] && harness.clock.sleepers == 1 }
        let generation = await client.currentGeneration
        cancelled.cancel()
        let left = try await returnedOutcome(
            of: "the caller cancelled behind the held hello",
            afterCancelling: { await releaseHandshake.signal() },
            { try await cancelled.value })
        #expect(throws: CancellationError.self) { _ = try left.get() }

        let running = await client.deadlinesRunning
        #expect(running == 1, "the hello's deadline is no longer running")
        #expect(harness.clock.sleepers == 1)
        let health = await client.health
        #expect(health == .idle, "the caller's cancellation moved the health to \(health)")
        #expect(await client.currentGeneration == generation, "the connection was given up")
        #expect(await client.negotiated == nil)

        harness.clock.advance(by: HelperClientDeadlines.handshakeVerb)
        // The default budget, not `deliveryBudget` (#592): this wait is the claim, and a budget
        // past the harness's backstop would let it run a late deadline out for the client.
        try await waitUntil("the handshake's deadline ran out and gave the connection up") {
            await client.health == .unresponsive
        }
        #expect(await client.deadlinesRunning == 0)
        #expect(await client.currentGeneration != generation)
        #expect(harness.sessions.count == 1)

        await releaseHandshake.signal()
    }
}
