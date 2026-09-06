import AeolusXPC
import Foundation
import Testing

@testable import AeolusHelper

/// The two reply shapes, and the one branch in them that can be reached without a client
/// doing anything at all.
@Suite("Helper reply shapes")
struct HelperReplyTests {

    /// A value the shared encoder refuses. `AeolusXPCCoding.encoder()` is a bare
    /// `JSONEncoder`, so its `nonConformingFloatEncodingStrategy` is `.throw`.
    private struct NonFinitePayload: Encodable {
        let value = Double.infinity
    }

    /// **Whose fault the helper says it is.** `malformedPayload` is documented as "a
    /// payload did not decode, or was missing a required field" — a statement about what
    /// the client sent — and `snapshot(reply:)` carries no payload for a client to have got
    /// wrong. The value that failed to encode was built by the helper from what the
    /// firmware reported.
    ///
    /// Not hypothetical: a sensor decoding to a non-finite `Double` is exactly how this
    /// branch is reached, which is why `ReadOnlyFanAuthority` omits one. Attributing that
    /// to the client sends the user to file a bug against the wrong half of the system.
    @Test("A reply the helper cannot encode is reported as the helper's failure")
    func encodingFailureIsReportedAsTheHelpersFailure() throws {
        // The premise: this really does fail to encode, so the test is not green because
        // it never reached the branch it names.
        #expect(throws: (any Error).self) {
            try AeolusXPCCoding.encoder().encode(NonFinitePayload())
        }

        let reply = PayloadReply.encoding(NonFinitePayload())

        guard case .helperFailed(let detail) = try #require(reply.fault) else {
            Issue.record("expected helperFailed, got \(String(describing: reply.fault))")
            return
        }
        #expect(detail == "the helper could not encode its own reply")
        #expect(reply.payloadData == nil, "a refusal never also carries a payload")
    }

    /// The detail is fixed text, not the `EncodingError`, whose description quotes the
    /// offending value and the coding path that reached it. Helper-authored strings are
    /// permitted to quote what they saw; there is no reason for this one to.
    @Test("The encoding-failure detail names the failure and never the value")
    func encodingFailureDetailQuotesNothing() throws {
        let fault = try #require(PayloadReply.encoding(NonFinitePayload()).fault)
        let rendered = try #require(fault.errorDescription)

        #expect(!rendered.contains("inf"))
        #expect(!rendered.contains("Infinity"))
    }

    // MARK: - The unbounded arm

    /// An error from a layer that has not been written yet. `crossing(_:)` exists to catch
    /// exactly this, and `String(describing:)` over an arbitrary `Error` is unbounded by
    /// construction.
    private struct EnormousError: Error, CustomStringConvertible {
        let description = String(repeating: "x", count: 4_000_000)
    }

    /// The bound has to bite **before** `asNSError()`, not after.
    ///
    /// `asNSError()` encodes the fault into `userInfo` and `NSXPCConnection` re-encodes
    /// that on the way across, so a detail that is only shortened at render time has
    /// already crossed the privilege boundary at full size. The enum payload is asserted
    /// first for that reason: it is what the helper's own log line and every later encoding
    /// read from.
    ///
    /// Every producer reaching `helperFailed` today is bounded — `SMCFanEnumerationError`'s
    /// sentences and four fixed literals — so this is depth. It is also the arm whose whole
    /// purpose is to carry errors nobody anticipated, which E5 keeps adding to.
    @Test("An unbounded error is bounded where the fault is built, before asNSError")
    func crossingBoundsAnUnboundedError() throws {
        let fault = AeolusXPCFault.crossing(EnormousError())

        guard case .helperFailed(let detail) = fault else {
            Issue.record("expected helperFailed, got \(fault)")
            return
        }
        #expect(detail.count <= FaultDetailBounds.maxLength)
        #expect(detail.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
        #expect(detail.hasSuffix(FaultDetailBounds.truncationMarker))

        let payload = try #require(
            fault.asNSError().userInfo[AeolusXPCFault.payloadUserInfoKey] as? String)
        #expect(payload.utf8.count <= 2 * FaultDetailBounds.maxUTF8Bytes)
    }

    /// The other half: `helperFailed`'s permission to quote what it saw is not withdrawn.
    /// A diagnosis that fits is carried whole, or an SMC failure stops being diagnosable.
    @Test("An error whose description fits crosses unchanged")
    func crossingLeavesAShortDescriptionAlone() {
        struct ShortError: Error, CustomStringConvertible {
            let description = "the SMC refused the key"
        }

        #expect(
            AeolusXPCFault.crossing(ShortError())
                == .helperFailed(detail: "the SMC refused the key"))
    }
}
