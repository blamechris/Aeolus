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
}
