import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The envelope bound, reached from the helper's own message handlers.
///
/// `XPCPayloadBoundsTests` proves the check refuses; this proves it is *wired in* — that
/// every payload-carrying message on the connection actor runs it, and that an over-size
/// payload never reaches the authority. A bound the boundary never calls is a bound that
/// exists only in its own unit test.
@Suite("The payload envelope gate")
struct PayloadEnvelopeGateTests {

    private func session(authority: RecordingFanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperRange: AeolusXPCVersion.supportedRange,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Envelope")
        )
    }

    /// Grows a well-formed payload past `limit` with JSON whitespace, so what is refused is
    /// the size rather than the syntax.
    private func oversize(_ payload: Data, limit: Int) -> Data {
        var bytes = Array(payload)
        bytes.insert(
            contentsOf: Array(repeating: UInt8(ascii: " "), count: limit + 1 - bytes.count), at: 1)
        return Data(bytes)
    }

    private func sizeDetail(limit: Int) -> String {
        "is larger than the \(limit)-byte limit for this message"
    }

    /// The message that matters most: `hello` is not behind the handshake gate, because it
    /// *is* the gate, so this is the only refusal reachable on a connection that has proved
    /// nothing about itself yet.
    @Test("An over-size hello is refused on a connection that has not handshaken")
    func helloIsBoundedBeforeTheHandshake() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        let payload = oversize(
            try helloPayload(), limit: AeolusXPCPayloadBounds.maxHelloRequestBytes)

        let reply = await session.hello(payload: payload)

        #expect(
            reply.fault
                == .malformedPayload(
                    detail: sizeDetail(limit: AeolusXPCPayloadBounds.maxHelloRequestBytes)))
        #expect(await authority.calls.isEmpty)
    }

    @Test("An over-size lease request is refused and never reaches the authority")
    func acquireLeaseIsBounded() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        let payload = oversize(
            try leasePayload(), limit: AeolusXPCPayloadBounds.maxLeaseRequestBytes)

        let reply = await session.acquireLease(payload: payload)

        #expect(
            reply.fault
                == .malformedPayload(
                    detail: sizeDetail(limit: AeolusXPCPayloadBounds.maxLeaseRequestBytes)))
        #expect(await authority.calls.isEmpty)
    }

    @Test("An over-size settings payload is refused and never reaches the authority")
    func applyIsBounded() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload())
        let settings = try AeolusXPCCoding.encoder().encode(
            [FanSetting(fanIndex: 0, control: .automatic)])
        let payload = oversize(settings, limit: AeolusXPCPayloadBounds.maxFanSettingsBytes)

        let reply = await session.apply(settings: payload, leaseID: UUID().uuidString)

        #expect(
            reply.fault
                == .malformedPayload(
                    detail: sizeDetail(limit: AeolusXPCPayloadBounds.maxFanSettingsBytes)))
        #expect(await authority.calls.isEmpty)
    }
}
