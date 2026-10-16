import Foundation

/// The write-verb scan, beside `SeamScanner` and not in it: that enum is at its
/// `type_body_length` ceiling, and `SeamScannerComments` and `SeamScannerScopes` are the
/// precedent for a sibling file holding more of the same type.
extension SeamScanner {

    /// Every `async` write verb whose name matches `namePattern`.
    ///
    /// `throws` is optional and the effects clause is required: it is what distinguishes a
    /// verb that reaches the firmware from a pure producer of the value it carries. See
    /// `everyTargetWriteVerbTakesAnAuthorisation` for what that buys and what it costs.
    static func writeVerbs(named namePattern: String) throws -> [Declaration] {
        var found: [Declaration] = []
        for file in try swiftFiles() {
            found += try writeVerbs(
                named: namePattern,
                inSource: try String(contentsOf: file, encoding: .utf8),
                file: file.lastPathComponent)
        }
        return found
    }

    /// `writeVerbs(named:)`'s scan, over one file's text.
    ///
    /// **The parameter list is found by balanced-parenthesis scanning, not by a pattern.** The
    /// first spelling matched it with `\([^)]*\)`, which ends at the first `)`, so a default
    /// value with a call in it — `under lease: UUID = UUID()` — made the verb match nothing and
    /// drop out of the population the permit assertions run over
    /// ([#362](https://github.com/blamechris/Aeolus/issues/362)). A closure-typed parameter did
    /// something worse: the pattern ended inside the closure's own `()` and listed the verb with
    /// half its parameters, so an assertion judged a signature nobody wrote. A generic clause
    /// dropped the verb too, since `\s*\(` wants the `(` straight after the name.
    ///
    /// The name is matched by pattern, and the list by `parameterListStart` and
    /// `closingParenthesis` — the pair `functions(inSource:file:)` is built on, so the two scans
    /// cannot disagree about where a list ends. A pattern need not guard its own end: the list
    /// must open straight after the name (a generic clause aside), so `engage` does not list
    /// `engageManualControl`. The effects clause is then required to follow the closing
    /// parenthesis directly: an unanchored search for `async` would let a synchronous
    /// requirement borrow the next declaration's.
    ///
    /// Comments are removed **including a trailing one** (`strippingAllComments`), because a `(`
    /// in `of fan: CommandableFan,  // the fan (see ADR 0008` is counted by the balance walk and
    /// would lose the list's real close. String literals are walked by both that stripper and
    /// `closingParenthesis`, so a `)` or a `//` inside a default value opens and closes nothing.
    /// Both are quote counters and not lexers, with the limit stated at `strippingBlockComments`.
    static func writeVerbs(
        named namePattern: String, inSource source: String, file: String
    ) throws -> [Declaration] {
        let verb = try NSRegularExpression(pattern: #"func\s+(?:"# + namePattern + #")"#)
        let effects = try NSRegularExpression(pattern: #"\s*async(\s+throws)?"#)
        let code = strippingAllComments(source)
        var found: [Declaration] = []

        for match in verb.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code),
                let open = parameterListStart(in: code, after: whole.upperBound),
                let close = closingParenthesis(in: code, openingAt: open),
                let tail = effects.firstMatch(
                    in: code, options: .anchored,
                    range: NSRange(code.index(after: close)..., in: code)),
                let tailEnd = Range(tail.range, in: code)?.upperBound
            else { continue }

            found.append(
                Declaration(
                    file: file,
                    text: String(code[whole.lowerBound..<tailEnd])
                        .replacingOccurrences(of: "\n", with: " ")))
        }
        return found
    }
}
