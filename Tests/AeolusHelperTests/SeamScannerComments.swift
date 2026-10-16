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
    /// this looks, and on `copyDelimited` for string literals, so the `//` in `"https://…"`
    /// opens no comment. The limits are that walker's, stated at `strippingBlockComments`: a
    /// quote counter and not a lexer, so a raw string with a `"` and a `//` inside it can put it
    /// out of step. None is written in `Sources/AeolusHelper` that way, and
    /// `EngagementRouteTripwireTests.noRawStringHoldsAQuoteAndACommentMarker` fails the day one is.
    static func strippingAllComments(_ source: String) -> String {
        let code = strippingComments(source)
        var output = ""
        var index = code.startIndex

        while index < code.endIndex {
            if code[index...].hasPrefix("//") {
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
