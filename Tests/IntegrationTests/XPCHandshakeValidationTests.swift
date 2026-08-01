import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// The handshake is the gate every other message sits behind, so its refusals are the
/// ones that decide whether an unnegotiated client can proceed at all.
@Suite("XPC handshake validation")
struct XPCHandshakeValidationTests {

    @Test("A hello inside the helper's range is accepted")
    func compatibleHelloIsAccepted() throws {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current,
            clientDescription: "fanctl 0.1.0"
        )
        let payload = try AeolusXPCCoding.encoder().encode(request)
        #expect(try AeolusXPCValidation.helloRequest(from: payload) == request)
    }

    @Test("A hello outside the helper's range is refused with both sides' numbers")
    func incompatibleHelloIsRefused() throws {
        let helperRange = ProtocolVersionRange(minimumSupported: 2, current: 4)
        let request = HelloRequest(clientProtocolVersion: 1, clientDescription: "fanctl")
        let thrown = try #require(
            fault(from: {
                try AeolusXPCValidation.validate(request, helperRange: helperRange)
            })
        )
        #expect(thrown == .versionMismatch(clientVersion: 1, helperRange: helperRange))
    }

    @Test("A hello from a client newer than the helper is refused")
    func newerClientIsRefused() {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current + 1,
            clientDescription: "Aeolus.app"
        )
        let thrown = fault(from: { try AeolusXPCValidation.validate(request) })
        #expect(thrown?.wireCode == "versionMismatch")
    }

    @Test("A hello with a hostile client description is refused")
    func hostileClientDescriptionIsRefused() {
        let request = HelloRequest(
            clientProtocolVersion: AeolusXPCVersion.current,
            clientDescription: "Aeolus.app\u{0}"
        )
        #expect(
            refusedParameter({ try AeolusXPCValidation.validate(request) }) == "clientDescription")
    }

    /// The description is judged before the version. A client that is both out of range
    /// and misbehaved is told about the misbehaviour, because updating fixes the version
    /// and would leave the bug in place.
    @Test("A hello that is both out of range and misbehaved reports the misbehaviour")
    func descriptionIsCheckedBeforeVersion() {
        let request = HelloRequest(
            clientProtocolVersion: 99,
            clientDescription: "Aeolus.app\n"
        )
        #expect(
            refusedParameter({ try AeolusXPCValidation.validate(request) }) == "clientDescription")
    }

    @Test("Undecodable hello JSON is refused as a malformed payload")
    func undecodableHelloIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeHelloRequest(from: Data("{".utf8))
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }

    @Test("A hello missing its version is refused rather than defaulted")
    func helloWithoutVersionIsRefused() {
        let thrown = fault(from: {
            _ = try AeolusXPCValidation.decodeHelloRequest(
                from: Data(#"{"clientDescription":"fanctl"}"#.utf8)
            )
        })
        #expect(thrown?.wireCode == "malformedPayload")
    }
}
