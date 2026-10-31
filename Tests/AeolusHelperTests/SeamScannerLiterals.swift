import Foundation
import Testing

/// The one string-literal walker every scan here shares, in a sibling file of `SeamScanner` for
/// that enum's length.
extension SeamScanner {

    /// Copies a literal opened at `open` — its `delimiter`, everything up to the matching close,
    /// and the close — and answers where to carry on.
    ///
    /// **A raw literal is read as raw.** The `#`s that open `#"…"#`, `##"…"##` or `#"""…"""#` sit
    /// immediately before `open`, already copied by the caller as code, so they are counted from
    /// there: the literal closes only at its quote followed by as many `#`, and a `\` is text
    /// unless those `#` follow it. Before #436's review this read `#"SMC "write path"#` as a
    /// literal that ended at the second quote, and the code after it as prose.
    ///
    /// **An interpolation is code.** `\(…)` — `\#(…)` in a raw literal — is walked to its balanced
    /// `)`, with any literal inside it walked by this same function, so `"\(row["key"])"` does not
    /// end at the inner quote. Its range is reported through `interpolations`, so a caller that
    /// drops a literal's text can still keep the call inside it.
    ///
    /// **A comment in an interpolation is a comment.** The walk skips one, so a `)`, a `(` or a `"`
    /// in it neither closes the interpolation early nor opens a literal. What is copied to
    /// `output` for an interpolation's code is up to `interpolation`, which the two comment
    /// strippers set to themselves (#460): until then it was copied as it stood, and a comment
    /// holding `;try #require(…)` was read as code. The other callers copy to discard, or read
    /// stripped source, and take the text as it stands.
    ///
    /// **It fails loudly.** A source that ends inside a literal or an interpolation, or a
    /// single-line literal that reaches a newline outside an interpolation, records an issue
    /// rather than returning code that was silently cut short.
    ///
    /// `internal` rather than `private`: every scan in this target uses it, and a second walker is
    /// precisely the drift this suite exists to catch.
    static func copyDelimited(
        _ source: String, from open: String.Index, delimiter: String, into output: inout String
    ) -> String.Index {
        copyDelimited(source, from: open, delimiter: delimiter, into: &output) { code in
            String(source[code])
        }
    }

    /// `copyDelimited(_:from:delimiter:into:)`, reporting each interpolation's code.
    static func copyDelimited(
        _ source: String, from open: String.Index, delimiter: String, into output: inout String,
        interpolations: inout [Range<String.Index>]
    ) -> String.Index {
        copyDelimited(source, from: open, delimiter: delimiter, into: &output) { code in
            interpolations.append(code)
            return String(source[code])
        }
    }

    /// `copyDelimited(_:from:delimiter:into:)`, with the code of each interpolation — a range of
    /// `source` — handed to `interpolation`, and the text it returns copied to `output` in its
    /// place: how the comment strippers walk it with themselves.
    static func copyDelimited(
        _ source: String, from open: String.Index, delimiter: String, into output: inout String,
        interpolation copied: (Range<String.Index>) -> String
    ) -> String.Index {
        let hashes = String(repeating: "#", count: rawHashes(before: open, in: source))
        let closing = delimiter + hashes
        let escape = "\\" + hashes
        var index = source.index(open, offsetBy: delimiter.count)
        output.append(delimiter)

        while index < source.endIndex {
            if source[index...].hasPrefix(closing) {
                output.append(closing)
                return source.index(index, offsetBy: closing.count)
            }
            if source[index...].hasPrefix(escape) {
                let after = source.index(index, offsetBy: escape.count)
                if after < source.endIndex, source[after] == "(" {
                    let close = interpolationEnd(in: source, openingAt: after)
                    output += source[index...after]
                    output += copied(source.index(after: after)..<close)
                    guard close < source.endIndex else {
                        index = close
                        continue
                    }
                    output.append(")")
                    index = source.index(after: close)
                    continue
                }
                let end = after < source.endIndex ? source.index(after: after) : after
                output += source[index..<end]
                index = end
                continue
            }
            if delimiter == "\"", source[index] == "\n" {
                Issue.record("a single-line string literal reaches a newline unclosed")
                return index
            }
            output.append(source[index])
            index = source.index(after: index)
        }
        Issue.record("the source ends inside a string literal")
        return index
    }

    /// How many `#` immediately precede `index`: a raw literal's opening delimiter.
    static func rawHashes(before index: String.Index, in source: String) -> Int {
        var count = 0
        var position = index
        while position > source.startIndex {
            let previous = source.index(before: position)
            guard source[previous] == "#" else { break }
            count += 1
            position = previous
        }
        return count
    }

    /// Where a regex literal opened by the `/` at `index` ends — just past its closing delimiter —
    /// or `nil` when none opens there (#436's review: `let quote = #/"/#` put every quote-counting
    /// scan out of step for the rest of the file).
    ///
    /// - `#/…/#`, `##/…/##`: the `#`s precede `index`, already copied by the caller as code, as a
    ///   raw string's are. It closes at a `/` followed by as many `#`; it may span lines only when
    ///   a newline follows its opening `/`, as Swift's own rule has it. One that never closes
    ///   records an issue.
    /// - `/…/`: only where `opensBareRegex` says the `/` cannot be dividing, and only when it
    ///   closes on its own line. Swift reads an unclosed bare `/` as an operator, and so does this.
    /// - In both, a `\` escapes the character after it, so `/a\/b/` is one literal.
    static func regexLiteralEnd(at index: String.Index, in source: String) -> String.Index? {
        guard source[index] == "/" else { return nil }
        let hashes = rawHashes(before: index, in: source)
        guard hashes > 0 || opensBareRegex(at: index, in: source) else { return nil }
        let closing = "/" + String(repeating: "#", count: hashes)
        var position = source.index(after: index)
        let spansLines = hashes > 0 && position < source.endIndex && source[position] == "\n"
        while position < source.endIndex {
            if source[position] == "\\" {
                position =
                    source.index(position, offsetBy: 2, limitedBy: source.endIndex)
                    ?? source.endIndex
                continue
            }
            if source[position] == "\n", !spansLines {
                guard hashes > 0 else { return nil }
                Issue.record("a single-line #/ regex literal reaches a newline unclosed")
                return position
            }
            if source[position...].hasPrefix(closing) {
                return source.index(position, offsetBy: closing.count)
            }
            position = source.index(after: position)
        }
        guard hashes > 0 else { return nil }
        Issue.record("the source ends inside a regex literal")
        return position
    }

    /// Whether the `/` at `index` can open a bare regex literal, `/…/`, rather than divide: it is
    /// followed by something other than a space, `/`, `*`, `=` or a closing bracket or separator,
    /// and what precedes it is not an operand — an operator, an opening bracket, a separator, a
    /// keyword that starts an expression, or nothing. `reduce(64, /)` passes the operator itself,
    /// which is not a regex (#436's final review, N1).
    static func opensBareRegex(at index: String.Index, in source: String) -> Bool {
        guard source[index] == "/" else { return false }
        let next = source.index(after: index)
        guard next < source.endIndex, !" \t\n/*=),;]}".contains(source[next]) else {
            return false
        }
        let before = source[..<index].reversed().drop { $0.isWhitespace }
        guard let last = before.first else { return true }
        if last.isLetter || last.isNumber || last == "_" {
            let word = String(before.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
            return expressionKeywords.contains(word)
        }
        return !")]}\"`".contains(last)
    }

    private static let expressionKeywords: Set<String> = [
        "return", "case", "in", "try", "await", "throw", "where", "if", "guard", "while", "else",
        "repeat", "is", "as", "some", "any",
    ]

    /// The `)` that closes the interpolation opened at `open`, with every literal inside walked
    /// rather than counted and every comment skipped, or the end of the source — recorded as an
    /// issue — if it has none.
    ///
    /// A regex is tried before a comment, as the comment walkers try it: `#//a/#` is a regex whose
    /// text begins `//`. A comment is skipped, so the `))` in `f(1, // ))` closes nothing; counted,
    /// they ended the interpolation at the comment, and the rest of it was read as the literal's
    /// text by that walk (#460).
    private static func interpolationEnd(
        in source: String, openingAt open: String.Index
    ) -> String.Index {
        var depth = 0
        var index = open
        var discarded = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" {
                let delimiter = source[index...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
                index = copyDelimited(source, from: index, delimiter: delimiter, into: &discarded)
                continue
            }
            if let end = regexLiteralEnd(at: index, in: source) {
                index = end
                continue
            }
            if source[index...].hasPrefix("//") {
                index = source[index...].firstIndex(of: "\n") ?? source.endIndex
                continue
            }
            if source[index...].hasPrefix("/*") {
                index = blockCommentEnd(in: source, from: index)
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        Issue.record("the source ends inside a string interpolation")
        return index
    }

    /// Where the `/* … */` comment opened at `index` ends — just past its closing `*/` — or the end
    /// of the source if it has none. Swift nests block comments, so the depth is counted rather
    /// than the first `*/` taken.
    private static func blockCommentEnd(
        in source: String, from index: String.Index
    ) -> String.Index {
        var depth = 0
        var position = index
        while position < source.endIndex {
            if source[position...].hasPrefix("/*") {
                depth += 1
                position = source.index(position, offsetBy: 2)
            } else if source[position...].hasPrefix("*/") {
                depth -= 1
                position = source.index(position, offsetBy: 2)
                if depth == 0 { return position }
            } else {
                position = source.index(after: position)
            }
        }
        return position
    }
}
