import AeolusXPC
import Foundation
import SMCCore
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

    /// An `SMCError` that reaches the crossing reads as SMCCore's readable text, not as an
    /// enum dump (#544). No handler passes one today, so this is pinned at `crossing(_:)`
    /// itself. **Mutation:** put `String(describing: error)` back in `crossing(_:)`. Run: red
    /// here, with `connectionFailed(kernReturn: -536870212)`.
    @Test("An SMCError crossing the boundary reads as SMCCore's readable text")
    func crossingDescribesAnSMCErrorReadably() {
        let detail = "connection to AppleSMC failed (kernel result -536870212)"
        #expect(
            AeolusXPCFault.crossing(SMCError.connectionFailed(kernReturn: -536_870_212))
                == .helperFailed(detail: detail))
    }

    /// The live route #548 named, run through the real types: `FNum` declares a type the
    /// codec does not know, whose four bytes `E2 80 A8 61` decode as UTF-8 to U+2028 and "a".
    /// `SMCFanEnumerationError.readFailed` carries that text, and `crossing(_:)` puts the
    /// error's description into a `.helperFailed` detail at full size — it bounds, it does not
    /// clean — so the detail itself holds the separator, and cleaning it is the renderer's job
    /// (#553).
    ///
    /// The first expectation is the premise: if it fails, the route no longer reaches the
    /// detail and this test is about nothing. The rest are what `fanctl` prints.
    ///
    /// **Mutation (#553):** in `FaultText.isRemovedFromDisplay`, delete `.lineSeparator,
    /// .paragraphSeparator`. Run: red on the last two expectations, and green on the premise.
    @Test("A firmware type code with a line separator reaches fanctl without it")
    func aFirmwareTypeCodeWithALineSeparatorIsCleanedBeforeFanctlPrintsIt() throws {
        let declared = SMCKeyType(fourCharCode: 0xE280_A861)
        let key = try #require(SMCKey("FNum"))
        let enumeration = SMCFanEnumerationError.readFailed(
            context: "read FNum",
            reason: SMCError.sizeMismatch(key: key, declared: declared, reportedBytes: 1)
                .readableDescription)

        let fault = AeolusXPCFault.crossing(enumeration)

        guard case .helperFailed(let detail) = fault else {
            Issue.record("an enumeration error crossed as \(fault), not .helperFailed")
            return
        }
        #expect(detail.unicodeScalars.contains("\u{2028}"), "the route no longer carries it")
        let printed = try #require(fault.errorDescription)
        #expect(!printed.unicodeScalars.contains("\u{2028}"))
        #expect(printed.contains("FNum declares a but returned 1 bytes"))
    }
}
