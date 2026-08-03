import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// The fault vocabulary is how the helper says no, so the properties worth testing are
/// the ones that decide whether a client can tell "no" from "yes": that every code
/// survives the wire, that a code from a newer helper still arrives as a refusal, that a
/// structurally broken payload does not quietly become one, and that nothing a peer sends
/// can rewrite the log line it lands in.
@Suite("XPC fault vocabulary")
struct XPCFaultTests {

    /// One of each case, including every case E2 cannot yet raise. The point of writing
    /// the vocabulary out early is that E5 and #37 can raise these without a protocol
    /// bump, which only holds if they encode and decode today.
    static let everyCase: [AeolusXPCFault] = [
        .handshakeRequired,
        .versionMismatch(
            clientVersion: 3,
            helperRange: ProtocolVersionRange(minimumSupported: 1, current: 1)
        ),
        .malformedPayload(detail: "is not well-formed JSON"),
        .invalidParameter(name: "timeToLive", detail: "must be between 5 and 120 seconds"),
        .manualControlUnavailable(reason: .writePathNotBuilt),
        .manualControlUnavailable(reason: .unknown("firmwareLocked")),
        .leaseExpired,
        .leaseUnknown,
        .leaseNotHeldByThisConnection,
        .thermalEmergencyActive,
        .reclaimedBySystem,
        .boundsImplausible(fanIndex: 1, detail: "F1Mn exceeds F1Mx"),
        .helperFailed(detail: "no AppleSMC service on this machine"),
        .unknown(code: "somethingNewer", detail: "with a detail"),
        .unknown(code: "somethingNewer", detail: nil),
    ]

    private func roundTrip(_ fault: AeolusXPCFault) throws -> AeolusXPCFault {
        let data = try AeolusXPCCoding.encoder().encode(fault)
        return try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: data)
    }

    private func decode(_ json: String) throws -> AeolusXPCFault {
        try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: Data(json.utf8))
    }

    @Test("Every fault survives a round trip", arguments: XPCFaultTests.everyCase)
    func everyCaseRoundTrips(_ fault: AeolusXPCFault) throws {
        #expect(try roundTrip(fault) == fault)
    }

    /// A refusal nobody can read is a refusal a client has to guess at, and every guess
    /// is optimistic.
    @Test("Every fault renders a non-empty message", arguments: XPCFaultTests.everyCase)
    func everyCaseRenders(_ fault: AeolusXPCFault) throws {
        let description = try #require(fault.errorDescription)
        #expect(!description.isEmpty)
    }

    /// The forward-tolerance contract, and the reason the vocabulary can grow inside
    /// version 1: a code this build has never heard of is still a refusal.
    @Test("An unrecognised code decodes to .unknown rather than failing")
    func unrecognisedCodeDecodesToUnknown() throws {
        let decoded = try decode(#"{"code":"fanSeizedSolid","detail":"it is stuck"}"#)
        #expect(decoded == .unknown(code: "fanSeizedSolid", detail: "it is stuck"))
    }

    @Test("An unrecognised code with no detail still decodes")
    func unrecognisedCodeWithoutDetail() throws {
        let decoded = try decode(#"{"code":"fanSeizedSolid"}"#)
        #expect(decoded == .unknown(code: "fanSeizedSolid", detail: nil))
    }

    /// Generic rendering, in the sense that matters: the message names the code, says it
    /// is a refusal, and does not pretend to be one of the codes this build knows.
    @Test("An unrecognised code renders generically, carrying the raw code")
    func unknownRendersGenerically() throws {
        let fault = AeolusXPCFault.unknown(code: "fanSeizedSolid", detail: nil)
        let description = try #require(fault.errorDescription)
        #expect(description.contains("fanSeizedSolid"))
        #expect(description.lowercased().contains("refused"))
    }

    /// Tolerance is for values, not for structure. A code this build *does* know,
    /// arriving without the fields that code requires, is corruption — and must not be
    /// laundered into `.unknown`, which would report a refusal this build could have
    /// understood as one it could not.
    @Test(
        "A known code missing its required fields throws",
        arguments: [
            #"{"code":"versionMismatch"}"#,
            #"{"code":"versionMismatch","clientVersion":3}"#,
            #"{"code":"malformedPayload"}"#,
            #"{"code":"invalidParameter","name":"timeToLive"}"#,
            #"{"code":"manualControlUnavailable"}"#,
            #"{"code":"boundsImplausible","fanIndex":0}"#,
            #"{"code":"helperFailed"}"#,
        ]
    )
    func knownCodeMissingFieldsThrows(_ json: String) {
        #expect(throws: DecodingError.self) {
            try decode(json)
        }
    }

    @Test("A payload with no code at all throws")
    func missingCodeThrows() {
        #expect(throws: DecodingError.self) {
            try decode(#"{"detail":"orphaned"}"#)
        }
    }

    /// Both sides' numbers, because the actionable part of a version mismatch is which
    /// of the two installed things is the old one.
    @Test("A version mismatch names both sides and the fix")
    func versionMismatchNamesBothSides() throws {
        let fault = AeolusXPCFault.versionMismatch(
            clientVersion: 3,
            helperRange: ProtocolVersionRange(minimumSupported: 1, current: 2)
        )
        let description = try #require(fault.errorDescription)
        #expect(description.contains("3"))
        #expect(description.contains("1"))
        #expect(description.contains("2"))
    }

    /// Free text from the far side lands in a log line and a UI label. A newline in it
    /// forges a second log entry; U+202E reverses the reading order of everything after
    /// it. Neither may reach the rendered string.
    @Test(
        "Rendered messages strip control and formatting characters",
        arguments: ["\u{0}", "\n", "\r", "\u{7F}", "\u{202E}", "\u{200F}"]
    )
    func renderingStripsControlCharacters(_ hostile: String) throws {
        let faults: [AeolusXPCFault] = [
            .unknown(code: "code\(hostile)injected", detail: nil),
            .unknown(code: "code", detail: "detail\(hostile)injected"),
            .malformedPayload(detail: "detail\(hostile)injected"),
            .invalidParameter(name: "field\(hostile)x", detail: "detail\(hostile)y"),
            .boundsImplausible(fanIndex: 0, detail: "detail\(hostile)y"),
            .helperFailed(detail: "detail\(hostile)y"),
            .manualControlUnavailable(reason: .unknown("reason\(hostile)z")),
        ]
        for fault in faults {
            let description = try #require(fault.errorDescription)
            #expect(
                !description.contains(hostile),
                "\(fault.wireCode) rendered a control character verbatim"
            )
        }
    }

    /// Stripping must not silently erase the fact that something arrived. A code made
    /// entirely of control characters still has to render as *something* a reader can
    /// distinguish from the helper having said nothing.
    @Test("Text that is entirely unprintable still renders as a marker")
    func entirelyUnprintableTextStillRenders() throws {
        let fault = AeolusXPCFault.unknown(code: "\u{0}\u{202E}\n", detail: nil)
        let description = try #require(fault.errorDescription)
        #expect(description.contains(FaultText.unprintableMarker))
    }

    /// A helper that sent a megabyte of detail must not put a megabyte into a log line.
    @Test("Rendered free text is bounded")
    func renderedTextIsBounded() throws {
        let long = String(repeating: "a", count: 10_000)
        let fault = AeolusXPCFault.malformedPayload(detail: long)
        let description = try #require(fault.errorDescription)
        #expect(description.count < FaultText.maxRenderedLength + 200)
        #expect(description.contains("…"))
    }

    /// A character cap alone does not bound a log line: one grapheme cluster can carry an
    /// unbounded run of combining marks, so text comfortably inside 200 *characters* is
    /// still hundreds of kilobytes. Both caps have to hold — the same defect, and the same
    /// fix, as `maxHolderDescriptionUTF8Bytes` one file over.
    @Test("Rendered free text is bounded in bytes, not only in characters")
    func renderedTextIsBoundedInBytes() throws {
        let cluster = "a" + String(repeating: "\u{0301}", count: 200)
        let byteHeavy = String(repeating: cluster, count: 300)
        #expect(byteHeavy.utf8.count > FaultText.maxRenderedUTF8Bytes)

        let fault = AeolusXPCFault.malformedPayload(detail: byteHeavy)
        let description = try #require(fault.errorDescription)
        #expect(description.utf8.count < FaultText.maxRenderedUTF8Bytes + 200)
        #expect(description.contains("…"))
    }

    /// The degenerate end of the same case: a single cluster too dense for even one
    /// character to fit inside the byte cap. It renders as the marker rather than as an
    /// ellipsis with nothing before it, which is the statement the marker always makes —
    /// the helper said something this client cannot show you.
    @Test("A single grapheme too large to render falls back to the marker")
    func oversizeSingleGraphemeRendersMarker() throws {
        let oneHugeCluster = "a" + String(repeating: "\u{0301}", count: 2_000)
        #expect(oneHugeCluster.count == 1)
        #expect(oneHugeCluster.utf8.count > FaultText.maxRenderedUTF8Bytes)

        let fault = AeolusXPCFault.malformedPayload(detail: oneHugeCluster)
        let description = try #require(fault.errorDescription)
        #expect(description.contains(FaultText.unprintableMarker))
    }

    /// The caps must not fire on text that is inside both of them.
    @Test("Text inside both caps renders unchanged")
    func textInsideBothCapsIsUnchanged() {
        let detail = "field 'timeToLive' has the wrong type"
        #expect(FaultText.displayable(detail) == detail)
    }

    /// `NSXPCConnection` flattens a Swift error to an `NSError` and discards its
    /// associated values, so this bridge is the only reason the vocabulary survives the
    /// trip at all.
    @Test("Every fault survives the NSError round trip", arguments: XPCFaultTests.everyCase)
    func everyCaseSurvivesNSErrorBridge(_ fault: AeolusXPCFault) throws {
        let nsError = fault.asNSError()
        let recovered = try #require(AeolusXPCFault(nsError: nsError))
        #expect(recovered == fault)
    }

    @Test("The bridged NSError carries a readable message for non-Swift readers")
    func bridgedErrorCarriesLocalizedDescription() {
        let nsError = AeolusXPCFault.leaseExpired.asNSError()
        #expect(nsError.domain == AeolusXPCFault.errorDomain)
        #expect(nsError.localizedDescription == AeolusXPCFault.leaseExpired.errorDescription)
    }

    /// "The helper said no" and "the helper never answered" are different facts and a
    /// client acts differently on them, so a transport failure must not come back
    /// dressed as a refusal.
    @Test("An error from outside the boundary does not become a fault")
    func foreignErrorsAreNotFaults() {
        let key = AeolusXPCFault.payloadUserInfoKey
        let notOurs: [(String, NSError)] = [
            ("another domain", NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)),
            (
                "another domain carrying our key",
                NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [key: "{}"])
            ),
            (
                "our domain with no payload",
                NSError(domain: AeolusXPCFault.errorDomain, code: 1, userInfo: nil)
            ),
            (
                "our domain with an unreadable payload",
                NSError(domain: AeolusXPCFault.errorDomain, code: 1, userInfo: [key: "not json"])
            ),
        ]
        for (label, nsError) in notOurs {
            #expect(AeolusXPCFault(nsError: nsError) == nil, "\(label) was read as a refusal")
        }
    }

    /// The wire codes are the contract. Renaming a Swift case costs nothing; renaming
    /// what it serialises as breaks every peer, and this is what makes that visible in a
    /// diff.
    @Test("Wire codes are the ones the contract publishes")
    func wireCodesAreStable() {
        let codes = Set(Self.everyCase.map(\.wireCode))
        #expect(
            codes == [
                "handshakeRequired",
                "versionMismatch",
                "malformedPayload",
                "invalidParameter",
                "manualControlUnavailable",
                "leaseExpired",
                "leaseUnknown",
                "leaseNotHeldByThisConnection",
                "thermalEmergencyActive",
                "reclaimedBySystem",
                "boundsImplausible",
                "helperFailed",
                "somethingNewer",
            ]
        )
    }

    /// A refusal shares its "why can't I control this fan" vocabulary with the snapshot,
    /// so the two cannot drift into answering the same question differently.
    @Test("manualControlUnavailable speaks FanState's availability vocabulary")
    func manualControlUnavailableSharesVocabulary() throws {
        let fault = AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
        let decoded = try roundTrip(fault)
        guard case .manualControlUnavailable(let reason) = decoded else {
            Issue.record("decoded to \(decoded.wireCode)")
            return
        }
        #expect(reason == ManualControlAvailability.Reason.writePathNotBuilt)
        #expect(reason.wireValue == "writePathNotBuilt")
    }
}
