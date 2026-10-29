import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient

/// A caller whose handshake was answered by a helper that then died, and that resumes only after
/// another caller has started the replacement's handshake
/// ([#582](https://github.com/blamechris/Aeolus/issues/582)).
///
/// An interruption keeps the connection and its generation and empties the handshake slot, so the
/// next caller starts a second handshake on the same connection, for the new process. A caller of
/// the first one that resumes after that met two defects, both older than #576: it cleared the new
/// handshake from the slot, and it sent its verb behind the new `hello` before that was answered.
/// When a caller resumes is the runtime's choice, so the first two tests hold the first caller's
/// relay (`HelperClient`'s `handshakeRelayHold`) until the schedule is built, and hold the second
/// `hello`'s reply at the helper (`HelloRepliesHeldInTurn`). The clock is the harness's frozen one
/// (#421), so no deadline runs out unless a test moves it, and none does.
///
/// The last two tests are another schedule in the same family, with a defect older than #582's:
/// the helper dies after it answers the first `hello`, and the client hears of the death before
/// it records the answer ([#585](https://github.com/blamechris/Aeolus/issues/585)). They hold the
/// reply in the client instead (`HelperClient`'s `receivedHelloReplyHold`), on the same frozen
/// clock.
@Suite("A caller whose handshake the dead helper answered", .timeLimit(.minutes(1)))
struct HelperClientHandshakeRestartTests {

    /// A late caller of the first handshake leaves the second one in the slot, so a third caller
    /// joins it rather than sending a third `hello`.
    ///
    /// The third caller's relay is started once it has joined the handshake in the slot or started
    /// one of its own, so the second `hello` is let go only after that choice is made. The choice
    /// is the claim: a third `hello` on the replacement's session is refused, a refused handshake
    /// takes its connection, and the second caller is told `connectionAbandoned`.
    ///
    /// What the first caller came back with is the next test's claim, not this one's.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, restore `if self.generation ==
    /// generation { handshake = nil }` for `if handshake == task { handshake = nil }`. Run: red on
    /// the third caller, refused with `invalidParameter` ("the handshake has already completed on
    /// this connection"), on the second, told `connectionAbandoned`, on the count of `hello`s
    /// (three), on the health (`.refused`) and on the generation. The other three tests stay
    /// green.
    @Test("A late caller of the first handshake does not clear the second from the slot")
    func aLateCallerLeavesTheNextHandshakeInTheSlot() async throws {
        let schedule = try await Self.lateCallerAfterTheHelperDied()
        let (harness, client) = (schedule.harness, schedule.client)
        let (first, second, secondHello) = (schedule.first, schedule.second, schedule.secondHello)

        await schedule.relays.release.signal()
        _ = try await returnedOutcome(
            of: "the first caller, once its relay is let go",
            afterCancelling: { await secondHello.signal() },
            { try await first.value })

        let third = Task { try await client.snapshot() }
        try await waitUntil(
            "the third caller joined a handshake or started one",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await schedule.relays.started == 3
        }
        await secondHello.signal()

        let thirdOutcome = try await returnedOutcome(of: "the third caller") {
            try await third.value
        }
        let secondOutcome = try await returnedOutcome(of: "the second caller") {
            try await second.value
        }
        #expect(throws: Never.self, "the third caller was not served") {
            _ = try thirdOutcome.get()
        }
        #expect(throws: Never.self, "the second caller was not served") {
            _ = try secondOutcome.get()
        }
        #expect(
            harness.arrivals.filter { $0 == "hello" }.count == 2,
            "the arrivals were \(harness.arrivals)")
        let health = await client.health
        #expect(health == .handshaken, "the health is \(health)")
        let generation = await client.currentGeneration
        #expect(generation == schedule.generation, "the connection was given up")
        #expect(harness.sessions.count == 2)
    }

    /// A late caller of the first handshake sends nothing behind the second `hello`, and is told
    /// the helper restarted.
    ///
    /// Its handshake succeeded, on the process that died. Nothing has been negotiated with the new
    /// one yet, so sending now would put its verb behind a `hello` that is not answered:
    /// pipelining, which this client never does (`HelperClient`'s own documentation). The arrivals
    /// are read while the second `hello` is still held, so a verb sent behind it is in them before
    /// that `hello`'s reply.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, delete the
    /// `if self.generation == generation, negotiatedReply == nil` check and its `throw`. Run: red
    /// on the first caller, which comes back with a snapshot, and on both readings of the
    /// arrivals: its `snapshot` arrived, and was answered, before the second `hello` was
    /// (`hello, hello→replied, hello, snapshot, snapshot→replied`). The slot test above and the
    /// 4097 test below stay green. The test of a reply its helper did not live to see recorded
    /// goes red too, on its first caller and both readings of its arrivals, because its
    /// `helperRestarted` comes from this same check.
    @Test("A late caller of the first handshake sends nothing behind the second hello")
    func aLateCallerSendsNothingBehindTheNextHello() async throws {
        let schedule = try await Self.lateCallerAfterTheHelperDied()
        let (harness, client) = (schedule.harness, schedule.client)
        let (first, second, secondHello) = (schedule.first, schedule.second, schedule.secondHello)

        await schedule.relays.release.signal()
        let firstOutcome = try await returnedOutcome(
            of: "the first caller, once its relay is let go",
            afterCancelling: { await secondHello.signal() },
            { try await first.value })
        #expect(throws: HelperClientError.helperRestarted) { _ = try firstOutcome.get() }
        #expect(
            harness.arrivals == ["hello", "hello→replied", "hello"],
            "the arrivals were \(harness.arrivals) with the second hello unanswered")

        await secondHello.signal()
        let secondOutcome = try await returnedOutcome(of: "the second caller") {
            try await second.value
        }
        #expect(throws: Never.self, "the second caller was not served") {
            _ = try secondOutcome.get()
        }
        #expect(
            harness.arrivals == [
                "hello", "hello→replied", "hello", "hello→replied", "snapshot", "snapshot→replied",
            ],
            "the arrivals were \(harness.arrivals)")
        let health = await client.health
        #expect(health == .handshaken, "the health is \(health)")
    }

    // MARK: - A reply the client has not recorded when it hears the helper died (#585)

    /// A `hello` reply from a helper that died before the client recorded it is never recorded.
    /// Its caller sends nothing and is told the helper restarted.
    ///
    /// The helper answers the first `hello` and dies, and the client hears of the death first. The
    /// reply and the interruption are both queued on the client's actor, and which runs first is
    /// the executor's choice, so the test holds the reply once the client has it, kills the
    /// helper's side, and lets the reply go only once the client reports `.interrupted`. Recorded
    /// then, the reply published `.handshaken` for a process that was gone, and every verb after it
    /// went to the replacement with no `hello` and was refused `handshakeRequired`, the first
    /// caller's included. Nothing tore the connection down, so nothing ended it.
    ///
    /// The claims: the first caller is told `helperRestarted` and its verb never arrives; the
    /// health stays `.interrupted`, with nothing negotiated; and the next caller handshakes with
    /// the replacement, on the same connection, and is served.
    ///
    /// **Mutation:** in `HelperClient.performHandshake(generation:)`, delete
    /// `guard interruptions == self.interruptions else { return reply }`. Run: red on the first
    /// caller (refused `handshakeRequired`), the health (`.handshaken`), `negotiated`, the arrivals
    /// (its `snapshot` reached the replacement), the next caller (refused `handshakeRequired`) and
    /// the arrivals after it. The other test of this schedule stays green. Deleting #582's
    /// restart check in `handshakenConnection()` instead turns this red on the first caller and
    /// both readings of the arrivals: the reply is not recorded, and the caller then sends its
    /// `snapshot` to the replacement with no `hello`.
    @Test("A hello reply from a helper that died before it was recorded is not recorded")
    func aReplyFromAHelperThatDiedFirstIsNotRecorded() async throws {
        let schedule = try await Self.replyHeldWhileTheHelperDied()
        let (harness, client, first) = (schedule.harness, schedule.client, schedule.first)

        await schedule.replies.release.signal()
        let firstOutcome = try await returnedOutcome(
            of: "the first caller, once its reply is let go"
        ) { try await first.value }
        #expect(throws: HelperClientError.helperRestarted) { _ = try firstOutcome.get() }
        let health = await client.health
        #expect(health == .interrupted, "the health is \(health)")
        #expect(await client.negotiated == nil, "the dead helper's reply was recorded")
        #expect(
            harness.arrivals == ["hello", "hello→replied"],
            "the arrivals were \(harness.arrivals)")

        let next = try await returnedOutcome(of: "the next caller") { try await client.snapshot() }
        #expect(throws: Never.self, "the next caller was not served") { _ = try next.get() }
        #expect(
            harness.arrivals == [
                "hello", "hello→replied", "hello", "hello→replied", "snapshot", "snapshot→replied",
            ],
            "the arrivals were \(harness.arrivals)")
        let healthAfter = await client.health
        #expect(healthAfter == .handshaken, "the health is \(healthAfter)")
        let generation = await client.currentGeneration
        #expect(generation == schedule.generation, "the connection was given up")
        #expect(harness.sessions.count == 2)
    }

    /// A connection whose `hello` a helper answered has spoken to a helper, even when the client
    /// heard of that helper's death before it recorded the answer.
    ///
    /// A 4097 on it is then `helperRestarted`, as it is when the answer was recorded first and the
    /// interruption cleared it. Read as `helperUnreachable`, the client would have told the first
    /// caller the helper restarted and would tell the next that it may not be installed, about the
    /// same helper. The 4097 is handed to `translate(_:on:)` directly, as
    /// `HelperClientTeardownTests` hands it a 4101: a message cannot be made to fail with one on
    /// demand.
    ///
    /// **Mutation:** in `HelperClient.performHandshake(generation:)`, move
    /// `hasEverHandshaken = true` below the `interruptions` guard. Run: red here alone, on
    /// `helperUnreachable(code: 4097)`. The other test of this schedule stays green: the first
    /// caller's `helperRestarted` comes from `handshakenConnection()`, which does not read
    /// `hasEverHandshaken`.
    @Test("A hello the dead helper answered still counts as having spoken to a helper")
    func aHelloTheDeadHelperAnsweredCountsAsAHelperSpokenTo() async throws {
        let schedule = try await Self.replyHeldWhileTheHelperDied()
        let first = schedule.first

        await schedule.replies.release.signal()
        _ = try await returnedOutcome(of: "the first caller, once its reply is let go") {
            try await first.value
        }
        let interrupted = NSError(domain: NSCocoaErrorDomain, code: XPCTransportCode.interrupted)
        let classified = await schedule.client.translate(interrupted, on: schedule.generation)

        #expect(
            classified as? HelperClientError == .helperRestarted,
            "a 4097 on this connection was read as \(classified)")
    }

    // MARK: - The schedule the first two tests build

    /// The point the first two tests start from.
    private struct LateCaller {
        let harness: ClientListenerHarness
        let client: HelperClient
        let relays: FirstCallHeld
        /// The caller that started the first handshake. Its relay is held.
        let first: Task<SystemSnapshot, Error>
        /// The caller that started the replacement's handshake, which is held at the helper.
        let second: Task<SystemSnapshot, Error>
        let secondHello: AsyncSignal
        let generation: UInt64
    }

    /// The first caller's handshake answered and its relay held; the helper's side killed; and a
    /// second caller's handshake on the replacement process held at the helper.
    ///
    /// Each step waits for the state the next one needs, so nothing here is raced. The interruption
    /// keeps the generation, and that is asserted rather than assumed: both defects turn on it.
    private static func lateCallerAfterTheHelperDied() async throws -> LateCaller {
        let firstHello = AsyncSignal()
        let secondHello = AsyncSignal()
        let harness = ClientListenerHarness(
            authority: RecordingFanAuthority(),
            holdingHandshakeReplies: HelloRepliesHeldInTurn(firstHello, secondHello))
        let relays = FirstCallHeld()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: harness.clock, holdingHandshakeRelays: { await relays.hold() })

        let first = Task { try await client.snapshot() }
        try await waitUntil(
            "the first hello is held at the helper, and its caller's relay too",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await relays.started == 1 && harness.arrivals == ["hello"]
                && harness.clock.sleepers == 1
        }
        await firstHello.signal()
        try await waitUntil(
            "the first handshake was answered", timeout: StallTolerantWait.deliveryBudget
        ) {
            await client.health == .handshaken
        }

        let generation = await client.currentGeneration
        harness.killHelperSideOfEveryConnection()
        try await waitUntil(
            "the client heard the helper die", timeout: StallTolerantWait.deliveryBudget
        ) {
            await client.health == .interrupted
        }
        #expect(await client.currentGeneration == generation, "an interruption moved it")

        let second = Task { try await client.snapshot() }
        try await waitUntil(
            "the replacement's hello is held at the helper",
            timeout: StallTolerantWait.deliveryBudget
        ) {
            await relays.started == 2 && harness.sessions.count == 2
                && harness.arrivals == ["hello", "hello→replied", "hello"]
                && harness.clock.sleepers == 1
        }
        return LateCaller(
            harness: harness, client: client, relays: relays, first: first, second: second,
            secondHello: secondHello, generation: generation)
    }

    // MARK: - The schedule the last two tests build

    /// The point the last two tests start from.
    private struct ReplyHeld {
        let harness: ClientListenerHarness
        let client: HelperClient
        let replies: FirstCallHeld
        /// The caller that started the handshake. The reply to its `hello` is held in the client.
        let first: Task<SystemSnapshot, Error>
        let generation: UInt64
    }

    /// The first `hello` answered and its reply held in the client, unrecorded; the helper's side
    /// killed; and the client told so.
    ///
    /// Each step waits for the state the next one needs. The interruption keeps the generation,
    /// and that is asserted rather than assumed: the defect turns on it.
    private static func replyHeldWhileTheHelperDied() async throws -> ReplyHeld {
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
        #expect(harness.arrivals == ["hello", "hello→replied"])
        let health = await client.health
        #expect(health == .idle, "the reply was recorded before it was let go: \(health)")
        #expect(await client.deadlinesRunning == 0, "the hello was answered, so no deadline runs")

        let generation = await client.currentGeneration
        harness.killHelperSideOfEveryConnection()
        try await waitUntil(
            "the client heard the helper die", timeout: StallTolerantWait.deliveryBudget
        ) {
            await client.health == .interrupted
        }
        #expect(await client.currentGeneration == generation, "an interruption moved it")
        return ReplyHeld(
            harness: harness, client: client, replies: replies, first: first,
            generation: generation)
    }
}

/// Holds the first call of one of `HelperClient`'s suite holds until `release` fires, lets every
/// later call through, and counts them all.
///
/// Run as `handshakeRelayHold`, it holds the first caller's relay, and `started` is how many
/// callers have joined a handshake or started one. Run as `receivedHelloReplyHold`, it holds the
/// first `hello`'s reply once the client has it, and `started` is how many replies have arrived.
private actor FirstCallHeld {

    let release = AsyncSignal()
    private var count = 0

    /// How many calls have started.
    var started: Int { count }

    func hold() async {
        count += 1
        guard count == 1 else { return }
        try? await release.wait()
    }
}
