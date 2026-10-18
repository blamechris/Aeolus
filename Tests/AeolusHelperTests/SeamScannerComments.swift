import Foundation

/// The comment stripper a receiver scan needs, beside `SeamScanner` and not in it: that enum is
/// at its `type_body_length` ceiling, and `SeamScannerScopes` is the precedent for a sibling
/// file holding more of the same type.
extension SeamScanner {

    /// Source with every comment removed, a `//` comment **trailing code** included.
    ///
    /// `strippingComments` leaves a trailing comment in place, and says why: the prose
    /// explaining a rule is usually a whole line. A scan that reads a *receiver* cannot leave
    /// it. `writer  // driver` on one line and `.engageManualControl(of:)` on the next normalise
    /// to `writer  // driver.engageManualControl(of:)`, and the receiver that scan reads is the
    /// last word of the comment, which can be the one name the scan allows.
    ///
    /// Built on `strippingComments`, so block comments and whole-line comments are gone before
    /// this looks, on `copyDelimited` for string literals, so the `//` in `"https://…"` or in
    /// `#"say "hi" // x"#` opens no comment, and on `regexLiteralEnd` for regex literals, tried
    /// before the `//` test, so the `//` in `#/a//b/#` or at the start of `#//a/#` opens none
    /// either. Until #436 this was a quote counter, and a raw string with a `"` and a `//` put it
    /// out of step;
    /// `EngagementRouteTripwireTests.noRawStringHoldsAQuoteAndACommentMarker` still keeps that
    /// shape out of `Sources/AeolusHelper`, as depth.
    static func strippingAllComments(_ source: String) -> String {
        let code = strippingComments(source)
        var output = ""
        var index = code.startIndex

        while index < code.endIndex {
            if let end = regexLiteralEnd(at: index, in: code) {
                output += code[index..<end]
                index = end
            } else if code[index...].hasPrefix("//") {
                while index < code.endIndex, code[index] != "\n" {
                    index = code.index(after: index)
                }
            } else if code[index...].hasPrefix("\"\"\"") {
                index = copyDelimited(code, from: index, delimiter: "\"\"\"", into: &output)
            } else if code[index] == "\"" {
                index = copyDelimited(code, from: index, delimiter: "\"", into: &output)
            } else {
                output.append(code[index])
                index = code.index(after: index)
            }
        }
        return output
    }
}
