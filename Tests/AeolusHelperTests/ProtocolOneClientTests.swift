import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A client of protocol 1 against the helper's own range since #670, 2 to 2
/// (`AeolusXPCVersion.supportedRange`). What `acquireLease` and `apply` mean changed in v2: the
/// helper may hold a target above the one sent, and a v1 client reports the one it sent, which is
/// `CLAUDE.md` rule 6's failure. So `hello` at 1 is refused with a version mismatch and the gate
/// stays shut, and `restoreAllToAutomatic`, which needs no `hello`, still hands every fan back.
@Suite("A protocol 1 client against the v2 helper (#670)")
struct ProtocolOneClientTests {

    private func session(authority: RecordingFanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperRange: AeolusXPCVersion.supportedRange,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "ProtocolOne"))
    }

    /// **Mutation:** set `AeolusXPCVersion.minimumSupported` back to 1. Run: red, the hello
    /// accepted and the snapshot after it reaching the authority.
    @Test("hello at protocol 1 is refused with a version mismatch, and the gate stays shut")
    func helloAtProtocolOneIsRefused() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)

        let reply = await session.hello(payload: try helloPayload(version: 1))
        let snapshot = await session.snapshot()

        #expect(
            reply.fault
                == .versionMismatch(clientVersion: 1, helperRange: AeolusXPCVersion.supportedRange))
        #expect(await session.handshakeState == nil)
        #expect(snapshot.fault == .handshakeRequired)
        #expect(await authority.calls.isEmpty)
    }

    /// The panic verb stays open to the client the handshake refused: its only effect is the safe
    /// state, so no version fence stands in front of it (`HandshakeGateTests`).
    @Test("restoreAllToAutomatic sent with no hello, after a refused one, still succeeds")
    func restoreAllToAutomaticNeedsNoHello() async throws {
        let authority = RecordingFanAuthority()
        let session = session(authority: authority)
        _ = await session.hello(payload: try helloPayload(version: 1))

        let reply = await session.restoreAllToAutomatic()

        #expect(reply.isSuccess)
        #expect(await authority.calls == [.restoreAllToAutomatic(session.id)])
    }
}
