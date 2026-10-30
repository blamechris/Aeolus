import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// A handshake, or a death notice, that reaches the client after the connection has moved on
/// ([#588](https://github.com/blamechris/Aeolus/issues/588)).
///
/// The client cannot tell which helper process a death notice is about, and one death produces
/// several: the interruption handler's, and a 4097 for each message in flight to the process that
/// died. Each test here builds one order in which a notice, or the handshake it emptied from the
/// slot, reaches the client late, and asks whether the connection the client is using survives
/// it. The orders are the executor's to pick, so each is held in place with one of `HelperClient`'s
/// suite holds, and the interruption handler is played by calling it, as
/// `HelperClientConnectionTests` plays libxpc. The clock is the harness's frozen one (#421), so no
/// deadline runs out unless a test moves it, and none does.
@Suite("A stale handshake or a late death notice leaves a live connection alone", .timeLimit(.minutes(1)))
struct HelperClientStaleHandshakeTests {

    /// An interruption handled after a handshake was put in the slot, and before its `hello` went
    /// out, leaves that handshake there, and the next caller joins it.
    ///
    /// Its `hello` goes after the interruption, so it reaches a process that outlived the death
    /// being reported, and nothing about it is stale. Emptied from the slot instead, it let the
    /// second caller start a second handshake, which negotiated the session. The first `hello`
    /// then reached that session and was refused ("the handshake has already completed on this
    /// connection"), and the refusal took the connection the second caller had been served on.
    /// The schedule is #587's reviewer's: the first handshake is held before its guard
    /// (`HelperClient`'s `handshakeStartHold`), and released once the second caller's relay has
    /// started, which means its choice of handshake is made.
    @Test("An interruption before a hello has gone leaves its handshake for the next caller")
    func anInterruptionBeforeTheHelloLeavesTheHandshakeInTheSlot() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let starts = FirstCallHeld()
        let relays = CallsCounted()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: harness.clock, holdingHandshakeRelays: { await relays.record() },
            holdingHandshakeStarts: { await starts.hold() })

        let first = Task { try await client.snapshot() }
        try await waitUntil(
            "the first handshake is held before its hello",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            let started = await starts.started
            let relayed = await relays.calls
            return started == 1 && relayed == 1
        }
        #expect(harness.arrivals.isEmpty, "a hello went out: \(harness.arrivals)")
        let generation = await client.currentGeneration
        await client.connectionWasInterrupted(generation)
        let interrupted = await client.health
        #expect(interrupted == .interrupted, "the health is \(interrupted)")

        let second = Task { try await client.snapshot() }
        try await waitUntil(
            "the second caller joined a handshake or started one",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await relays.calls == 2
        }
        await starts.release.signal()

        let firstOutcome = try await returnedOutcome(of: "the first caller") {
            try await first.value
        }
        let secondOutcome = try await returnedOutcome(of: "the second caller") {
            try await second.value
        }
        #expect(throws: Never.self, "the first caller was not served") {
            _ = try firstOutcome.get()
        }
        #expect(throws: Never.self, "the second caller was not served") {
            _ = try secondOutcome.get()
        }
        #expect(
            harness.arrivals.filter { $0 == "hello" }.count == 1,
            "the arrivals were \(harness.arrivals)")
        let health = await client.health
        #expect(health == .handshaken, "the health is \(health)")
        #expect(await client.currentGeneration == generation, "the connection was given up")
        #expect(harness.sessions.count == 1)
    }

    /// A 4097 for a `hello` sent to a process that died, reaching the client after the
    /// interruption handler's notice of the same death and after a newer handshake has been
    /// recorded, leaves that handshake and its connection alone. Its caller is told the helper
    /// restarted.
    ///
    /// The 4097 is a second notice of a death already counted. Counted again, it cleared the newer
    /// handshake, recorded with the replacement; and the first handshake's failure then took the
    /// connection, which was live and handshaken, and on which a lease could have been acquired in
    /// between. The first `hello` is held unanswered at the helper, the helper's side is killed,
    /// and the 4097 is held in the client before anything reads it (`HelperClient`'s
    /// `receivedHelloReplyHold`), until the second caller has been served.
    @Test("A late notice of a death a newer handshake followed leaves that handshake and connection")
    func aLateNoticeLeavesTheNewerHandshakeAndItsConnection() async throws {
        let firstHello = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(),
            holdingHandshakeReplies: HelloRepliesHeldInTurn(firstHello))
        let answers = FirstCallHeld()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: harness.clock, holdingReceivedHelloReplies: { await answers.hold() })

        let first = Task { try await client.snapshot() }
        try await waitUntil(
            "the first hello is held at the helper", timeout: StallTolerantWait.deliveryBudget
        ) {
            harness.arrivals == ["hello"] && harness.clock.sleepers == 1
        }
        let generation = await client.currentGeneration
        harness.killHelperSideOfEveryConnection()
        try await waitUntil(
            "the client heard the helper die, and holds the first hello's 4097",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            let health = await client.health
            let held = await answers.started
            return health == .interrupted && held == 1
        }
        #expect(await client.currentGeneration == generation, "an interruption moved it")

        let second = try await returnedOutcome(of: "the second caller") {
            try await client.snapshot()
        }
        #expect(throws: Never.self, "the second caller was not served") { _ = try second.get() }
        let handshaken = await client.health
        #expect(handshaken == .handshaken, "the health is \(handshaken)")

        await answers.release.signal()
        let firstOutcome = try await returnedOutcome(
            of: "the first caller, once its hello's 4097 is let go"
        ) { try await first.value }
        #expect(throws: HelperClientError.helperRestarted) { _ = try firstOutcome.get() }
        let health = await client.health
        #expect(health == .handshaken, "the health is \(health)")
        #expect(await client.negotiated != nil, "the newer handshake was cleared")
        #expect(await client.currentGeneration == generation, "the connection was given up")

        let third = try await returnedOutcome(of: "the third caller") {
            try await client.snapshot()
        }
        #expect(throws: Never.self, "the third caller was not served") { _ = try third.get() }
        #expect(
            harness.arrivals == [
                "hello", "hello", "hello→replied", "snapshot", "snapshot→replied", "snapshot",
                "snapshot→replied",
            ],
            "the arrivals were \(harness.arrivals)")
        #expect(harness.sessions.count == 2)
        await firstHello.signal()
    }

    /// A late first notice of a death before a `hello` was sent, handled after its reply arrived
    /// and before it was recorded, costs two calls and one reconnect, and nothing after them.
    ///
    /// This is the bounded failure #585 accepted, run as one sequence: the client cannot tell this
    /// notice from one of a death after the send, so it drops the reply, as it must for #585's
    /// wedge. The helper is alive, and has negotiated the dropped `hello`. So the first caller is
    /// told the helper restarted; the second caller's `hello` is refused, and the refusal takes
    /// the connection; and the third is served on a new one. The reply is held in the client
    /// (`receivedHelloReplyHold`) while the notice is handled, as #587's reviewer's probe held it.
    @Test("A late notice of a death before a hello costs two calls and one reconnect, and no more")
    func aLateNoticeOfAnEarlierDeathCostsOneReconnect() async throws {
        let harness = ClientListenerHarness(authority: RecordingFanAuthority())
        let replies = FirstCallHeld()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: harness.clock, holdingReceivedHelloReplies: { await replies.hold() })

        let first = Task { try await client.snapshot() }
        try await waitUntil(
            "the client has the first hello's reply in hand",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await replies.started == 1
        }
        let generation = await client.currentGeneration
        await client.connectionWasInterrupted(generation)
        await replies.release.signal()

        let firstOutcome = try await returnedOutcome(of: "the first caller") {
            try await first.value
        }
        #expect(throws: HelperClientError.helperRestarted) { _ = try firstOutcome.get() }

        let secondOutcome = try await returnedOutcome(of: "the second caller") {
            try await client.snapshot()
        }
        let refusal = #expect(throws: AeolusXPCFault.self) { _ = try secondOutcome.get() }
        if case .invalidParameter = refusal {
        } else {
            Issue.record("the second caller's hello was not refused: \(String(describing: refusal))")
        }
        let refused = await client.health
        #expect(refused == .refused, "the health is \(refused)")
        #expect(await client.currentGeneration != generation, "the refused connection was kept")

        let thirdOutcome = try await returnedOutcome(of: "the third caller") {
            try await client.snapshot()
        }
        #expect(throws: Never.self, "the third caller was not served") {
            _ = try thirdOutcome.get()
        }
        let health = await client.health
        #expect(health == .handshaken, "the health is \(health)")
        #expect(harness.sessions.count == 2)
        #expect(
            harness.arrivals == [
                "hello", "hello→replied", "hello", "hello→replied", "hello", "hello→replied",
                "snapshot", "snapshot→replied",
            ],
            "the arrivals were \(harness.arrivals)")
    }
}

/// Counts the calls of one of `HelperClient`'s suite holds, and holds none of them.
///
/// Run as `handshakeRelayHold`, `calls` is how many callers have joined a handshake or started
/// one.
private actor CallsCounted {

    private var count = 0

    var calls: Int { count }

    func record() { count += 1 }
}
