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
/// When a caller resumes is the runtime's choice, so each test holds the first caller's relay
/// (`HelperClient`'s `handshakeRelayHold`) until the schedule is built, and holds the second
/// `hello`'s reply at the helper (`HelloRepliesHeldInTurn`). The clock is the harness's frozen one
/// (#421), so no deadline runs out unless a test moves it, and none does.
@Suite("A caller whose handshake the dead helper answered", .timeLimit(.minutes(1)))
struct HelperClientHandshakeAfterInterruptionTests {

    /// A late caller of the first handshake leaves the second one in the slot, so a third caller
    /// joins it rather than sending a third `hello`.
    ///
    /// The third caller's relay is started once it has joined the handshake in the slot or started
    /// one of its own, so the second `hello` is let go only after that choice is made. The choice
    /// is the claim: a third `hello` on the replacement's session is refused, a refused handshake
    /// takes its connection, and the second caller is told `connectionAbandoned`.
    ///
    /// What the first caller came back with is the other test's claim, not this one's.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, restore `if self.generation ==
    /// generation { handshake = nil }` for `if handshake == task { handshake = nil }`. Run: see
    /// the PR for #582.
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
        try await waitUntil("the third caller joined a handshake or started one") {
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
    /// one yet, so sending now would put its verb behind a `hello` that is not answered: pipelining,
    /// which this client never does (`HelperClient`'s own documentation). The arrivals are read
    /// while the second `hello` is still held, so a verb sent behind it is in them before its reply.
    ///
    /// **Mutation:** in `HelperClient.handshakenConnection()`, delete the
    /// `if self.generation == generation, negotiatedReply == nil` check and its `throw`. Run: see
    /// the PR for #582.
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

    // MARK: - The schedule both tests build

    /// The point both tests start from.
    private struct LateCaller {
        let harness: ClientListenerHarness
        let client: HelperClient
        let relays: FirstRelayHeld
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
        let relays = FirstRelayHeld()
        let client = HelperClient(
            transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
            clientDescription: "test client", deadlines: ClientListenerHarness.defaultDeadlines,
            clock: harness.clock, holdingHandshakeRelays: { await relays.hold() })

        let first = Task { try await client.snapshot() }
        try await waitUntil("the first hello is held at the helper, and its caller's relay too") {
            await relays.started == 1 && harness.arrivals == ["hello"]
                && harness.clock.sleepers == 1
        }
        await firstHello.signal()
        try await waitUntil("the first handshake was answered") {
            await client.health == .handshaken
        }

        let generation = await client.currentGeneration
        harness.killHelperSideOfEveryConnection()
        try await waitUntil("the client heard the helper die") {
            await client.health == .interrupted
        }
        #expect(await client.currentGeneration == generation, "an interruption moved it")

        let second = Task { try await client.snapshot() }
        try await waitUntil("the replacement's hello is held at the helper") {
            await relays.started == 2 && harness.sessions.count == 2
                && harness.arrivals == ["hello", "hello→replied", "hello"]
                && harness.clock.sleepers == 1
        }
        return LateCaller(
            harness: harness, client: client, relays: relays, first: first, second: second,
            secondHello: secondHello, generation: generation)
    }
}

/// Holds the first handshake relay a client starts until `release` fires, and counts every relay
/// that has started. The client runs it through `HelperClient`'s `handshakeRelayHold`.
private actor FirstRelayHeld {

    let release = AsyncSignal()
    private var count = 0

    /// How many relays have started, which is how many callers have joined a handshake or
    /// started one.
    var started: Int { count }

    func hold() async {
        count += 1
        guard count == 1 else { return }
        try? await release.wait()
    }
}
