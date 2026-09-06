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

    /// The rendering bound and the construction bound are the same two numbers, held once.
    /// Two constants that must agree with nothing enforcing it is how they stop agreeing.
    @Test("Rendering and construction bound the same text by the same numbers")
    func oneBoundNotTwo() {
        #expect(FaultText.maxRenderedLength == FaultDetailBounds.maxLength)
        #expect(FaultText.maxRenderedUTF8Bytes == FaultDetailBounds.maxUTF8Bytes)
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
}
