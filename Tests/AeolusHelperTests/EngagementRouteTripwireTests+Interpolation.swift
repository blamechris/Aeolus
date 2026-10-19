import Foundation
import Testing

@testable import AeolusHelper

/// The second blind spot of `SeamScanner.strippingAllComments(_:)`'s quote counter, beside the raw
/// string's: a string literal **nested in an interpolation**. In `"\(String("//"))"` the counter
/// closes the outer literal at the inner one's opening quote, so the inner `//` reads as a comment
/// and the rest of the line — code included — is dropped from every scan that reads stripped
/// source. Kept here rather than in `EngagementRouteTripwireTests.swift` for that suite's
/// `type_body_length`; `noRawStringHoldsAQuoteAndACommentMarker` runs this scan over the tree.
extension EngagementRouteTripwireTests {

    /// Every line of `source`, block and whole-line comments stripped first, that opens an
    /// interpolation and then holds a `"` and, after it, a `//` — a nested literal holding a
    /// comment marker, or one whose quotes put the counter out of step before a marker later on
    /// the line. Fail-closed: a line that interpolates and then holds a separate literal with a
    /// marker in it is reported too, and is rewritten rather than reasoned about.
    static func interpolationsHoldingAQuoteAndACommentMarker(
        in source: String
    ) throws -> [String] {
        let code = SeamScanner.strippingComments(source)
        let risky = try NSRegularExpression(pattern: #"\\\([^\n]*"[^\n]*//"#)
        return code.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { line in
                risky.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
    }

    /// The scan behind the tree test, on lines it must and must not report.
    ///
    /// **Mutation (this suite's own):** make `interpolationsHoldingAQuoteAndACommentMarker(in:)`
    /// return nothing. Run: red here — the tree holds no such line, so the tree test alone cannot
    /// tell a working scan from a dead one.
    @Test("The interpolation scan reports a nested literal with a comment marker, and nothing else")
    func theInterpolationScanReportsOnlyTheRiskyLines() throws {
        let reported = try Self.interpolationsHoldingAQuoteAndACommentMarker(
            in: #"""
                private let label = "\(String("//"))"; let hidden = PlaneAdmission.thermalCycle
                private let other = "\(flag ? "x" : "y//z")"
                private let url = "\(host) at https://example.com"
                private let fine = "\(flag ? "yes" : "no")"
                // let commented = "\(String("//"))"
                """#)

        #expect(reported.count == 2, "reported \(reported)")
        #expect(reported.first?.contains("PlaneAdmission.thermalCycle") == true)
        #expect(reported.last?.contains("y//z") == true)
    }
}
