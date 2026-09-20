import Foundation

/// `SeamScanner`'s **scope** half: which braces a declaration sits inside, and where a
/// function's body ends.
///
/// Split from `SeamScanner.swift` along a real seam rather than a line count. Everything
/// there answers *what a declaration says* — a signature, its parameters' types, its effects
/// clause — from a pattern or a parse of the declaration alone. Everything here answers
/// *where the declaration is*, which no amount of reading one declaration can settle: a
/// `let` is a member or a local depending entirely on the braces above it, and the two are
/// written identically.
///
/// It is one type across two files, so four of `SeamScanner`'s parsing primitives are
/// `internal` rather than `private`: `private` at type scope does not reach an extension in
/// another file, and a second copy of a brace matcher is the defect this whole suite exists
/// to catch.
extension SeamScanner {

    // MARK: - Properties

    /// One `var` or `let` declared **outside every function body**: a type's member, or a
    /// file-level global.
    ///
    /// The distinction is the whole subject. `HelperClientVerbs.swift` decodes a
    /// `SystemSnapshot` into a local in the verb that asked for one and must go on doing so;
    /// the same type *stored* on the actor is the rule-6 defect
    /// `HelperClientStateSeamTests.theClientStoresNoFanState` exists to catch. The two read almost
    /// identically, which is why a pattern scan cannot tell them apart and this is parsed.
    struct Property {
        let file: String
        let name: String
        /// The type as written, or `""` where the declaration leaves it to inference.
        let type: String
        /// The initialiser expression as written, or `""` where there is none.
        ///
        /// Read alongside the type rather than instead of it, because `let cached =
        /// SystemSnapshot(…)` names its type nowhere else: a type-position-only scan does
        /// not see that declaration at all, and inference is the one spelling an author
        /// reaches for without thinking about it.
        ///
        /// A brace-delimited initialiser is collected **whole**, newlines and all — see
        /// `fragment(in:from:stoppingAt:)` for why a line-bounded one was an evasion this
        /// repository's own formatter forced. One consequence, deliberate: a stored property
        /// written `= .idle { didSet { … } }` carries its observer's body here too. An
        /// observer is part of what the declaration says, and a `didSet` that names a
        /// forbidden type is a declaration worth reporting.
        let initialiser: String
        /// Whether the declaration has storage. A computed property and a protocol
        /// requirement do not; a `willSet`/`didSet` observer does not stop one having it.
        let isStored: Bool
        /// The declaration as written, newlines collapsed, for a failure message.
        let text: String

        /// Every identifier in the type position and in the initialiser.
        ///
        /// Split on everything that cannot be part of a name, so a membership test reads
        /// **whole** names. `Lease` is a prefix of `LeaseRequest`, so a forbidden-name list
        /// checked with `contains(_:)` against the raw text is silently a list of prefixes —
        /// and the reverse mistake is worse: such a list fires on every `LeaseRequest` too,
        /// which is how a tripwire earns a reputation for crying wolf and then gets deleted.
        /// `[UUID: Lease]` reports `UUID` and `Lease`; `Task<Lease, Error>` reports `Lease`
        /// too.
        var names: [String] { SeamScanner.identifiers(in: type + " " + initialiser) }
    }

    /// Every identifier in `text`, split on everything that cannot be part of a name.
    ///
    /// One copy, because `Property.names` and `TypeAlias.names` compare against the same
    /// forbidden lists and a list checked by two different splitters is two lists.
    static func identifiers(in text: String) -> [String] {
        text
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
    }

    /// Every `var` and `let` declared outside a function body in one target.
    static func properties(in target: String) throws -> [Property] {
        var found: [Property] = []
        for file in try swiftFiles(under: target) {
            found += properties(
                inSource: try String(contentsOf: file, encoding: .utf8),
                file: file.lastPathComponent)
        }
        return found
    }

    /// `properties(in:)`'s parser, over one file's text.
    ///
    /// A brace stack, not a regex, because the property this answers is *scope*: every
    /// enclosing brace must have been opened by a type declaration. The `{` of a `func`, an
    /// `init`, a `switch`, a `do` or a trailing closure all open something a local may live
    /// in, and `Sources/AeolusXPCClient` is full of locals whose text is indistinguishable
    /// from the members this forbids.
    ///
    /// Which brace is which is decided by the **last keyword before it**, rather than by the
    /// header's first word: the text since the previous brace routinely contains earlier
    /// declarations, so `private var generation: UInt64 = 0` sitting above `private struct
    /// ConnectionGeneration {` must not make that a function body. A header naming no
    /// keyword at all — `AsyncStream {`, `Task {` — is not a type.
    ///
    /// The limits, stated rather than discovered later, and each one checked against a
    /// fixture in `SeamScannerParsingTests`:
    ///
    /// - Comments are dropped first, as everywhere else here, so a declaration written in
    ///   prose is invisible. That is the direction that fails safe.
    /// - A string literal is skipped wholesale and contributes **nothing** to the header, to
    ///   the type, or to the initialiser: a `struct` or a `{` inside one cannot flip a scope,
    ///   its text is not scanned for declarations, and `names` cannot read a type out of
    ///   prose. `Property.text` still quotes the declaration as written, literal included,
    ///   because that is what a failure message has to show.
    /// - An **`enum case` with an associated value is not scanned.** `case cached(
    ///   SystemSnapshot)` on a case-carrying enum is storage by any useful definition and is
    ///   not here; what would catch it is the stored property of that enum type, which is,
    ///   and the value has to be reachable from somewhere to be served.
    /// - A **tuple binding** — `let (a, b) = …` — is skipped rather than guessed at: there is
    ///   no single name to record. None in the target.
    /// - A declaration whose type is left to inference has `type == ""` and its initialiser
    ///   instead, which is why `names` reads both. A **multi-line** initialiser is read to its
    ///   closing brace, so the type named only inside `= { … }()` is read too: a line-bounded
    ///   initialiser made that spelling invisible, and it is the only spelling of a substantial
    ///   initialiser the repository's 100-column formatter accepts.
    /// - `willSet`/`didSet` keep `isStored`; `get`/`set` and a bare getter do not. A stored
    ///   property with an observer read as computed would be the one silent miss here, so the
    ///   first keyword inside the accessor block is what decides it, not the brace.
    static func properties(inSource source: String, file: String) -> [Property] {
        let code = strippingComments(source)
        // One entry per open brace: whether a type declaration opened it.
        var scopes: [Bool] = []
        // The text since the last brace or `;` — the candidate header for the next one.
        var header = ""
        var found: [Property] = []
        var index = code.startIndex

        while index < code.endIndex {
            let character = code[index]

            if character == "\"" {
                header.append(" ")
                index = endOfStringLiteral(in: code, from: index)
                continue
            }
            if character == "{" {
                scopes.append(headerOpensAType(header))
                header = ""
                index = code.index(after: index)
                continue
            }
            if character == "}" {
                if !scopes.isEmpty { scopes.removeLast() }
                header = ""
                index = code.index(after: index)
                continue
            }
            if character == ";" {
                header = ""
                index = code.index(after: index)
                continue
            }
            guard character.isLetter || character == "_" else {
                header.append(character)
                index = code.index(after: index)
                continue
            }

            let wordEnd = identifier(in: code, from: index)
            let word = String(code[index..<wordEnd])
            header += word
            if word == "var" || word == "let", scopes.allSatisfy({ $0 }),
                let property = property(in: code, declaredAt: index, after: wordEnd, file: file)
            {
                found.append(property)
            }
            // Carried on from the keyword rather than from the end of the declaration just
            // parsed, so the type, the initialiser and any accessor block are walked by the
            // loop as well. That is what keeps a computed property's braces — and a trailing
            // closure's — pushing the non-type scope their header describes.
            index = wordEnd
        }
        return found
    }

    /// One `var`/`let` declaration, from just after its keyword.
    ///
    /// A backtick-escaped name is read without its backticks, so `` `default` `` is a
    /// declaration and not a gap. It was a gap until this line existed, and the gap is not
    /// academic: escaping is exactly how a property whose name collides with a keyword gets
    /// written, and a scan that skipped those would report a shorter population without
    /// saying so.
    private static func property(
        in code: String, declaredAt keyword: String.Index, after start: String.Index, file: String
    ) -> Property? {
        var index = skippingWhitespace(in: code, from: start)
        if index < code.endIndex, code[index] == "`" { index = code.index(after: index) }
        guard index < code.endIndex, code[index].isLetter || code[index] == "_" else { return nil }
        let nameEnd = identifier(in: code, from: index)
        let name = String(code[index..<nameEnd])
        index = skippingWhitespace(in: code, from: nameEnd)
        if index < code.endIndex, code[index] == "`" {
            index = skippingWhitespace(in: code, from: code.index(after: index))
        }

        var type = ""
        if index < code.endIndex, code[index] == ":" {
            let parsed = fragment(in: code, from: code.index(after: index), stoppingAt: ["=", "{"])
            type = parsed.text
            index = parsed.end
        }

        var initialiser = ""
        var isStored = true
        if index < code.endIndex, code[index] == "=" {
            let parsed = fragment(in: code, from: code.index(after: index), stoppingAt: [])
            initialiser = parsed.text
            index = parsed.end
        } else {
            let accessor = skippingWhitespace(in: code, from: index)
            if accessor < code.endIndex, code[accessor] == "{" {
                isStored = observesStorage(in: code, accessorAt: accessor)
            }
        }

        return Property(
            file: file,
            name: name,
            type: type,
            initialiser: initialiser,
            isStored: isStored,
            text: collapsingWhitespace(String(code[keyword..<index])))
    }

    /// Whether an accessor block belongs to a **stored** property: `willSet`/`didSet` observe
    /// storage, `get`/`set` and a bare getter replace it.
    private static func observesStorage(in code: String, accessorAt open: String.Index) -> Bool {
        let index = skippingWhitespace(in: code, from: code.index(after: open))
        guard index < code.endIndex, code[index].isLetter else { return false }
        let word = String(code[index..<identifier(in: code, from: index)])
        return word == "willSet" || word == "didSet"
    }

    /// Whether the text before a `{` declares a type, decided by the last keyword in it.
    private static func headerOpensAType(_ header: String) -> Bool {
        let typeKeywords: Set<String> = [
            "struct", "class", "actor", "enum", "extension", "protocol",
        ]
        let bodyKeywords: Set<String> = [
            "func", "var", "let", "init", "deinit", "subscript", "if", "guard", "while", "for",
            "switch", "case", "do", "else", "catch", "repeat", "defer", "get", "set", "willSet",
            "didSet", "return", "in",
        ]
        let words =
            header
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
        guard
            let last = words.last(where: { typeKeywords.contains($0) || bodyKeywords.contains($0) })
        else { return false }
        return typeKeywords.contains(last)
    }

    // MARK: - Type aliases

    /// One `typealias`: the name it introduces, and every identifier in the type it stands for.
    ///
    /// A forbidden-type tripwire compares a declaration's identifiers against a list of type
    /// names, and an alias is the one construct that puts a *different* name on a listed type
    /// without wrapping it in anything. `private typealias Remembered = SystemSnapshot` followed
    /// by `private var last: Remembered?` reports the identifier `Remembered`, which is on no
    /// list — so the client stores a snapshot and `theClientStoresNoFanState` says nothing. That
    /// was verified on a scratch type in `Sources/AeolusXPCClient`, and the lease half escaped
    /// with it, because `held: Grant?` splits to no `lease` word either.
    struct TypeAlias {
        let file: String
        let name: String
        /// Every identifier in the aliased type, by `Property.names`' own rule.
        let names: [String]
    }

    /// Every `typealias` under `Sources`, or under one target of it.
    ///
    /// Read across the whole tree rather than one target by default, because an alias does not
    /// have to be declared where it is used: `public typealias Grant = Lease` in `FanKit` is
    /// nameable from every client of it, and a resolver that only read the storing target would
    /// close the shorter route while leaving the one an author reaches for when the alias is
    /// meant to be shared.
    ///
    /// The limits: an alias declared **outside `Sources`** — in a dependency, or in the test
    /// target — is not resolved, and an alias to a nested type is resolved by its identifiers, so
    /// `A.B` contributes both `A` and `B`. The first is the direction that fails open and is
    /// stated rather than closed; a forbidden DTO is declared in this tree by construction.
    static func typeAliases(in target: String?) throws -> [TypeAlias] {
        var found: [TypeAlias] = []
        for file in try swiftFiles(under: target) {
            found += typeAliases(
                inSource: try String(contentsOf: file, encoding: .utf8),
                file: file.lastPathComponent)
        }
        return found
    }

    /// `typeAliases(in:)`'s parser, over one file's text.
    ///
    /// Comments are dropped and string literals are stepped over, as everywhere else here: the
    /// prose in these targets discusses a remembered snapshot at length, and a tripwire that
    /// resolves an alias written in a sentence is a tripwire that fires on its own explanation.
    ///
    /// The right-hand side goes through `fragment(in:from:stoppingAt:)`, the same collector the
    /// initialiser half uses, so a wrapped alias is read past its first line for the same reason
    /// a wrapped initialiser is.
    static func typeAliases(inSource source: String, file: String) -> [TypeAlias] {
        let code = strippingComments(source)
        var found: [TypeAlias] = []
        var index = code.startIndex

        while index < code.endIndex {
            if code[index] == "\"" {
                index = endOfStringLiteral(in: code, from: index)
                continue
            }
            guard code[index].isLetter || code[index] == "_" else {
                index = code.index(after: index)
                continue
            }
            let wordEnd = identifier(in: code, from: index)
            guard String(code[index..<wordEnd]) == "typealias" else {
                index = wordEnd
                continue
            }
            guard let alias = typeAlias(in: code, after: wordEnd, file: file) else {
                index = wordEnd
                continue
            }
            found.append(alias.alias)
            index = alias.end
        }
        return found
    }

    /// One `typealias` declaration, from just after its keyword.
    private static func typeAlias(
        in code: String, after start: String.Index, file: String
    ) -> (alias: TypeAlias, end: String.Index)? {
        var index = skippingWhitespace(in: code, from: start)
        if index < code.endIndex, code[index] == "`" { index = code.index(after: index) }
        guard index < code.endIndex, code[index].isLetter || code[index] == "_" else { return nil }
        let nameEnd = identifier(in: code, from: index)
        let name = String(code[index..<nameEnd])

        // To the `=`. A generic parameter clause — `typealias Pair<T> = (T, T)` — contains none,
        // so scanning for the first one needs no bracket accounting; a declaration that reaches a
        // newline, a `;` or a `{` first is not an alias assignment and is refused rather than
        // guessed at.
        var equals = nameEnd
        while equals < code.endIndex, !"=\n;{".contains(code[equals]) {
            equals = code.index(after: equals)
        }
        guard equals < code.endIndex, code[equals] == "=" else { return nil }

        let aliased = fragment(in: code, from: code.index(after: equals), stoppingAt: [])
        return (
            TypeAlias(file: file, name: name, names: identifiers(in: aliased.text)), aliased.end
        )
    }

    // MARK: - Function bodies

    /// The body of the `func` named `name`, brace-matched from its declaration — the text
    /// between its braces, exclusive.
    ///
    /// `nil` when the name is not declared in this source, or when what follows its parameter
    /// list is not a body. A caller asserting the absence of something *inside* a function
    /// must treat that as a failure rather than as an empty scan: a tripwire over a body it
    /// could not find is a tripwire that passes because it looked at nothing, which is exactly
    /// how a renamed function silently drops its guard.
    ///
    /// The limits: the first declaration of the name **that has a body** wins, so an overload
    /// is not distinguished; and a body includes every closure written inside it, which is
    /// deliberate — a retry loop spawned in a `Task { … }` inside the send path is the send
    /// path.
    ///
    /// **Every** declaration of the name is tried, rather than only the first, and that is a
    /// correctness fix rather than a generalisation. `HelperConnectionPinning.swift` declares
    /// the protocol requirement `func pinnedConnection(over:)` above
    /// `SignedHelperPinning.pinnedConnection`, so a first-match scan answered `nil` for the one
    /// function in this target that builds a connection — and the send-path suite's
    /// `sendPath()` dropped it from the population without a word. A three-attempt retry of
    /// `transport.makeConnection()`, which is the boot-loop amplifier that test exists to
    /// forbid, was green. The requirement and the conformer are written in that order because
    /// the protocol comes first in the file, which is the ordinary way to write one.
    static func functionBody(named name: String, inSource source: String) throws -> String? {
        let code = strippingComments(source)
        let declaration = try NSRegularExpression(pattern: #"func\s+\#(name)\b"#)
        let matches = declaration.matches(
            in: code, range: NSRange(code.startIndex..<code.endIndex, in: code))
        for match in matches {
            guard let whole = Range(match.range, in: code),
                let open = parameterListStart(in: code, after: whole.upperBound),
                let close = closingParenthesis(in: code, openingAt: open),
                let body = bodyStart(in: code, after: close),
                let end = closingBrace(in: code, openingAt: body)
            else { continue }
            return String(code[code.index(after: body)..<end])
        }
        return nil
    }

    /// The `{` that opens a body, or `nil` if a `}` arrives first — a declaration with no body
    /// of its own, as a protocol requirement is.
    private static func bodyStart(in code: String, after close: String.Index) -> String.Index? {
        var index = code.index(after: close)
        while index < code.endIndex {
            if code[index] == "{" { return index }
            if code[index] == "}" { return nil }
            index = code.index(after: index)
        }
        return nil
    }

    /// The `}` that closes the `{` at `open`, at the correct nesting depth, with string
    /// literals skipped.
    private static func closingBrace(in code: String, openingAt open: String.Index) -> String.Index?
    {
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "\"" {
                index = endOfStringLiteral(in: code, from: index)
                continue
            }
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - Small movements

    /// Where the identifier beginning at `start` ends.
    private static func identifier(in code: String, from start: String.Index) -> String.Index {
        var index = start
        while index < code.endIndex,
            code[index].isLetter || code[index].isNumber || code[index] == "_"
        {
            index = code.index(after: index)
        }
        return index
    }

    private static func skippingWhitespace(
        in code: String, from start: String.Index
    )
        -> String
        .Index
    {
        var index = start
        while index < code.endIndex, code[index].isWhitespace { index = code.index(after: index) }
        return index
    }

    /// Where the string literal opening at `start` ends, `"""` spans and `\` escapes honoured.
    ///
    /// Shares `copyDelimited`'s quote-counting limit and its consequence: a `"` inside an
    /// interpolation ends the literal early. Reaching the end of the source rather than the end
    /// of a literal returns `endIndex`, so a caller terminates either way.
    private static func endOfStringLiteral(
        in code: String, from start: String.Index
    )
        -> String
        .Index
    {
        var discarded = ""
        let delimiter = code[start...].hasPrefix("\"\"\"") ? "\"\"\"" : "\""
        return copyDelimited(code, from: start, delimiter: delimiter, into: &discarded)
    }

    /// A type or an initialiser, collected at depth zero and stopped by the first of
    /// `terminators`, a `;`, or a newline once something balanced has been collected.
    ///
    /// The newline rule is what lets a wrapped type — a `:` with the type on the line below —
    /// still be read, while a complete declaration does not run on into the next one.
    ///
    /// **A `{` the caller did not name as a terminator opens a brace depth, and the newline rule
    /// is suspended inside it.** Without that, an initialiser is cut off at the end of its first
    /// line, and `private var lastSnapshot = {` is a complete initialiser as far as this parser
    /// is concerned: the closure below it contributes nothing, so a stored `SystemSnapshot?`
    /// whose type is written only inside the closure is invisible to
    /// `theClientStoresNoFanState`. That is not a contrived spelling — `.swift-format`'s
    /// `lineLength` is 100, so an initialiser of any substance **has** to be broken across lines
    /// to be accepted by the formatter this repository gates on, and the one-line form that this
    /// parser did catch is the one form that cannot merge. A guard evaded by the house style is a
    /// guard that only ever fires on a spelling nobody can commit.
    ///
    /// Braces are counted separately from `(`/`[`/`<`, and the bracket accounting is switched off
    /// while a brace is open, because the clamped `>` rule below is a guess that is right in a
    /// type position and wrong in a closure body: one `if count > 3` inside the closure would
    /// otherwise drop the depth back to zero and truncate the initialiser at the next newline,
    /// which is the same hole one level in.
    ///
    /// **`<`/`>` are counted apart from `(`/`[` for the same reason, one level out.** A `>` that
    /// closes nothing is clamped at zero, and while the two shared one counter that clamp was
    /// applied to the sum — so a `>` inside a parenthesised continuation cancelled the `(` that
    /// opened it. `= scratchMake(\n    isHot: 1 > 0,\n    snapshot: SystemSnapshot(…)\n)` dropped
    /// to depth zero on the comparison and was cut off at the newline after it, so the stored
    /// `SystemSnapshot` on the line below was invisible to `theClientStoresNoFanState`. Separate
    /// counters make a bare comparison unable to close a bracket it never opened, while a wrapped
    /// generic — `: Task<\n    Lease, Error\n>?` — still holds the continuation open on the angle
    /// count alone. The three delimiters the formatter actually emits for a long initialiser —
    /// paren, bracket, and brace — were each read correctly before this and still are; what was
    /// wrong was a comparison written *inside* one of them.
    ///
    /// A `{` that *is* named as a terminator still terminates — that is how the type half stops
    /// at a computed property's accessor block — so this widens the initialiser half alone.
    private static func fragment(
        in code: String, from start: String.Index, stoppingAt terminators: Set<Character>
    ) -> (text: String, end: String.Index) {
        var depth = 0
        var angles = 0
        var braces = 0
        var text = ""
        var index = start
        var previous: Character = " "

        while index < code.endIndex {
            let character = code[index]
            if character == "\"" {
                // Skipped, and its text is **not** collected. A string literal cannot be the
                // type of a stored property or construct one, so nothing a caller asks of a
                // type position can be answered from inside it — while a literal that
                // *describes* a forbidden declaration is exactly what a tripwire's own failure
                // message and this suite's fixtures are made of. Collecting it made
                // `private var detail = "… SystemSnapshot? …"` report `SystemSnapshot`, which
                // is a tripwire firing on prose about itself.
                text.append(" ")
                previous = " "
                index = endOfStringLiteral(in: code, from: index)
                continue
            }
            if character == "{", !terminators.contains("{") {
                braces += 1
            } else if character == "}" {
                braces = max(0, braces - 1)
            } else if braces == 0 {
                switch character {
                case "(", "[": depth += 1
                case "<": angles += 1
                case ")", "]": depth = max(0, depth - 1)
                // Clamped at zero and blind to a `>` that closes nothing, for
                // `topLevelComponents`' reasons: a return arrow's `>` and a bare `>` in a default
                // value both drive an unclamped count negative, and a negative one here loses the
                // terminator that ends the declaration. Clamped on its **own** counter, so the
                // clamp cannot spend a `(` that a comparison never opened.
                case ">" where previous != "-": angles = max(0, angles - 1)
                default: break
                }
            }
            if depth == 0, angles == 0, braces == 0 {
                if character == ";" || terminators.contains(character) { break }
                if character == "\n", !text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            }
            text.append(character)
            previous = character
            index = code.index(after: index)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), index)
    }
}
