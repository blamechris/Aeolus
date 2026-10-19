import Foundation

/// The comment stripper a receiver scan needs, beside `SeamScanner` and not in it: that enum is
/// at its `type_body_length` ceiling, and `SeamScannerScopes` is the precedent for a sibling
/// file holding more of the same type.
extension SeamScanner {

    /// Source with every comment removed, a `//` comment **trailing code** included.
    ///
    /// `strippingComments` leaves a trailing comment in place, because the prose explaining a
    /// rule is usually a whole line. A scan that reads a *receiver* cannot leave it.
    /// `writer  // driver` on one line and `.engageManualControl(of:)` on the next normalise
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

    /// The `//` comment at `start`, which the walker has met as code: copied to `output` as it
    /// stands when it trails code, and dropped, with its own newline, when it is the whole of its
    /// line. Returns where the walker resumes.
    ///
    /// **Whole line** means only blanks precede it in `output` since the last newline, so a block
    /// comment before it on the line, which the walker has turned into a space, does not make it a
    /// trailing one. The line leaves with the newline that ends it, or, at the end of the source,
    /// with the one before it: the lines that remain are as they were when this was a filter over
    /// the source split on newlines (`SeamScannerCommentLineTests.aDroppedLineTakesItsOwnNewline`).
    /// This is not offered a line inside a literal, which `copyDelimited` has carried across whole
    /// (#457).
    static func copyOrDropLineComment(
        in source: String, from start: String.Index, into output: inout String
    ) -> String.Index {
        let lineStart =
            output.lastIndex(of: "\n").map { output.index(after: $0) } ?? output.startIndex
        let wholeLine = output[lineStart...].allSatisfy {
            $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
        }
        if wholeLine { output.removeSubrange(lineStart...) }

        var index = start
        while index < source.endIndex, source[index] != "\n" {
            if !wholeLine { output.append(source[index]) }
            index = source.index(after: index)
        }
        guard wholeLine else { return index }
        if index < source.endIndex { return source.index(after: index) }
        if output.last == "\n" { output.removeLast() }
        return index
    }
}
