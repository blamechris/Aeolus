import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// The ceiling on `helperFailed`'s detail, applied where the detail is built and where one
/// arrives — not only where it is rendered.
///
/// `FaultText.displayable` already bounded this text at render time, and that is not a bound
/// on what crosses the boundary: `asNSError()` embeds the fault's JSON in `userInfo` and
/// `NSXPCConnection` re-encodes it. A detail that is only short by the time a label draws it
/// has already crossed a privilege boundary at full size.
@Suite("Fault detail bounds")
struct XPCFaultDetailBoundTests {

    /// Long enough that nothing about it could be an accident of a small buffer.
    static let megabytes = String(repeating: "x", count: 4_000_000)

    // MARK: - The bound itself

    @Test("Text inside both caps is returned unchanged")
    func shortTextIsUntouched() {
        let text = "no AppleSMC service on this machine"
        #expect(FaultDetailBounds.bounded(text) == text)
    }

    /// A ceiling, not a sanitiser. Stripping here would duplicate `FaultText.displayable`'s
    /// job and would silently change what a diagnostic said before anyone rendered it.
    @Test("The bound does not strip, trim, or otherwise rewrite text that fits")
    func theBoundIsNotASanitiser() {
        let text = "  leading and trailing space, and a \u{202E} override  "
        #expect(FaultDetailBounds.bounded(text) == text)
    }

    @Test("Over-long text is cut to within both caps, with the marker inside the bound")
    func longTextIsCutWithinTheBound() {
        let bounded = FaultDetailBounds.bounded(Self.megabytes)

        #expect(bounded.count <= FaultDetailBounds.maxLength)
        #expect(bounded.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
        #expect(bounded.hasSuffix(FaultDetailBounds.truncationMarker))
    }

    /// The byte cap is not implied by the character cap. 200 characters of combining marks
    /// is kilobytes, which is the defect the byte half exists for.
    @Test("A string inside the character cap but past the byte cap is still cut")
    func theByteCapBindsIndependently() {
        let dense = String(
            repeating: "a" + String(repeating: "\u{0301}", count: 64),
            count: FaultDetailBounds.maxLength - 1)
        #expect(dense.count < FaultDetailBounds.maxLength)
        #expect(dense.utf8.count > FaultDetailBounds.maxUTF8Bytes)

        #expect(FaultDetailBounds.bounded(dense).utf8.count <= FaultDetailBounds.maxUTF8Bytes)
    }

    /// The byte cap's own boundary, which neither test above can reach.
    ///
    /// `longTextIsCutWithinTheBound` feeds ASCII, where the character cap binds and the byte
    /// budget is never approached. `theByteCapBindsIndependently` feeds 129-byte clusters,
    /// so the loop stops 26 bytes short of the budget and a three-byte error either way is
    /// invisible. Five-byte clusters divide the budget exactly: 160 of them are 800 bytes,
    /// so whether the marker's own three bytes come out of the budget or are added past it
    /// is the difference between a 798-byte result and an 803-byte one — against a cap of
    /// 800. #219's review confirmed the gap by mutation: `bytes: maxUTF8Bytes -
    /// truncationMarker.utf8.count` → `bytes: maxUTF8Bytes` left the whole suite green.
    @Test("The marker's bytes come out of the byte cap rather than sitting on top of it")
    func theMarkerFitsInsideTheByteCap() {
        let dense = String(
            repeating: "a\u{0301}\u{0301}", count: FaultDetailBounds.maxLength - 1)
        #expect(dense.count < FaultDetailBounds.maxLength)
        #expect(dense.utf8.count > FaultDetailBounds.maxUTF8Bytes)

        let bounded = FaultDetailBounds.bounded(dense)

        #expect(bounded.hasSuffix(FaultDetailBounds.truncationMarker))
        #expect(bounded.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
    }

    /// The rendering bound and the construction bound are the same two numbers, held once.
    /// Two constants that must agree with nothing enforcing it is how they stop agreeing.
    ///
    /// This pins the **constants** and nothing else, and is a tautology at any commit where
    /// `FaultText` names `FaultDetailBounds`' values rather than restating them: no deletion
    /// or inversion of production logic reddens it, only re-introducing a differing literal.
    /// That is its whole job. `renderingAndConstructionCutIdentically` is the one that pins
    /// the behaviour.
    @Test("Rendering and construction bound the same text by the same numbers")
    func oneBoundNotTwo() {
        #expect(FaultText.maxRenderedLength == FaultDetailBounds.maxLength)
        #expect(FaultText.maxRenderedUTF8Bytes == FaultDetailBounds.maxUTF8Bytes)
    }

    /// Equal constants are not one bound. The two functions have to cut the same text the
    /// same way, and until #219's review they did not: `displayable` cut to the full cap and
    /// then appended the marker, so rendering returned 201 characters and 803 bytes against
    /// constants named `maxRenderedLength` (200) and `maxRenderedUTF8Bytes` (800), while
    /// `oneBoundNotTwo` sat green beside it comparing the two numbers.
    ///
    /// Compared as whole strings rather than as lengths: `displayable` strips control
    /// characters before cutting and `bounded` does not, so on text with none the two are
    /// required to agree character for character, which is the strongest form of the claim.
    @Test("Rendering and construction cut the same over-long text identically")
    func renderingAndConstructionCutIdentically() {
        let rendered = FaultText.displayable(Self.megabytes)

        #expect(rendered == FaultDetailBounds.bounded(Self.megabytes))
        #expect(rendered.count <= FaultText.maxRenderedLength)
        #expect(rendered.utf8.count <= FaultText.maxRenderedUTF8Bytes)
    }

    // MARK: - On arrival

    /// A helper is not the only thing that can put a string in this field: a peer, or
    /// anything that can forge an `NSError` in this domain, hands one to `init(from:)`.
    @Test("A helperFailed detail arriving over-long is bounded on decode")
    func decodedDetailIsBounded() throws {
        let wire = Data(#"{"code":"helperFailed","detail":"\#(Self.megabytes)"}"#.utf8)

        let fault = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: wire)

        guard case .helperFailed(let detail) = fault else {
            Issue.record("expected helperFailed, got \(fault)")
            return
        }
        #expect(detail.count <= FaultDetailBounds.maxLength)
        #expect(detail.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
    }

    @Test("A helperFailed detail arriving inside the bound survives the wire unchanged")
    func decodedShortDetailIsUntouched() throws {
        let text = "no AppleSMC service on this machine"
        let wire = Data(#"{"code":"helperFailed","detail":"\#(text)"}"#.utf8)

        let fault = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: wire)

        #expect(fault == .helperFailed(detail: text))
    }

    /// Every free-text string a decoded fault carries, so one test can cover every arm and
    /// adding an arm that forgets the bound fails here rather than passing unnoticed.
    ///
    /// No `default:` arm, deliberately: `AeolusXPCFault` is not `@testable`-exempt from
    /// exhaustiveness, so a new case added to it is a compile error in this file until this
    /// switch is taught what the case carries — the one shape of "forgets the bound" a
    /// non-exhaustive switch cannot catch. #219's review confirmed the gap: with a
    /// `default: return []` arm here, `manualControlUnavailable`'s `reason` decoded
    /// unbounded and the whole suite stayed green.
    static func freeText(_ fault: AeolusXPCFault) -> [String] {
        switch fault {
        case .handshakeRequired: return []
        case .versionMismatch: return []
        case .malformedPayload(let detail): return [detail]
        case .invalidParameter(let name, let detail): return [name, detail]
        case .manualControlUnavailable(let reason): return [reason.wireValue]
        case .leaseExpired: return []
        case .leaseUnknown: return []
        case .leaseNotHeldByThisConnection: return []
        case .thermalEmergencyActive: return []
        case .reclaimedBySystem: return []
        case .boundsImplausible(_, let detail): return [detail]
        case .helperFailed(let detail): return [detail]
        case .unknown(let code, let detail): return [code] + (detail.map { [$0] } ?? [])
        }
    }

    /// Builds an oversized exemplar of the case `code` decodes to, with every field the
    /// case carries set to `Self.megabytes` (or a harmless placeholder for a field that
    /// is not free text, such as `versionMismatch`'s integers).
    ///
    /// Exhaustive over `AeolusXPCFault.KnownCode`, which is `CaseIterable` since #231 for
    /// exactly this reason: a new code is a compile error here until this switch says how
    /// to build one, so the wire-shape coverage below cannot silently omit it the way a
    /// hand-typed template list could. This is the structural tie #231 asked for — one
    /// switch, forced by the compiler, standing in for the second hand-maintained
    /// enumeration `AeolusXPCFault`'s associated values rule out.
    static func oversizedExemplar(for code: AeolusXPCFault.KnownCode) -> AeolusXPCFault {
        switch code {
        case .handshakeRequired: return .handshakeRequired
        case .versionMismatch:
            return .versionMismatch(
                clientVersion: 1,
                helperRange: ProtocolVersionRange(minimumSupported: 1, current: 1))
        case .malformedPayload: return .malformedPayload(detail: megabytes)
        case .invalidParameter: return .invalidParameter(name: megabytes, detail: megabytes)
        case .manualControlUnavailable:
            return .manualControlUnavailable(
                reason: ManualControlAvailability.Reason(wireValue: megabytes))
        case .leaseExpired: return .leaseExpired
        case .leaseUnknown: return .leaseUnknown
        case .leaseNotHeldByThisConnection: return .leaseNotHeldByThisConnection
        case .thermalEmergencyActive: return .thermalEmergencyActive
        case .reclaimedBySystem: return .reclaimedBySystem
        case .boundsImplausible: return .boundsImplausible(fanIndex: 0, detail: megabytes)
        case .helperFailed: return .helperFailed(detail: megabytes)
        }
    }

    /// Every exemplar `oversizedExemplar(for:)` can build, plus `.unknown` — the one case
    /// with deliberately no entry in `KnownCode`, because it is what a code *outside* that
    /// closed set decodes to. That is a fixed structural exception rather than a case that
    /// could ever be silently added, so it is listed here by hand and nowhere else.
    static let everyExemplar: [AeolusXPCFault] =
        AeolusXPCFault.KnownCode.allCases.map(oversizedExemplar(for:))
        + [.unknown(code: megabytes, detail: megabytes)]

    /// The decode-side bound names an adversary — a peer, or anything that can forge an
    /// `NSError` in this domain — and that adversary chooses the wire code. #93 bounded
    /// `helperFailed` alone, which left `malformedPayload`, `invalidParameter`,
    /// `boundsImplausible` and `unknown` decoding their free text unbounded: the same 4 MB
    /// string reached a client through any of them by changing one word on the wire.
    ///
    /// Parameterised over `KnownCode.allCases` rather than a hand-typed template per case
    /// — the tie #231 asked for — and rather than over the oversized exemplars themselves:
    /// `AeolusXPCFault` embeds its associated values in a parameterised test's own name, so
    /// arguing over `everyExemplar` directly would put a 4 MB string in every test-case
    /// name Swift Testing prints, pass or fail. The exemplar is built inside the test body
    /// instead, and is round-tripped through the real encoder and decoder, so this
    /// exercises the actual wire path, not a JSON literal that could drift from it. A case
    /// with no free text (`freeText` returns `[]`) is included too and simply has nothing
    /// to check — the point is that every case is *reachable* here at all, which #231 found
    /// was not true of the old hand-typed list.
    @Test(
        "Every free-text field arriving over-long is bounded on decode",
        arguments: AeolusXPCFault.KnownCode.allCases)
    func everyFreeTextFieldIsBoundedOnDecode(code: AeolusXPCFault.KnownCode) throws {
        let exemplar = Self.oversizedExemplar(for: code)
        let wire = try AeolusXPCCoding.encoder().encode(exemplar)
        let fault = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: wire)

        for text in Self.freeText(fault) {
            #expect(text.count <= FaultDetailBounds.maxLength)
            #expect(text.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
        }
    }

    /// `.unknown`'s own arm of the check above: the one case with deliberately no entry in
    /// `KnownCode`, because it is what a code *outside* that closed set decodes to, so it
    /// cannot be reached by parameterising over `KnownCode.allCases`. A fixed structural
    /// exception rather than a case that could ever be silently added — nothing else in
    /// this file needs a second hand-written entry for it.
    @Test("An unrecognised code's free text is bounded on decode too")
    func unknownCodeFreeTextIsBoundedOnDecode() throws {
        let exemplar = AeolusXPCFault.unknown(code: Self.megabytes, detail: Self.megabytes)
        let wire = try AeolusXPCCoding.encoder().encode(exemplar)
        let fault = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: wire)

        let strings = Self.freeText(fault)
        #expect(!strings.isEmpty)
        for text in strings {
            #expect(text.count <= FaultDetailBounds.maxLength)
            #expect(text.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
        }
    }

    /// `everyFreeTextFieldIsBoundedOnDecode` proves nothing for a case whose free text
    /// never actually got long — a builder that forgot to substitute `megabytes` would
    /// leave the case in `everyExemplar` but make its check vacuous. This is the
    /// independent proof that every case `freeText(_:)` says carries text really carries
    /// oversized text going in, for every exemplar this file builds.
    @Test("Every exemplar that carries free text carries it over both bounds")
    func everyCarriedFieldIsActuallyOversized() {
        for exemplar in Self.everyExemplar {
            for text in Self.freeText(exemplar) {
                #expect(
                    text.count > FaultDetailBounds.maxLength
                        || text.utf8.count > FaultDetailBounds.maxUTF8Bytes,
                    "\(exemplar) carries free text that was never long enough to prove the bound"
                )
            }
        }
    }
}
