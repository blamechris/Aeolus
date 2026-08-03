import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The handshake gate, exercised directly against the per-connection actor.
///
/// These run without a listener, a connection, or a privilege, which is what lets them
/// assert the thing a client cannot see: that the authority was **not called**. A gate
/// that refused the client and dispatched anyway would return an identical refusal.
@Suite("The handshake gate")
struct HandshakeGateTests {

    private func session(
        authority: RecordingFanAuthority,
        range: ProtocolVersionRange = AeolusXPCVersion.supportedRange
    ) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperRange: range,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Gate")
        )
    }

    // MARK: - Refused before the handshake

    @Test("snapshot is refused before hello, and never reaches the authority")
    func snapshotRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.snapshot()

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("acquireLease is refused before hello, and never reaches the authority")
    func acquireLeaseRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.acquireLease(payload: try leasePayload())

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("renewLease is refused before hello, and never reaches the authority")
    func renewLeaseRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.renewLease(id: UUID().uuidString)

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("releaseLease is refused before hello, and never reaches the authority")
    func releaseLeaseRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.releaseLease(id: UUID().uuidString)

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("apply is refused before hello, and never reaches the authority")
    func applyRefusedBeforeHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let settings = try AeolusXPCCoding.encoder().encode(
            [FanSetting(fanIndex: 0, control: .automatic)])
        let reply = await session.apply(settings: settings, leaseID: UUID().uuidString)

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    /// The gate is checked before the payload is looked at. A client that has not
    /// introduced itself learns `handshakeRequired` and nothing about how the helper
    /// parses payloads.
    @Test("A malformed payload before hello is still answered handshakeRequired")
    func malformedPayloadBeforeHandshakeIsGatedFirst() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.acquireLease(payload: Data("not json".utf8))

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    // MARK: - The panic-path exemption

    /// Exempt from the handshake gate — never from the authorisation gate, which is a
    /// different mechanism in a different layer. Its only expressible effect is the safe
    /// state, so a version fence in front of it would be a safety mechanism defeating
    /// safety.
    @Test("restoreAllToAutomatic is reachable before hello and does reach the authority")
    func restoreAllToAutomaticIsExemptFromTheGate() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.restoreAllToAutomatic()

        #expect(reply.isSuccess)
        #expect(await authority.calls == [.restoreAllToAutomatic(session.id)])
    }

    // MARK: - Version negotiation

    @Test("A client inside the supported range completes the handshake")
    func handshakeSucceedsInRange() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.hello(payload: try helloPayload())
        let data = try #require(reply.payloadData)
        let decoded = try AeolusXPCCoding.decoder().decode(HelloReply.self, from: data)

        #expect(decoded.helperProtocolRange == AeolusXPCVersion.supportedRange)
        #expect(await session.handshakeState?.protocolVersion == AeolusXPCVersion.current)
        #expect(await session.handshakeState?.clientDescription == "test client")
    }

    @Test("Once handshaken, a gated message reaches the authority")
    func gateOpensAfterHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        _ = await session.hello(payload: try helloPayload())
        let reply = await session.snapshot()

        #expect(reply.fault == nil)
        #expect(await authority.calls == [.snapshot])
    }

    /// Refuse, never degrade — and say enough that the client can name the fix rather
    /// than shrug.
    @Test("A client above the range is refused with both sides' ranges")
    func handshakeRefusesVersionAboveRange() async throws {
        let authority = RecordingFanAuthority()
        let range = ProtocolVersionRange(minimumSupported: 1, current: 1)
        let session = session(authority: authority, range: range)

        let reply = await session.hello(payload: try helloPayload(version: 3))

        #expect(reply.fault == .versionMismatch(clientVersion: 3, helperRange: range))
        #expect(await session.handshakeState == nil)
    }

    @Test("A client below the range is refused with both sides' ranges")
    func handshakeRefusesVersionBelowRange() async throws {
        let authority = RecordingFanAuthority()
        let range = ProtocolVersionRange(minimumSupported: 2, current: 4)
        let session = session(authority: authority, range: range)

        let reply = await session.hello(payload: try helloPayload(version: 1))

        #expect(reply.fault == .versionMismatch(clientVersion: 1, helperRange: range))
        #expect(await session.handshakeState == nil)
    }

    /// A refused handshake must not open the gate. Checked separately from the refusal
    /// itself because those are two different defects: telling the client the wrong thing,
    /// and letting it through anyway.
    @Test("A refused handshake leaves the gate shut")
    func refusedHandshakeLeavesGateShut() async throws {
        let authority = RecordingFanAuthority()
        let range = ProtocolVersionRange(minimumSupported: 1, current: 1)
        let session = session(authority: authority, range: range)

        _ = await session.hello(payload: try helloPayload(version: 9))
        let reply = await session.snapshot()

        #expect(reply.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    @Test("A malformed hello is refused and leaves the gate shut")
    func malformedHelloLeavesGateShut() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.hello(payload: Data("{".utf8))

        guard case .malformedPayload = try #require(reply.fault) else {
            Issue.record("expected malformedPayload, got \(String(describing: reply.fault))")
            return
        }
        #expect(await session.handshakeState == nil)
        #expect(await session.snapshot().fault == .handshakeRequired)
    }

    /// A client-chosen description that could forge a log entry is refused before it is
    /// ever recorded as this connection's identity.
    @Test("A hello carrying a control character in its description is refused")
    func helloWithControlCharacterIsRefused() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.hello(
            payload: try helloPayload(description: "fanctl\nDENIED: nothing to see"))

        #expect(
            reply.fault
                == .invalidParameter(
                    name: "clientDescription",
                    detail: "must not contain control or formatting characters"))
        #expect(await session.handshakeState == nil)
    }

    /// A connection has one negotiated identity and one negotiated version. Replacing
    /// either mid-life would leave the handshake line already in the log describing a
    /// client that no longer exists.
    @Test("A second hello on a handshaken connection is refused")
    func secondHelloIsRefused() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        _ = await session.hello(payload: try helloPayload(description: "first"))
        let reply = await session.hello(payload: try helloPayload(description: "second"))

        #expect(
            reply.fault
                == .invalidParameter(
                    name: "hello",
                    detail: "the handshake has already completed on this connection"))
        #expect(await session.handshakeState?.clientDescription == "first")
    }

    // MARK: - Validation split

    /// The listener narrows the `@objc` `String` back to a `UUID` before it reaches a
    /// lookup or a log line — and refuses rather than repairing, because an ID that is not
    /// a UUID names no lease this helper ever issued.
    @Test("A lease ID that is not a UUID is refused before the authority sees it")
    func nonUUIDLeaseIDIsRefusedAtTheListener() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())

        let reply = await session.renewLease(id: String(repeating: "z", count: 36))

        #expect(
            reply.fault
                == .invalidParameter(
                    name: "leaseID",
                    detail: "must be a UUID in canonical 36-character form"))
        #expect(await authority.calls.isEmpty)
    }

    /// The case that proves `validateLeaseID` is doing the narrowing and not
    /// `UUID(uuidString:)` on its own: `UUID(uuidString:)` **accepts** a canonical UUID
    /// with a trailing NUL and returns the same UUID as the string without it. Anything
    /// reading the value as C truncates at the NUL, so the ID that was checked is not the
    /// ID that gets logged. Only the length check refuses it.
    ///
    /// Written as its own test because the obvious one — 36 letters that are not hex —
    /// is killed by the parse alone, so it cannot tell whether the length check is there.
    @Test("A lease ID with a trailing NUL is refused, which only the length check catches")
    func leaseIDWithTrailingNULIsRefused() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())

        let smuggled = UUID().uuidString + "\u{0}"
        // The premise: Foundation parses this, so nothing downstream would have objected.
        #expect(UUID(uuidString: smuggled) != nil)

        let reply = await session.renewLease(id: smuggled)

        #expect(
            reply.fault
                == .invalidParameter(
                    name: "leaseID",
                    detail: "must be a UUID in canonical 36-character form"))
        #expect(await authority.calls.isEmpty)
    }

    @Test("A lease request with an out-of-range TTL is refused before the authority sees it")
    func outOfRangeTTLIsRefusedAtTheListener() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())

        let reply = await session.acquireLease(payload: try leasePayload(timeToLive: 6_000))

        #expect(reply.fault?.wireCode == "invalidParameter")
        #expect(await authority.calls.isEmpty)
    }

    @Test("A lease request naming a holder with a control character is refused at the listener")
    func controlCharacterHolderIsRefusedAtTheListener() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())

        let reply = await session.acquireLease(payload: try leasePayload(holder: "a\u{202E}b"))

        #expect(
            reply.fault
                == .invalidParameter(
                    name: "holderDescription",
                    detail: "must not contain control or formatting characters"))
        #expect(await authority.calls.isEmpty)
    }

    /// The fan-index check belongs to the authority, which owns the enumeration. A lease
    /// request naming a fan that does not exist must therefore *reach* the authority — the
    /// listener has no business refusing it, and could not do so without a hardware read.
    @Test("Fan indices are not judged by the listener; the request reaches the authority")
    func fanIndicesAreTheAuthoritysBusiness() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())

        let reply = await session.acquireLease(payload: try leasePayload(fanIndices: [99]))

        #expect(reply.fault == .manualControlUnavailable(reason: .writePathNotBuilt))
        #expect(await authority.calls == [.acquireLease(session.id)])
    }

    // MARK: - Teardown

    @Test("Invalidation crosses the seam, once, however many times it is called")
    func invalidationIsIdempotentAndCrossesTheSeam() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        await session.invalidate()
        await session.invalidate()

        #expect(await authority.invalidatedConnections == [session.id])
    }

    /// The count in the invalidation log line, which is what makes "no message was ever
    /// delivered" a fact rather than an inference.
    @Test("Every message delivered is counted, refused ones included")
    func everyMessageIsCounted() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        _ = await session.snapshot()
        _ = await session.hello(payload: try helloPayload())
        _ = await session.snapshot()

        #expect(await session.messageCount == 3)
    }
}
