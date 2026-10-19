import Foundation

/// The declarations written at the outermost level of some Swift code, each with its attributes,
/// its modifiers and the body it opens, read off source the way every seam scan reads it.
///
/// Two guards are built on it. `WriteSeamTestIsolationTests`' rule 5 holds every top-level
/// declaration in the test files that can name the SMC write to `private`, so the compiler
/// refuses another file that calls a helper there. `SMCRequestConstructionTests` holds
/// `SMCConnection.Request` to its members, its one initialiser `private`.
///
/// ## How it reads
///
/// Comments and string literals go first, by the normalisation the seam scans share. Backticks
/// stay: `` `private` `` is a name, and a name must never pass for the modifier. The code is then
/// read as tokens at bracket depth 0. A `{…}`, `(…)` or `[…]` is one token holding its text, so
/// nothing inside a body, an argument list or a literal is outermost.
///
/// A declaration is found by its **introducer**, and `introducers` is every keyword Swift 6.4
/// declares with. A declaration is not found by a pattern for one spelling of it. Its attributes
/// and modifiers are the run of them written immediately before the introducer, read backwards,
/// so `private` on the line above counts and a `private` that belongs to an earlier declaration
/// does not.
///
/// ## What fails closed, and what it cannot see
///
/// What the census cannot read goes in `Census.unreadable` rather than being skipped: a bracket
/// that does not balance, and a `#` directive other than conditional compilation's, because a
/// freestanding macro can declare anything. A modifier this census does not know ends the run, so
/// a `private` written before it is not seen and the declaration reads as not private. Every
/// incomplete list errs towards red.
///
/// It reads source, not expansions. An attached macro's peers are not read; the attached macros
/// the guarded files use are Swift Testing's, which expand inside the declaration they annotate.
/// A declaration kind added to Swift after 6.4 has an introducer this list lacks, and is not seen.
enum DeclarationCensus {

    /// One declaration at the outermost level the census read.
    struct Declaration: Equatable {
        /// The keyword that declares it: `struct`, `func`, `let`, `extension`, `init`, ….
        let introducer: String
        /// What follows the introducer, dotted: `SMCConnection`, `SMCCore.SMCKeyType`, `bytes`.
        /// Empty where nothing is named, as for `init` or a tuple pattern.
        let name: String
        /// Each attribute's name, dotted, without its argument: `Suite`, `Testing.Test`.
        let attributes: [String]
        /// Each modifier as written, a parenthesised argument included: `private(set)` is not
        /// `private`.
        let modifiers: [String]
        /// The text inside the `{…}` the declaration opens, if it opens one. Already read as code,
        /// so `DeclarationCensus.outermost(inCode:)` takes it as it is.
        let body: String?

        /// `private` and nothing wider, written bare. `private(set)` restricts a setter and leaves
        /// the getter at the declaration's level, so it does not count, and neither does
        /// `fileprivate`: the guards built on this census want `private`, the form swift-format's
        /// `FileScopedDeclarationPrivacy` keeps at file scope.
        var isPrivate: Bool {
            modifiers.contains("private")
                && !modifiers.contains { Self.otherAccessLevels.contains($0) }
        }

        static let otherAccessLevels: Set<String> = [
            "fileprivate", "internal", "package", "public", "open",
        ]
    }

    struct Census: Equatable {
        let declarations: [Declaration]
        /// What the census could not read, each a short description for a failure message. A
        /// caller fails on any.
        let unreadable: [String]
    }

    /// Every keyword Swift 6.4 introduces a declaration with, `import` aside, which declares
    /// nothing another file can name. The member-only ones (`init`, `case`, `subscript`, …) are
    /// here too, so a census of a type's body sees every member.
    static let introducers: Set<String> = [
        "actor", "associatedtype", "case", "class", "deinit", "enum", "extension", "func", "init",
        "let", "macro", "operator", "precedencegroup", "protocol", "struct", "subscript",
        "typealias", "var",
    ]

    /// The introducers that are not reserved words, so a constant may be named after one.
    static let contextualIntroducers: Set<String> = ["actor", "macro"]

    /// The words that may stand between a declaration's attributes and its introducer:
    /// `MemberAccessScan`'s modifiers, the access levels it handles apart, and the operator
    /// fixities.
    static let modifiers: Set<String> = MemberAccessScan.ignorableModifiers.union([
        "private", "fileprivate", "prefix", "infix", "postfix",
    ])

    /// The only `#` directives that declare nothing.
    static let conditionalCompilation: Set<String> = ["if", "elseif", "else", "endif"]

    /// The outermost declarations of a whole file's `source`.
    static func outermost(inSource source: String) -> Census {
        outermost(
            inCode: WriteSeamTestIsolationTests.strippingStringLiterals(
                SeamScanner.strippingAllComments(source)))
    }

    /// The outermost declarations of `code` that is already free of comments and string literals:
    /// a `Declaration.body`, for one.
    static func outermost(inCode code: String) -> Census {
        let read = tokens(in: code)
        var unreadable = read.unreadable
        var declarations: [Declaration] = []
        for index in read.tokens.indices {
            if let directive = unknownDirective(at: index, in: read.tokens) {
                unreadable.append(directive)
            }
            if let declaration = declaration(introducedAt: index, in: read.tokens) {
                declarations.append(declaration)
            }
        }
        return Census(declarations: declarations, unreadable: unreadable)
    }

    // MARK: - Declarations

    private static func declaration(introducedAt index: Int, in tokens: [Token]) -> Declaration? {
        guard case .word(let introducer) = tokens[index], introducers.contains(introducer) else {
            return nil
        }
        // `import struct SMCCore.SMCKey` imports; it declares nothing.
        if index > 0, tokens[index - 1] == .word("import") { return nil }
        var next: String?
        if index + 1 < tokens.count, case .word(let word) = tokens[index + 1] { next = word }
        // `class func` and `class var` are a modifier and the introducer after it.
        if introducer == "class", let next, introducers.contains(next) { return nil }
        // `actor` and `macro` are contextual: `let actor = …` names a constant. Each declares only
        // when a name follows.
        if contextualIntroducers.contains(introducer), next == nil { return nil }
        let prefix = self.prefix(endingBefore: index, in: tokens)
        return Declaration(
            introducer: introducer, name: dottedName(from: index + 1, in: tokens),
            attributes: prefix.attributes, modifiers: prefix.modifiers,
            body: body(after: index, in: tokens))
    }

    /// The attributes and modifiers written immediately before the introducer at `end`, read
    /// backwards until a token is neither.
    private static func prefix(
        endingBefore end: Int, in tokens: [Token]
    ) -> (attributes: [String], modifiers: [String]) {
        var attributes: [String] = []
        var modifiers: [String] = []
        var cursor = end - 1
        while cursor >= 0 {
            var argument: String?
            var nameIndex = cursor
            if case .group("(", let inner) = tokens[cursor] {
                argument = inner
                nameIndex = cursor - 1
            }
            guard nameIndex >= 0, case .word(let word) = tokens[nameIndex] else { break }
            if let attribute = attribute(endingAt: nameIndex, in: tokens) {
                attributes.insert(attribute.name, at: 0)
                cursor = attribute.start - 1
            } else if Self.modifiers.contains(word) {
                let collapsed = argument.map { SeamScanner.collapsingWhitespace($0) }
                modifiers.insert(collapsed.map { "\(word)(\($0))" } ?? word, at: 0)
                cursor = nameIndex - 1
            } else {
                break
            }
        }
        return (attributes, modifiers)
    }

    /// The attribute whose dotted name ends at `end`, and the index of its `@`.
    private static func attribute(
        endingAt end: Int, in tokens: [Token]
    ) -> (name: String, start: Int)? {
        var start = end
        var parts: [String] = []
        while start >= 0, case .word(let part) = tokens[start] {
            parts.insert(part, at: 0)
            if start >= 1, tokens[start - 1] == .symbol("@") {
                return (parts.joined(separator: "."), start - 1)
            }
            guard start >= 2, tokens[start - 1] == .symbol(".") else { return nil }
            start -= 2
        }
        return nil
    }

    /// The dotted name starting at `start`: a word, then `.` and a word, as often as written.
    private static func dottedName(from start: Int, in tokens: [Token]) -> String {
        var parts: [String] = []
        var index = start
        while index < tokens.count, case .word(let part) = tokens[index] {
            parts.append(part)
            guard index + 2 < tokens.count, tokens[index + 1] == .symbol("."),
                case .word = tokens[index + 2]
            else { break }
            index += 2
        }
        return parts.joined(separator: ".")
    }

    /// The first `{…}` after the introducer at `index` and before the next introducer.
    private static func body(after index: Int, in tokens: [Token]) -> String? {
        for token in tokens[(index + 1)...] {
            if case .group("{", let inner) = token { return inner }
            if case .word(let word) = token, introducers.contains(word) { return nil }
        }
        return nil
    }

    /// A `#` directive at `index` other than conditional compilation's, described.
    private static func unknownDirective(at index: Int, in tokens: [Token]) -> String? {
        guard tokens[index] == .symbol("#") else { return nil }
        guard index + 1 < tokens.count, case .word(let directive) = tokens[index + 1] else {
            return "a # with no directive after it"
        }
        return conditionalCompilation.contains(directive) ? nil : "#\(directive)"
    }

    // MARK: - Tokens

    enum Token: Equatable {
        /// An identifier, a keyword or a number. A backticked name keeps its backticks.
        case word(String)
        /// A bracketed span, by its opening bracket, holding the text between the brackets.
        case group(Character, String)
        /// Any other character that is not whitespace.
        case symbol(Character)
    }

    private static let partners: [Character: Character] = ["{": "}", "(": ")", "[": "]"]

    /// `code` as tokens at bracket depth 0, and what could not be read.
    static func tokens(in code: String) -> (tokens: [Token], unreadable: [String]) {
        var tokens: [Token] = []
        var unreadable: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            if character.isWhitespace {
                index = code.index(after: index)
            } else if partners[character] != nil {
                guard let close = partner(of: index, in: code) else {
                    unreadable.append("a \(character) that does not balance")
                    return (tokens, unreadable)
                }
                tokens.append(.group(character, String(code[code.index(after: index)..<close])))
                index = code.index(after: close)
            } else if partners.values.contains(character) {
                unreadable.append("a \(character) that closes nothing")
                index = code.index(after: index)
            } else if let end = wordEnd(at: index, in: code) {
                tokens.append(.word(String(code[index..<end])))
                index = end
            } else {
                tokens.append(.symbol(character))
                index = code.index(after: index)
            }
        }
        return (tokens, unreadable)
    }

    /// The index of the bracket closing the one at `open`, or `nil` if the brackets inside do not
    /// nest or never close.
    private static func partner(of open: String.Index, in code: String) -> String.Index? {
        var expected: [Character] = []
        var index = open
        while index < code.endIndex {
            let character = code[index]
            if let close = partners[character] {
                expected.append(close)
            } else if partners.values.contains(character) {
                guard expected.last == character else { return nil }
                expected.removeLast()
                if expected.isEmpty { return index }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The end of the word starting at `index`, or `nil` if none starts there. A backticked name
    /// ends at its closing backtick.
    private static func wordEnd(at index: String.Index, in code: String) -> String.Index? {
        if code[index] == "`" {
            let after = code.index(after: index)
            guard let close = code[after...].firstIndex(of: "`") else { return nil }
            return code.index(after: close)
        }
        guard isWordCharacter(code[index]) else { return nil }
        return code[index...].firstIndex { !isWordCharacter($0) } ?? code.endIndex
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
