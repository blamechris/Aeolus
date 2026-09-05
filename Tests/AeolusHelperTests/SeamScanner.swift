import Foundation
import Testing

/// Scans `Sources` for function declarations, so a signature can be asserted as a property of
/// the source tree rather than of a call site.
///
/// `WritePathAbsenceTests` had the enumerator and the comment-stripping filter first and now
/// routes through this, rather than the two keeping separate copies that must agree. An
/// earlier version of this comment said "extracted rather than copied" while that extraction
/// had not happened — which was the same failure this whole suite exists to correct, in a
/// doc comment about the suite.
enum SeamScanner {

    struct Declaration {
        let file: String
        let text: String

        /// Just what sits between the parentheses, so an assertion can look at a parameter's
        /// *type position* rather than searching the whole declaration.
        ///
        /// Searching the whole text reads argument labels and sibling type names too, which
        /// is how `engageManualControlForUnlock(ofCommandableFan index: Int)` satisfied a
        /// "names a permit" check while naming no permit at all.
        var parameters: String {
            guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
                open < close
            else { return text }
            return String(text[text.index(after: open)..<close])
        }
    }

    /// One `func` declaration, parsed to its closing parenthesis rather than matched by a
    /// regex that stops at the first `)`.
    ///
    /// The parsed form is what an *allowlist* scan needs and a pattern scan cannot give it.
    /// `declarations(matching:)` can only answer "does anything shaped like this exist"; to
    /// assert that every verb in a target has been acknowledged, each one has to be named —
    /// and naming it means knowing its argument labels and its parameters' types apart from
    /// their labels.
    struct Function {
        let file: String
        let name: String
        /// The external argument labels, in order. `_` for a wildcard, as Swift spells it.
        let labels: [String]
        /// Each parameter's type, with any default value removed — its *type position*,
        /// never its label. `WriteAuthorisationTests` records what reading the whole
        /// declaration instead costs.
        let parameterTypes: [String]
        /// Everything between the closing parenthesis and the body: `async`, `throws`, and
        /// the return type.
        let effects: String
        /// The declaration as written, newlines collapsed, for a failure message.
        let text: String

        var isAsync: Bool { effects.contains("async") }

        /// `File.swift: name(label: Type, label: Type)` — stable across a return-type or
        /// body change, and different for two verbs that differ in their labels **or in
        /// their parameters' types**.
        ///
        /// The types are in the key because an allowlist keyed on `name(label:label:)`
        /// alone cannot see an overload. `SafetyActorWriter.command(_ rpm: Double, of fan:
        /// CommandableFan)` is acknowledged; adding `command(_ rpm: Double, of index: Int)`
        /// beside it — an ungoverned write taking the bare index ADR 0008 removed — produced
        /// the identical key `command(_:of:)`, so it landed on an acknowledged entry and was
        /// invisible to every test in `WriteVerbAllowlistTests`. That is precisely the
        /// silent-addition failure this suite exists to stop, reached by the one route a
        /// label-only key leaves open.
        ///
        /// The two same-file protocol-requirement/conformer pairs the target has —
        /// `LeaseClock.sleep(until:)` and `CriticalTemperatureSensing`'s
        /// `readCriticalTemperatures()` — are written with byte-identical signatures, so they
        /// still collapse onto one key, as `functions(in:)` records.
        var key: String {
            let parameters = zip(labels, parameterTypes)
                .map { "\($0): \($1)" }
                .joined(separator: ", ")
            return "\(file): \(name)(\(parameters))"
        }

        /// Whether any of `names` appears in a parameter's type or in the return type.
        func mentions(anyOf names: [String]) -> Bool {
            (parameterTypes + [effects]).contains { text in names.contains { text.contains($0) } }
        }
    }

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources")
    }

    static func swiftFiles() throws -> [URL] {
        try swiftFiles(under: nil)
    }

    /// Every `.swift` file under `Sources`, or under one target directory of it.
    static func swiftFiles(under target: String?) throws -> [URL] {
        let root = target.map { sourcesRoot.appendingPathComponent($0) } ?? sourcesRoot
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found under \(root.path)")
        return files
    }

    /// Every `func` declared in one target, parsed rather than pattern-matched.
    ///
    /// The three limits, stated rather than discovered later:
    ///
    /// - Comment lines are dropped first, as everywhere else here, so a declaration inside a
    ///   block comment is invisible.
    /// - Two declarations in one file that agree on name and labels — a protocol requirement
    ///   and its conformer in the same file, which is how `LeaseClock` and
    ///   `CriticalTemperatureSensing` are written — share a `key` and collapse when the
    ///   caller puts them in a `Set`.
    /// - `func` is what is scanned, so a computed property is not here. The permit mint is a
    ///   computed `var`; what confines it is `FanWriteAuthorisation.swift`'s access levels,
    ///   asserted by `anAuthorisationTypeCannotBeMintedElsewhere`.
    static func functions(in target: String) throws -> [Function] {
        let expression = try NSRegularExpression(
            pattern: #"func\s+([A-Za-z_]\w*)\s*(<[^>]*>)?\s*\("#)
        var found: [Function] = []

        for file in try swiftFiles(under: target) {
            let code = strippingCommentLines(try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)

            for match in expression.matches(in: code, range: range) {
                guard let whole = Range(match.range, in: code),
                    let nameRange = Range(match.range(at: 1), in: code),
                    let close = closingParenthesis(
                        in: code, openingAt: code.index(before: whole.upperBound))
                else { continue }

                let clause = String(code[whole.upperBound..<close])
                let parameters = topLevelComponents(of: clause).map(splitOnFirstColon(_:))
                let effects = effectsClause(of: code, after: close)
                found.append(
                    Function(
                        file: file.lastPathComponent,
                        name: String(code[nameRange]),
                        labels: parameters.map(\.label),
                        parameterTypes: parameters.map(\.type),
                        effects: effects,
                        text: collapsingWhitespace(
                            String(code[whole.lowerBound...close]) + " " + effects)))
            }
        }
        return found
    }

    /// Every `async` write verb whose name matches `namePattern`.
    ///
    /// `throws` is optional and the effects clause is required: it is what distinguishes a
    /// verb that reaches the firmware from a pure producer of the value it carries. See
    /// `everyTargetWriteVerbTakesAnAuthorisation` for what that buys and what it costs.
    static func writeVerbs(named namePattern: String) throws -> [Declaration] {
        try declarations(matching: #"func\s+"# + namePattern + #"\s*\([^)]*\)\s*async(\s+throws)?"#)
    }

    /// The body of a `struct` declaration, for asserting access levels the compiler will not
    /// report and no runtime test can observe.
    static func structBody(of type: String, in file: String) throws -> String {
        let url = try #require(
            swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try #require(
            source.range(of: #"struct \#(type)[^{]*\{[\s\S]*?\n\}"#, options: .regularExpression),
            "\(type) was not found in \(file)")
        return String(source[body])
    }

    /// Every declaration under `Sources` matching `pattern`.
    ///
    /// Comment lines are dropped first, for the reason `WritePathAbsenceTests` records: the
    /// prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps. The trade is
    /// that a declaration inside a block comment is invisible — contrived, where an added
    /// verb is not.
    static func declarations(matching pattern: String) throws -> [Declaration] {
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [Declaration] = []

        for file in try swiftFiles() {
            let code = strippingCommentLines(try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for match in expression.matches(in: code, range: range) {
                guard let matched = Range(match.range, in: code) else { continue }
                found.append(
                    Declaration(
                        file: file.lastPathComponent,
                        text: String(code[matched]).replacingOccurrences(of: "\n", with: " ")))
            }
        }
        return found
    }

    // MARK: - Parsing

    /// Source with whole-line comments removed.
    ///
    /// The prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps.
    private static func strippingCommentLines(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The `)` that closes the `(` at `open`, at the correct nesting depth.
    ///
    /// This is what `\([^)]*\)` cannot do, and the gap is not theoretical: a parameter of
    /// closure type or one defaulted to `= .init()` carries a `)` of its own, so the pattern
    /// scan does not match such a declaration **at all** — it goes silently uncounted rather
    /// than failing. `docs/ADR/0008` calls that out and
    /// [#120](https://github.com/blamechris/Aeolus/issues/120) asks for it to be parsed.
    private static func closingParenthesis(
        in code: String, openingAt open: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = open
        var inStringLiteral = false

        while index < code.endIndex {
            let character = code[index]
            if inStringLiteral {
                if character == "\"" { inStringLiteral = false }
            } else {
                switch character {
                case "\"": inStringLiteral = true
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The effects clause and return type: everything from the closing parenthesis to the
    /// body or the end of the line.
    ///
    /// Stopping at the newline is what keeps a protocol requirement — which has no `{` at
    /// all — from swallowing the declaration beneath it. A clause the formatter has wrapped
    /// onto its own line is picked up from there instead, and only when that line begins
    /// with a keyword that can legally start one.
    private static func effectsClause(of code: String, after close: String.Index) -> String {
        func line(from start: String.Index) -> (text: String, end: String.Index) {
            var text = ""
            var index = start
            while index < code.endIndex, code[index] != "\n", code[index] != "{" {
                text.append(code[index])
                index = code.index(after: index)
            }
            return (text.trimmingCharacters(in: .whitespaces), index)
        }

        let first = line(from: code.index(after: close))
        guard first.text.isEmpty, first.end < code.endIndex, code[first.end] == "\n" else {
            return first.text
        }
        let wrapped = line(from: code.index(after: first.end)).text
        let starters = ["async", "throws", "rethrows", "->"]
        return starters.contains(where: wrapped.hasPrefix) ? wrapped : first.text
    }

    /// A comma-separated clause split at depth zero, so a `[String: Int]` or a `() -> Void`
    /// stays in one piece.
    private static func topLevelComponents(of clause: String) -> [String] {
        var components: [String] = []
        var current = ""
        var depth = 0
        var previous: Character = " "

        for character in clause {
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]": depth -= 1
            // The `>` of a return arrow closes nothing; only a generic bracket's does.
            case ">" where previous != "-": depth -= 1
            default: break
            }
            if character == "," && depth == 0 {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        components.append(current)
        return
            components
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One parameter's external label and its type, split at the colon that separates them.
    ///
    /// Depth-aware for the same reason as above: `_ handler: (Int) -> Void` and
    /// `at priority: [String: Int]` both carry a colon that is not the separator.
    private static func splitOnFirstColon(_ parameter: String) -> (label: String, type: String) {
        var depth = 0
        var previous: Character = " "
        var index = parameter.startIndex

        while index < parameter.endIndex {
            let character = parameter[index]
            switch character {
            case "(", "[", "<": depth += 1
            case ")", "]": depth -= 1
            case ">" where previous != "-": depth -= 1
            case ":" where depth == 0:
                let names = parameter[..<index].split(separator: " ")
                var type = String(parameter[parameter.index(after: index)...])
                if let defaulted = type.range(of: " = ") {
                    type = String(type[..<defaulted.lowerBound])
                }
                return (
                    String(names.first ?? ""),
                    type.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            default: break
            }
            previous = character
            index = parameter.index(after: index)
        }
        return (parameter, "")
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
