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
    static func freeText(_ fault: AeolusXPCFault) -> [String] {
        switch fault {
        case .malformedPayload(let detail): return [detail]
        case .invalidParameter(let name, let detail): return [name, detail]
        case .boundsImplausible(_, let detail): return [detail]
        case .helperFailed(let detail): return [detail]
        case .unknown(let code, let detail): return [code] + (detail.map { [$0] } ?? [])
        default: return []
        }
    }

    /// The decode-side bound names an adversary — a peer, or anything that can forge an
    /// `NSError` in this domain — and that adversary chooses the wire code. #93 bounded
    /// `helperFailed` alone, which left `malformedPayload`, `invalidParameter`,
    /// `boundsImplausible` and `unknown` decoding their free text unbounded: the same 4 MB
    /// string reached a client through any of them by changing one word on the wire.
    ///
    /// Driven from templates rather than written out five times, so the next arm to carry
    /// free text is one line here and cannot be half-added.
    @Test(
        "Every free-text field arriving over-long is bounded on decode",
        arguments: [
            #"{"code":"malformedPayload","detail":"@"}"#,
            #"{"code":"invalidParameter","name":"@","detail":"@"}"#,
            #"{"code":"boundsImplausible","fanIndex":0,"detail":"@"}"#,
            #"{"code":"helperFailed","detail":"@"}"#,
            #"{"code":"@","detail":"@"}"#,
        ])
    func everyFreeTextFieldIsBoundedOnDecode(template: String) throws {
        let wire = Data(template.replacingOccurrences(of: "@", with: Self.megabytes).utf8)

        let fault = try AeolusXPCCoding.decoder().decode(AeolusXPCFault.self, from: wire)

        let strings = Self.freeText(fault)
        #expect(!strings.isEmpty, "this arm carries no free text, so the case proves nothing")
        for text in strings {
            #expect(text.count <= FaultDetailBounds.maxLength)
            #expect(text.utf8.count <= FaultDetailBounds.maxUTF8Bytes)
        }
    }
}
