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

    /// The sibling of `sourcesRoot`, for the tripwires whose subject is the **suite** rather
    /// than the tree it scans.
    ///
    /// There is one such invariant today — nothing under `Tests/` may construct the real
    /// signal sources, because doing so would `SIG_IGN` this process's `SIGTERM` permanently
    /// — and it was enforced by a doc comment until #197's review pointed out that a doc
    /// comment is not enforcement.
    static var testsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AeolusHelperTests
            .deletingLastPathComponent()  // Tests
    }

    static func swiftFiles() throws -> [URL] {
        try swiftFiles(under: nil)
    }

    /// Every `.swift` file under `Sources`, or under one target directory of it.
    static func swiftFiles(under target: String?) throws -> [URL] {
        let root = target.map { sourcesRoot.appendingPathComponent($0) } ?? sourcesRoot
        return try swiftFiles(beneath: root)
    }

    /// Every `.swift` file under one target directory of `Tests`.
    static func swiftFiles(underTests target: String) throws -> [URL] {
        try swiftFiles(beneath: testsRoot.appendingPathComponent(target))
    }

    /// Every `.swift` file under **every** test target.
    ///
    /// The sibling above takes one target because its callers assert about one. A tripwire whose
    /// subject is "no test anywhere may do this" needs the whole tree instead, and naming today's
    /// targets in the caller would make it blind to tomorrow's — which is the failure
    /// `HelperClientDeadlineLiteralTests` exists to prevent, reached by the one route a fixed list
    /// leaves open.
    static func swiftFilesUnderTests() throws -> [URL] {
        try swiftFiles(beneath: testsRoot)
    }

    private static func swiftFiles(beneath root: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]))
        let entries = enumerator.compactMap { $0 as? URL }
        refuseSymbolicLinks(in: entries, under: root)
        let files = entries.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the project's sources were not found under \(root.path)")
        return files
    }

    /// A symbolic link under a scanned root is refused, not followed: the enumerator does not
    /// descend into a linked directory, and SwiftPM compiles what is behind one, so a suite behind
    /// a link would build and be scanned by nothing (#436's review).
    static func refuseSymbolicLinks(in entries: [URL], under root: URL) {
        for entry in entries
        where (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            Issue.record(
                """
                \(entry.path) is a symbolic link under \(root.lastPathComponent)/. SwiftPM \
                compiles what it points at, and these scans do not follow it.
                """)
        }
    }

    /// Every `func` declared in one target, parsed rather than pattern-matched.
    ///
    /// The limits, stated rather than discovered later — and each of them checked against
    /// the parser rather than assumed of it, in `SeamScannerParsingTests`:
    ///
    /// - Comments are dropped first, as everywhere else here, so a declaration inside a
    ///   `//` line **or a `/* … */` span** is invisible. An earlier version of this bullet
    ///   claimed the same of block comments while `strippingCommentLines` removed only whole
    ///   `//` lines, which had it exactly backwards: prose showing a forbidden signature
    ///   inside `/* … */` was scanned as a declaration.
    /// - A comment **trailing** a declaration is dropped from the effects clause and nowhere
    ///   else: `effectsClause(of:after:)` truncates at `//`. Until #177 it did not, and the
    ///   trailing comment did not merely reach the clause — it *became* the clause, so a
    ///   wrapped `async throws` on the next line was never read and the verb dropped out of
    ///   the population. Elsewhere the whole-line rule still stands, which is what keeps the
    ///   prose explaining a rule from tripping the rule.
    /// - A **`subscript`** is not `func`, so neither it nor its `get async throws` accessor
    ///   is scanned. None in `Sources/AeolusHelper` today; one returning a permit would be
    ///   invisible, exactly as a computed property is.
    /// - A **stored closure** is not `func` either. A `let write: (CommandableFan) async
    ///   throws -> Void` capturing the plane is a verb by any useful definition and is not
    ///   here. What confines it is the same thing that confines the permit mint:
    ///   `FanWriteAuthorisation.swift`'s access levels.
    /// - The converse, and the direction that is safe: a `func` written **inside a string
    ///   literal** is scanned as a declaration, because `strippingComments` preserves string
    ///   literals rather than parsing them. That adds a phantom to the population, which
    ///   fails loudly on the allowlist rather than hiding anything.
    /// - Two declarations in one file with byte-identical signatures — a protocol
    ///   requirement and its conformer in the same file, which is how `LeaseClock` and
    ///   `CriticalTemperatureSensing` are written — share a `key` and collapse when the
    ///   caller puts them in a `Set`. An *overload* no longer collapses: `key` carries the
    ///   parameter types.
    /// - `func <name>` is what is scanned, so an **operator** declaration is not here:
    ///   `SafetyPrecedence.swift`'s `static func < (lhs:rhs:)` is the one in this target.
    ///   It is synchronous and takes no permit, so it is outside the population either way;
    ///   an operator that took one would be invisible.
    /// - `func` is what is scanned, so a computed property is not here. The permit mint is a
    ///   computed `var`; what confines it is `FanWriteAuthorisation.swift`'s access levels,
    ///   asserted by `anAuthorisationTypeCannotBeMintedElsewhere`.
    static func functions(in target: String) throws -> [Function] {
        var found: [Function] = []
        for file in try swiftFiles(under: target) {
            found += try functions(
                inSource: try String(contentsOf: file, encoding: .utf8),
                file: file.lastPathComponent)
        }
        return found
    }

    /// `functions(in:)`'s parser, over one file's text.
    ///
    /// Separated from the enumeration so the limits above can be asserted against fixtures
    /// rather than against whatever `Sources` happens to contain today — a parser tested
    /// only through the tree it scans is tested only for the shapes already written.
    static func functions(inSource source: String, file: String) throws -> [Function] {
        let expression = try NSRegularExpression(pattern: #"func\s+([A-Za-z_]\w*)"#)
        let code = strippingComments(source)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        var found: [Function] = []

        for match in expression.matches(in: code, range: range) {
            guard let whole = Range(match.range, in: code),
                let nameRange = Range(match.range(at: 1), in: code),
                let open = parameterListStart(in: code, after: whole.upperBound),
                let close = closingParenthesis(in: code, openingAt: open)
            else { continue }

            let clause = String(code[code.index(after: open)..<close])
            let split = parameters(in: clause)
            let effects = effectsClause(of: code, after: close)
            found.append(
                Function(
                    file: file,
                    name: String(code[nameRange]),
                    labels: split.map(\.label),
                    parameterTypes: split.map(\.type),
                    effects: effects,
                    text: collapsingWhitespace(
                        String(code[whole.lowerBound...close]) + " " + effects)))
        }
        return found
    }

    /// The body of a `struct` declaration, for asserting access levels the compiler will not
    /// report and no runtime test can observe.
    static func structBody(of type: String, in file: String) throws -> String {
        let url = try #require(
            swiftFiles().first { $0.lastPathComponent == file },
            "\(file) is not in the source tree")
        return try structBody(
            of: type, inSource: try String(contentsOf: url, encoding: .utf8), file: file)
    }

    /// `structBody(of:in:)`'s parse, over one file's text.
    ///
    /// **The name is matched whole.** `struct \(type)` with nothing after it is a *prefix*
    /// match, and `range(of:)` answers the first one in the file, so `structBody(of: "Fan", …)`
    /// resolved to whichever of `Fan` and `FanState` came first in `Fan.swift` — and a
    /// `FanStateReport` added above `FanState` would silently hand every caller the wrong
    /// struct's body. The consequence is worse for the callers than for the parser:
    ///
    /// - `HelperClientStateSeamTests.theFanStateListNamesEveryTypeTheseDTOsCarry` is the check
    ///   that makes the forbidden lists "self-maintaining rather than hand-written". Reading a
    ///   colliding struct's fields instead audits a type nobody asked about, finds them all
    ///   accounted for, and stays **green** — so the audited type's own fields go on being
    ///   validated by nothing, which is exactly the gap that hid `FanControlMode` for a review
    ///   round. A completeness check that can read the wrong type is not one.
    /// - `WriteAuthorisationTests.anAuthorisationTypeCannotBeMintedElsewhere` counts the stored
    ///   properties of `CommandableFan` and `AuthorisedFanTarget` to decide who can mint a write
    ///   permit. Auditing a neighbour with the same field count would pass on a type nobody
    ///   checked.
    ///
    /// Today's tree matches by luck — `Fan` precedes `FanState`, `FanTargetRPM` precedes
    /// `FanControlEnvelope` — and declaration order is not a thing a guard may depend on.
    ///
    /// The limits: the body ends at the first `\n}` in column zero, so this reads a **top-level**
    /// struct and a nested one is part of its parent's body; and an `extension` of the type is not
    /// its declaration and is not read.
    static func structBody(of type: String, inSource source: String, file: String) throws -> String
    {
        let body = try #require(
            source.range(
                of: #"struct \#(type)(?![A-Za-z0-9_])[^{]*\{[\s\S]*?\n\}"#,
                options: .regularExpression),
            "\(type) was not found in \(file)")
        return String(source[body])
    }

    /// Every declaration under `Sources` matching `pattern`.
    ///
    /// Comments are dropped first, for the reason `WritePathAbsenceTests` records: the
    /// prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps. The trade is
    /// that a declaration inside a comment is invisible — contrived, where an added verb is
    /// not.
    static func declarations(matching pattern: String) throws -> [Declaration] {
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [Declaration] = []

        for file in try swiftFiles() {
            let code = strippingComments(try String(contentsOf: file, encoding: .utf8))
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

    /// The unstructured `Task { … }` and `Task.detached { … }` spawn sites in one file's
    /// text.
    ///
    /// An unstructured task is the one route around "a synchronous function cannot `await`",
    /// so `WriteVerbAllowlistTests` counts the sites to keep a new one from arriving
    /// unremarked. It lives here, taking source rather than a URL, for the reason every other
    /// primitive does: the first spelling of the pattern —
    /// `\bTask(\.detached)?\s*(\([^()]*\))?\s*\{` — did not match `Task<Void, Never> { … }`,
    /// which is a **legal spelling of exactly the thing being counted**, so the count it
    /// asserted was not the count it claimed. No spawn site in the target is written that way
    /// today; the *type* is — `ThermalSupervisor.swift`'s `private var task: Task<Void,
    /// Never>?` — which is the whole difficulty, since the spelling is already in the
    /// maintainer's hand and nothing would have reported the site it hid. A pattern nothing
    /// puts a fixture through is a pattern whose misses are invisible.
    ///
    /// **The pattern is `WriteSeamSpellingTests.taskSpawn`**, the one the write-turn job scan
    /// reads, so the two cannot disagree about what a spawn is (#442's review, S1). The pattern
    /// this had matched `Task` only when a `{` followed an argument list, which missed
    /// `Task(operation: { … })` and `Task.detached(priority:, operation: { … })`: neither has a
    /// `{` straight after its parentheses, and a closure holds parentheses of its own. This
    /// census is what notices a `Task` spawned through a helper function that a write-turn job
    /// calls, which the job scan cannot see.
    ///
    /// The source is read as code: comments, trailing ones included, and string literals are
    /// removed first, so the word in prose is not a site. Reading a `Task` *type* as a spawn is
    /// possible in principle — a protocol's `var t: Task<Void, Never> {` would match — and is
    /// **fail-loud**: the count rises, the message names the file, and a maintainer looks. A
    /// missed spawn is the direction that fails silently, so the pattern errs wide.
    static func unstructuredTaskSpawns(inSource source: String) throws -> Int {
        try RuleZeroScan.count(WriteSeamSpellingTests.taskSpawn, in: RuleZeroScan.code(of: source))
    }

    // MARK: - Parsing

    /// Source with comments removed: every `/* … */` span, replaced by one space, and every
    /// whole line that is a `//` comment **where the lexer is reading code**.
    ///
    /// The prose describing a forbidden signature is not that signature, and a tripwire that
    /// fires on the sentence explaining the rule is a tripwire nobody keeps. That argument
    /// applies to a block comment exactly as it applies to a line comment, and until #177
    /// only the line half was implemented while three doc comments claimed both — so a
    /// signature quoted inside `/* … */` was scanned as a declaration and would have
    /// reddened the tripwire it was explaining.
    ///
    /// A line is dropped when only blanks precede its `//` on its line of the source — a block
    /// comment before it, which the walker has turned into a space, is blank
    /// (`SeamScannerCommentLineTests` pins `/* x */ // c`), and the text after `\(` in an
    /// interpolation is not a line of its own — and the walker reaches that `//` as code. A line
    /// of a multi-line string literal
    /// that begins `//` is the literal's text, and an interpolation on it is code: filtering lines
    /// by their text, before the literal walker had looked, removed such a line and the call in
    /// it, so no rule-zero scan saw a `production` in `"""` / `//\(X.production(log: L()))` /
    /// `"""` (#457). A **trailing** `//` comment is left in place, because the prose that explains
    /// a rule is usually a whole line; `strippingAllComments` says what leaving it costs a
    /// receiver scan, and removes it.
    ///
    /// **A source with a carriage return is refused** (`refuseCarriageReturns(in:file:)`), so the
    /// walker never has to say where a `\r` ends a comment.
    ///
    /// `internal` rather than `private` so `SeamScannerParsingTests` can put a fixture
    /// through it. Nothing in `Sources` contains a block comment today, so the tree cannot
    /// exercise this and a test that only scans the tree cannot know it works.
    static func strippingComments(_ source: String) -> String {
        refuseCarriageReturns(in: source)
        return strippingBlockAndLineComments(source)
    }

    /// Every `/* … */` span replaced by one space, and every `//` comment that is the whole of its
    /// line removed with its newline. The space is what the lexer sees: a comment separates
    /// tokens, so `public/* */import` is `public import` (#442's review, S3).
    ///
    /// Swift nests block comments, so the depth is counted rather than the first `*/` taken.
    /// The text of a string literal — `"""` spans included — and a `//` comment **trailing code**
    /// are copied through untouched: a `/*` inside either opens nothing, and treating one as an
    /// opener would swallow the rest of the file.
    ///
    /// **A whole-line `//` comment is judged here, where the walker knows it is reading code.** A
    /// `//` the walker meets is outside every literal's text and every regex, so a line of a
    /// multi-line literal that begins `//` is never offered: `copyDelimited` has already carried
    /// the whole literal across. `copyOrDropLineComment` drops the comment when it is the whole of
    /// its line (#457; this was a filter on each line's text, run after the walker, which could
    /// not tell a literal's line from a comment).
    ///
    /// **An interpolation is code, so this walks it too.** `copyDelimited` hands the code of each
    /// interpolation back to this function, and a comment in it — a line, a trailing one or a
    /// block — is dropped or kept as it would be outside a literal, with one difference:
    /// `startsLine` is false for it, because its first line follows `\(`. A `//` right after `\(`
    /// trails code, as Swift reads it, and keeps its newline (#460's review, B1).
    ///
    /// Literals are walked by `copyDelimited`, which reads raw delimiters and interpolations (see
    /// it), so a `"` inside `"\(row["key"])"` or `#"a "b"#` does not end the literal early, and
    /// regex literals by `regexLiteralEnd`, so `/"/` and `#/a//b/#` are text. With no block
    /// comment anywhere in `Sources`, `depth` never rises and the only change to the input is
    /// the whole-line comments dropped — `SeamScannerParsingTests`'
    /// `noBlockCommentIsWrittenInSources` fails the day one is written.
    private static func strippingBlockAndLineComments(
        _ source: String, startsLine: Bool = true
    ) -> String {
        var output = ""
        var index = source.startIndex
        var depth = 0

        func matches(_ token: String, at position: String.Index) -> Bool {
            source[position...].hasPrefix(token)
        }

        while index < source.endIndex {
            if depth > 0 {
                if matches("/*", at: index) {
                    depth += 1
                    index = source.index(index, offsetBy: 2)
                } else if matches("*/", at: index) {
                    depth -= 1
                    index = source.index(index, offsetBy: 2)
                } else {
                    if source[index] == "\n" { output.append("\n") }
                    index = source.index(after: index)
                }
                continue
            }

            // A regex first: `#//a/#` is an extended regex whose text begins `//`, not a comment
            // (#436's delta review, S2). A bare `/` followed by `/` or `*` opens no regex, so
            // comments are unaffected.
            if let end = regexLiteralEnd(at: index, in: source) {
                output += source[index..<end]
                index = end
            } else if matches("/*", at: index) {
                // One space per span, as Swift's lexer reads it: `public/* */import` is two
                // words, and joined they are one that no pattern for `import` finds (#442, S3).
                output.append(" ")
                depth = 1
                index = source.index(index, offsetBy: 2)
            } else if matches("//", at: index) {
                index = copyOrDropLineComment(
                    in: source, from: index, into: &output, startsLine: startsLine)
            } else if source[index] == "\"" {
                let delimiter = matches("\"\"\"", at: index) ? "\"\"\"" : "\""
                index = copyDelimited(source, from: index, delimiter: delimiter, into: &output) {
                    strippingBlockAndLineComments(String(source[$0]), startsLine: false)
                }
            } else {
                output.append(source[index])
                index = source.index(after: index)
            }
        }
        return output
    }

    /// The `(` that opens a declaration's parameter list, skipping a generic clause.
    ///
    /// A regex spelling of that clause as `<[^>]*>` cannot span a nested `>`, so
    /// `func read<T: Decoding<Wire>>(…)` matched nothing at all and went **silently
    /// uncounted** — the same failure mode as `\([^)]*\)` on a nested `)`, and the reason an
    /// allowlist cannot be built on either.
    static func parameterListStart(
        in code: String, after name: String.Index
    ) -> String.Index? {
        var index = name
        while index < code.endIndex, code[index].isWhitespace {
            index = code.index(after: index)
        }
        guard index < code.endIndex else { return nil }

        if code[index] == "<" {
            var depth = 0
            var previous: Character = " "
            while index < code.endIndex {
                switch code[index] {
                case "<": depth += 1
                // The `>` of a return arrow closes nothing, so a constraint that is itself a
                // function type — `func command<T: Sequence<() -> Void>>(…)` — must not read
                // as closing the clause early. `topLevelComponents` has carried this guard
                // from the start; without it here the `(` was never found, the declaration
                // went **silently uncounted**, and a permit-bearing verb written that way was
                // invisible to the whole allowlist.
                case ">" where previous != "-": depth -= 1
                // A generic parameter list contains neither; either one means this `<` was
                // never opening one, so give up rather than run to the end of the file.
                case "{", ";": return nil
                default: break
                }
                previous = code[index]
                index = code.index(after: index)
                if depth == 0 { break }
            }
            while index < code.endIndex, code[index].isWhitespace {
                index = code.index(after: index)
            }
        }
        guard index < code.endIndex, code[index] == "(" else { return nil }
        return index
    }

    /// The `)` that closes the `(` at `open`, at the correct nesting depth.
    ///
    /// This is what `\([^)]*\)` cannot do, and the gap is not theoretical: a parameter of
    /// closure type or one defaulted to `= .init()` carries a `)` of its own, so the pattern
    /// scan does not match such a declaration **at all** — it goes silently uncounted rather
    /// than failing. `docs/ADR/0008` calls that out and
    /// [#120](https://github.com/blamechris/Aeolus/issues/120) asks for it to be parsed.
    ///
    /// A parenthesis inside a string literal is not counted, and a `\` inside one escapes the
    /// character after it — as `copyDelimited` does for the comment stripper, so the two
    /// agree on where a literal ends. Without that, a default of `"\")"` ended its literal at
    /// the escaped quote, took the `)` after it for the list's close, and the verb dropped out
    /// of the population ([#362](https://github.com/blamechris/Aeolus/issues/362)). A quote
    /// counter and not a lexer: a `"` inside an interpolation still ends the literal early.
    static func closingParenthesis(
        in code: String, openingAt open: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = open
        var inStringLiteral = false

        while index < code.endIndex {
            let character = code[index]
            if inStringLiteral {
                if character == "\\", code.index(after: index) < code.endIndex {
                    index = code.index(after: index)
                } else if character == "\"" {
                    inStringLiteral = false
                }
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
    ///
    /// A `//` comment **trailing** the parameter list is dropped here, because
    /// `strippingComments` removes only whole `//` lines. Until #177 it was not, and the
    /// consequence was not cosmetic: a comment on the parameter-list line made the clause
    /// look non-empty, so the wrapped line beneath it was never read, and
    /// `func commandUngoverned(_ rpm: Double, of index: Int)  // ungoverned` carrying its
    /// `async throws -> CommandedTarget` on the next line parsed as **not `async`** and left
    /// the population altogether. Nothing that may legally follow a parameter list contains
    /// `//`, so truncating there costs nothing — and a `{` inside that comment must not end
    /// the line either, or the wrapped clause is lost by the same route.
    private static func effectsClause(of code: String, after close: String.Index) -> String {
        func line(from start: String.Index) -> (text: String, end: String.Index) {
            var text = ""
            var index = start
            var commented = false

            while index < code.endIndex, code[index] != "\n" {
                if commented {
                    index = code.index(after: index)
                    continue
                }
                if code[index] == "{" { break }
                let next = code.index(after: index)
                if code[index] == "/", next < code.endIndex, code[next] == "/" {
                    commented = true
                    index = next
                    continue
                }
                text.append(code[index])
                index = next
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

    /// A parameter clause split into each parameter's external label and its type.
    ///
    /// `internal` rather than `private` so `MemberAccessScan` can compose a member's signature
    /// from the same parse `Function.key` is built on. A second depth-aware parameter split,
    /// agreeing with this one only by inspection, is precisely the arrangement this type's own
    /// doc comment records replacing.
    static func parameters(in clause: String) -> [(label: String, type: String)] {
        topLevelComponents(of: clause).map(splitOnFirstColon(_:))
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
            // Clamped at zero, because a default value may carry a bare `>` that closes
            // nothing: `_ rpm: Double = 1 > 0 ? 1 : 2` drove the depth negative, so the comma
            // after it was no longer at depth zero and every later parameter was swallowed
            // into the first component. A verb written that way reported **one** parameter —
            // so a permit in its second named no permit, and the verb was invisible to
            // `onlyAcknowledgedVerbsNameAPermit`.
            case ")", "]": depth = max(0, depth - 1)
            // The `>` of a return arrow closes nothing; only a generic bracket's does.
            case ">" where previous != "-": depth = max(0, depth - 1)
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
            // Clamped for `topLevelComponents`' reason: a bare `>` in a default value closes
            // nothing, and a negative depth here would hide the colon that separates the
            // label from the type.
            case ")", "]": depth = max(0, depth - 1)
            case ">" where previous != "-": depth = max(0, depth - 1)
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

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Member uses

extension SeamScanner {

    /// The receiver of every use of `member` in one file's code — a call, a call split across
    /// lines (`writer\n    .member(of:`), one with a space before its parenthesis, an unapplied
    /// method reference (`writer.member`), an optional-chained or force-unwrapped receiver
    /// (`writer?.member`, `writer!.member`) and a parenthesised one (`(writer).member`) alike.
    ///
    /// Comments are stripped — trailing ones too — and whitespace around each `.`, `?.` and
    /// `!.` removed first, so the spelling of a use cannot hide it: a scan anchored on
    /// `receiver.member(` missed every one of these shapes. A declaration (`func member(`) has
    /// no receiver and is not a use.
    ///
    /// **A use whose receiver is not a word is not attributed**: a call result
    /// (`makeWriter().member`), a subscript (`writers[0].member`), and a bare `member(of:)` inside
    /// the type that declares it have no `word.` in front. `mentions(of:inSource:)` counts those,
    /// and a caller that must not miss one compares the two.
    static func receivers(of member: String, inSource source: String) throws -> [String] {
        let stripped = strippingAllComments(source)
        let code = try NSRegularExpression(pattern: #"\s*([?!]?)\s*\.\s*"#)
            .stringByReplacingMatches(
                in: stripped, range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: "$1.")
        let use = try NSRegularExpression(
            pattern: #"(\w+)\s*\)?[?!]?\."# + member + #"(?![A-Za-z0-9_])"#)
        return use.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        }
    }

    /// How many times `member` is named in one file's code other than in a declaration,
    /// whatever stands in front of it.
    ///
    /// The receiver-agnostic count behind `receivers(of:inSource:)`. That scan needs a word and
    /// a `.`; this one needs the identifier. A use on a call result, on a subscript, or with no
    /// receiver at all is counted here and attributed there to nothing, so `mentions` minus
    /// `receivers.count` is the number of uses a receiver scan cannot see. Comments are stripped
    /// first, trailing ones included, and `func member` is a declaration and not a use.
    ///
    /// A mention inside a string literal counts, which errs loud: it can only add a failure
    /// that names the file.
    static func mentions(of member: String, inSource source: String) throws -> Int {
        let code = strippingAllComments(source)
        let range = NSRange(code.startIndex..., in: code)
        let named = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])"# + member + #"(?![A-Za-z0-9_])"#)
        let declared = try NSRegularExpression(
            pattern: #"\bfunc\s+"# + member + #"(?![A-Za-z0-9_])"#)
        return named.numberOfMatches(in: code, range: range)
            - declared.numberOfMatches(in: code, range: range)
    }
}
