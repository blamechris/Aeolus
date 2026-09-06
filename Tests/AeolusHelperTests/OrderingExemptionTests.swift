import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The other half of `MessageOrderingTests`: what per-connection ordering deliberately does
/// **not** cover, and what it must never be allowed to cover.
///
/// Ordering is a precondition — "every message sent earlier on this connection has
/// returned" — and two things in this design may not acquire one. The panic path, because
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) says it carries the fewest
/// preconditions of anything in the protocol, and a queue in front of it is a precondition
/// that is unbounded in exactly the state a user reaches for it in (`docs/SAFETY.md` § 4's
/// wedged `io_connect_t`). And another connection, because two connections are two clients
/// and one must never be able to delay the other.
///
/// Both were claims the diff did not stand behind: the panic verb was routed through the
/// sequencer with three documents saying it was exempt, and per-connection independence was
/// asserted of the `MessageSequencer` type rather than of `HelperXPCService`'s wiring — so
/// making the sequencer process-wide left the whole CI-runnable suite green.
@Suite("Ordering exemptions and per-connection isolation", .timeLimit(.minutes(2)))
struct OrderingExemptionTests {

    /// The panic path is answered while a message sent before it is still parked.
    ///
    /// `snapshot` parks in the authority and never returns until this test releases it, so
    /// a `restoreAllToAutomatic` that had to wait for its predecessor would never be
    /// answered at all and the `waitUntil` fails red on its deadline rather than on a
    /// timing margin. That is the shape the failure takes in production too — § 4's write
    /// that does not return is not slow, it is permanent.
    ///
    /// **Mutation:** in `HelperXPCService.restoreAllToAutomatic(reply:)`, replace
    /// `Task { … }` with `sequencer.enqueue { … }`. Run: red.
    @Test("The panic path is not delayed by a message parked before it")
    func thePanicPathIsNotDelayedByAParkedMessage() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let service = HelperXPCService(session: MessageOrderingFixtures.session(over: authority))
        let replies = OrderRecord<String>()

        try await MessageOrderingFixtures.handshake(on: service)

        service.snapshot { _, _ in replies.append("snapshot") }
        try await waitUntil("the parked message reached the authority") {
            await authority.hasBeenAsked
        }

        service.restoreAllToAutomatic { _ in replies.append("restoreAllToAutomatic") }

        try await waitUntil("the panic path was answered while the snapshot was parked") {
            replies.entries == ["restoreAllToAutomatic"]
        }
        #expect(
            await authority.hasRestored,
            "the panic path was answered without reaching the authority")

        await gate.signal()
        try await waitUntil("the parked message was answered too") { replies.entries.count == 2 }
        #expect(replies.entries == ["restoreAllToAutomatic", "snapshot"])
    }

    /// One connection's parked message does not delay another connection's.
    ///
    /// Two `HelperXPCService` instances, because that is what a connection is: the delegate
    /// mints one exported object per accepted connection, and the sequencer is its property.
    /// `MessageOrderingTests.separateSequencersRunIndependently` asserts the same property
    /// of two `MessageSequencer` values, which is a property of the *type* — it stays green
    /// when the wiring is changed to share one, and the wiring is where the hazard is.
    ///
    /// **Mutation:** on `HelperXPCService`, make the sequencer process-wide —
    /// `private static let shared = MessageSequencer()` with
    /// `private var sequencer: MessageSequencer { Self.shared }`. Run: red.
    @Test("A message parked on one connection does not delay another connection")
    func oneConnectionsParkedMessageDoesNotDelayAnother() async throws {
        let gate = AsyncSignal()
        let authority = GatedSnapshotAuthority(gate: gate)
        let connectionA = HelperXPCService(
            session: MessageOrderingFixtures.session(over: authority))
        let connectionB = HelperXPCService(
            session: MessageOrderingFixtures.session(over: authority))
        let replies = OrderRecord<String>()

        try await MessageOrderingFixtures.handshake(on: connectionA)

        connectionA.snapshot { _, _ in replies.append("A.snapshot") }
        try await waitUntil("A's message reached the authority") { await authority.hasBeenAsked }

        connectionB.hello(request: try helloPayload()) { _, _ in replies.append("B.hello") }

        try await waitUntil("B was answered while A was parked") {
            replies.entries == ["B.hello"]
        }

        await gate.signal()
        try await waitUntil("A was answered too") { replies.entries.count == 2 }
    }

    /// A client can confirm, from the handshake's own reply, that the helper it reached
    /// honours the ordering the contract states.
    ///
    /// It cannot consult this *before* pipelining — the reply carrying it is the round trip
    /// pipelining exists to skip — which is why the contract also names the fallback. What
    /// the string buys is the second connection and the next launch: a client that saw it
    /// once knows the optimisation is safe against this helper, and one that did not can
    /// stop paying for the retry path.
    ///
    /// Over the wire rather than against `HelperConnectionSession` directly, because the
    /// capability is only true of a session `HelperListenerDelegate` built: the parameter
    /// defaults to `[]`, so a test that passes the string in itself would assert nothing
    /// about the production wiring.
    ///
    /// **Mutation:** empty `HelperListenerDelegate.advertisedCapabilities`. Run: red.
    @Test("The handshake advertises the ordering guarantee as a capability")
    func theOrderingGuaranteeIsAdvertisedAsACapability() async throws {
        let authority = RecordingFanAuthority()
        let harness = AnonymousListenerHarness(authority: authority)

        let request = try helloPayload()
        let hello = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: request, reply: reply)
        }

        let decoded = try AeolusXPCCoding.decoder().decode(
            HelloReply.self, from: try #require(hello.payload))
        #expect(
            decoded.advertises("ordered-messages"),
            """
            the handshake advertised \(decoded.capabilities). A client that pipelines has \
            no other way to learn that the helper it reached is one that permits it.
            """)
    }
}
