import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The teardown gate: once `invalidate()` has crossed the seam, no further message reaches
/// the authority — with one deliberate exception.
///
/// ## What is being tested, and why the refusal is not it
///
/// Every assertion below is on `RecordingFanAuthority.calls`, never on the fault alone. A
/// gate that refused the client *and* dispatched anyway returns an identical refusal, and
/// dispatching is the entire defect: E5's authority would release everything held by a
/// `ConnectionID` and then be handed a fresh `acquireLease` bound to that same, already-torn
/// -down ID. The lease's connection-death teardown has already run for that connection and
/// will never run again, so [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md)'s two
/// independent paths silently become one.
///
/// These drive the actor directly rather than over a connection on purpose. The race the
/// gate closes — a message task and the invalidation task enqueueing on the actor in
/// unspecified order — cannot be *reliably* provoked through a real `NSXPCConnection`,
/// because whether libxpc delivers the message before the port dies is not under a test's
/// control. Calling `invalidate()` first pins the interleaving that matters, which is the
/// one where invalidation wins.
@Suite("The teardown gate")
struct ConnectionTeardownGateTests {

    private func session(authority: RecordingFanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Teardown")
        )
    }

    /// The refusal every gated message answers with once the connection has been torn down.
    private static let connectionGone = AeolusXPCFault.helperFailed(
        detail: "the connection has been invalidated")

    // MARK: - Refused after teardown

    /// **The scenario the gate exists for.** A client sends `acquireLease` and is
    /// `SIGKILL`ed; libxpc delivers the message, the kernel tears the port down, and the
    /// invalidation task wins the race onto the actor.
    ///
    /// The connection is handshaken first, so the refusal cannot be the handshake gate
    /// doing this test's work for it.
    @Test("acquireLease after invalidation never reaches the authority")
    func acquireLeaseAfterInvalidationIsNotDispatched() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let reply = await session.acquireLease(payload: try leasePayload())

        #expect(await authority.calls == [.connectionDidInvalidate(session.id)])
        #expect(reply.fault != .handshakeRequired, "the handshake gate is not what refused this")
        #expect(reply.fault == Self.connectionGone)
    }

    @Test("snapshot after invalidation never reaches the authority")
    func snapshotAfterInvalidationIsNotDispatched() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let reply = await session.snapshot()

        #expect(await authority.calls == [.connectionDidInvalidate(session.id)])
        #expect(reply.fault == Self.connectionGone)
    }

    @Test("renewLease after invalidation never reaches the authority")
    func renewLeaseAfterInvalidationIsNotDispatched() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let reply = await session.renewLease(id: UUID().uuidString)

        #expect(await authority.calls == [.connectionDidInvalidate(session.id)])
        #expect(reply.fault == Self.connectionGone)
    }

    /// The acknowledgement-shaped half of the gate. Split from the payload-shaped half in
    /// the source for the same reason the handshake gate is, so both need exercising.
    @Test("releaseLease after invalidation never reaches the authority")
    func releaseLeaseAfterInvalidationIsNotDispatched() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let reply = await session.releaseLease(id: UUID().uuidString)

        #expect(await authority.calls == [.connectionDidInvalidate(session.id)])
        #expect(reply.fault == Self.connectionGone)
    }

    @Test("apply after invalidation never reaches the authority")
    func applyAfterInvalidationIsNotDispatched() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let settings = try AeolusXPCCoding.encoder().encode(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000))])
        let reply = await session.apply(settings: settings, leaseID: UUID().uuidString)

        #expect(await authority.calls == [.connectionDidInvalidate(session.id)])
        #expect(reply.fault == Self.connectionGone)
    }

    /// `hello` reaches no authority, so this is not about dispatch. It is about the record:
    /// the invalidation log line has already been written, carrying this connection's
    /// handshake state and message count, and a handshake completing after it would leave a
    /// negotiated identity that no line in the log ever describes.
    @Test("hello after invalidation is refused and leaves the connection un-negotiated")
    func helloAfterInvalidationIsRefused() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        await session.invalidate()

        let reply = await session.hello(payload: try helloPayload())

        #expect(reply.fault == Self.connectionGone)
        #expect(await session.handshakeState == nil)
    }

    // MARK: - The panic-path exemption

    /// **The mirror, and it is a safety assertion rather than a completeness one.**
    ///
    /// `restoreAllToAutomatic` goes through a dying connection deliberately. Its only
    /// expressible effect is the safe state, so refusing it *because the connection is
    /// dying* would be a safety mechanism defeating safety — and a dying connection is
    /// exactly when the fans most need putting back. ADR 0005 requires the panic path to
    /// carry the fewest preconditions of anything in the protocol, and "the connection is
    /// still alive" is a precondition.
    ///
    /// The reply is very likely undeliverable by then. The effect is what is being asserted,
    /// which is why this checks the authority was reached rather than that the caller was
    /// told so.
    @Test("restoreAllToAutomatic still reaches the authority after invalidation")
    func restoreAllToAutomaticSurvivesTheTeardownGate() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        await session.invalidate()

        let reply = await session.restoreAllToAutomatic()

        #expect(reply.isSuccess)
        #expect(
            await authority.calls == [
                .connectionDidInvalidate(session.id),
                .restoreAllToAutomatic(session.id),
            ])
    }

    /// And it stays reachable however many times the connection is torn down, since
    /// `invalidate()` is idempotent and the exemption is not conditioned on the count.
    @Test("The panic path survives a repeated invalidation")
    func restoreAllToAutomaticSurvivesRepeatedInvalidation() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        await session.invalidate()
        await session.invalidate()

        let reply = await session.restoreAllToAutomatic()

        #expect(reply.isSuccess)
        #expect(await authority.invalidatedConnections == [session.id])
        #expect(
            await authority.calls.contains(.restoreAllToAutomatic(session.id)))
    }
}
