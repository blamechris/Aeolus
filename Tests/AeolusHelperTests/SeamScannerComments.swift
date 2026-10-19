import Foundation
import Testing

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
    ///
    /// **A trailing comment in an interpolation goes too.** The code of an interpolation is code,
    /// so `copyDelimited` hands it back to the walk below, and the `// note` in an interpolation
    /// that reads `\(f(1 // note` and ends on the next line is removed as it would be outside a
    /// literal (#460).
    static func strippingAllComments(_ source: String) -> String {
        strippingTrailingComments(strippingComments(source))
    }

    /// `strippingAllComments`' walk, over source whose block and whole-line comments are gone.
    private static func strippingTrailingComments(_ code: String) -> String {
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
                index = copyDelimited(code, from: index, delimiter: "\"\"\"", into: &output) {
                    strippingTrailingComments(String(code[$0]))
                }
            } else if code[index] == "\"" {
                index = copyDelimited(code, from: index, delimiter: "\"", into: &output) {
                    strippingTrailingComments(String(code[$0]))
                }
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
    ///
    /// **`startsLine` says whether the start of `output` is the start of a line.** It is for a
    /// source, and not for the code of an interpolation, whose first line follows `\(`: Swift
    /// reads `\( // c` as a comment trailing code, so with no newline in `output` yet the comment
    /// is not the whole of its line, and keeps its newline (#460's review, B1).
    static func copyOrDropLineComment(
        in source: String, from start: String.Index, into output: inout String,
        startsLine: Bool = true
    ) -> String.Index {
        let lastNewline = output.lastIndex(of: "\n")
        let lineStart = lastNewline.map { output.index(after: $0) } ?? output.startIndex
        let wholeLine =
            (lastNewline != nil || startsLine)
            && output[lineStart...].allSatisfy {
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

    /// Records an issue when `source` holds a carriage return, and carries on.
    ///
    /// Swift ends a line at `\n`, at `\r` and at `\r\n`; this walker ends a `//` comment at `\n`
    /// only, and `\r\n` is a single `Character` that is not `\n`. So the code after a `\r` was part
    /// of the comment before it, invisible to every scan. The choice was between teaching the
    /// walker, and every `\n` test in `copyDelimited`, `regexLiteralEnd` and the scans that read
    /// what it returns, that `\r` and `\r\n` end a line too, and refusing the source, **failing
    /// closed** as one that ends inside a literal is. The second: it is one check, at the front of
    /// the walk, and the tree has no carriage return in a `.swift` file, so it costs nothing today.
    ///
    /// **Where the file is named.** The lexer is given a string and cannot name it.
    /// `RuleZeroScan.files(under:)` refuses per file, with its path, for every scan that reads
    /// through it, and `SeamScannerInterpolationCommentTests.noFileInTheTreeHoldsACarriageReturn`
    /// names each `.swift` file under `Sources`, `Tests` and `Tools` and each package manifest
    /// (`Package.swift`, `Package@swift-*.swift`) that holds one. So does
    /// `grep -rl $'\r' Sources Tests Tools Package*.swift`.
    ///
    /// **The scans with a stripper of their own do not refuse it.** `ToolsSeamScanner` in
    /// `PowerObserverTests`, `SMCSamplerTests` and `AppIconTests`, `XPCDeclarationNormaliser` and
    /// `PayloadRefusalTests` in `IntegrationTests`, and `StampSiteScanner` in `SMCCoreTests` read
    /// files under the same three directories. A carriage return in one is a red in the tree test
    /// above, in this target, and not in theirs.
    ///
    /// - Returns: whether it refused, for a caller that has the file and would rather not read it.
    @discardableResult
    static func refuseCarriageReturns(in source: String, file: String? = nil) -> Bool {
        guard holdsCarriageReturn(source) else { return false }
        Issue.record(
            """
            \(file ?? "the source") holds a carriage return, which the comment walker does not \
            read as a line end: refused rather than read with the code after it taken for a comment
            """)
        return true
    }

    /// Whether `source` holds a `\r`. The test is on `utf8`: `\r\n` is a single `Character`, so a
    /// `String` holding it does not `contains("\r")`.
    static func holdsCarriageReturn(_ source: String) -> Bool {
        source.utf8.contains(0x0D)
    }
}
