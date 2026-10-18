import Foundation
import Testing

/// What `CompositionWriteChannelTests.widenedAccessToken` finds of `open` and `package` (#445):
/// that it holds a declaration of every keyword its pattern lists, and that it reads the word as
/// an access level only where a declaration starts.
extension CompositionWriteChannelTests {

    // MARK: - The pattern's keywords

    /// The declaration keywords `open` and `package` must be followed by, past any other modifiers
    /// and attributes, to be read as access levels. The pattern is built from this list, and
    /// `everyDeclarationKeywordIsHeld` takes its keywords from it, so a keyword cannot be added
    /// here, or cut, without a fixture saying so (#445, S-2).
    static let declarationKeywords = [
        "func", "var", "let", "class", "struct", "enum", "actor", "protocol", "extension", "init",
        "subscript", "typealias", "associatedtype", "import",
    ]

    // MARK: - Where a declaration starts

    /// What, written before `open` or `package`, makes it a name and not a modifier: the keywords
    /// `case` and `return`, and the characters `=` and `,` (`_ = open`, `case closed, open`,
    /// `x == open`). A declaration that follows is the next statement's, not `open`'s: `case open`
    /// over `var isOpen: Bool { … }` reads past the case to the `var` (#445, N-1).
    ///
    /// Everything else leaves `open` read as a modifier — a `{`, `}` or `;`, an attribute, another
    /// modifier, a `)` — so a context this does not know errs loud, which is the direction that
    /// cannot hide a widening.
    static let expressionKeywords: Set<String> = ["case", "return"]
    static let expressionSeparators: Set<Character> = ["=", ","]

    /// Whether the token before `index` makes the word at it a name: see `expressionKeywords`.
    static func followsExpressionContext(_ index: String.Index, in code: String) -> Bool {
        var end = index
        while end > code.startIndex, code[code.index(before: end)].isWhitespace {
            end = code.index(before: end)
        }
        guard end > code.startIndex else { return false }
        if expressionSeparators.contains(code[code.index(before: end)]) { return true }
        var start = end
        while start > code.startIndex, isWordCharacter(code[code.index(before: start)]) {
            start = code.index(before: start)
        }
        return expressionKeywords.contains(String(code[start..<end]))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Every widening access word in `code`, in order.
    ///
    /// `open` and `package` are words the pattern finds before a declaration keyword, wherever that
    /// keyword is, so one that stands as a name — `case open` over a member — is dropped here
    /// unless it starts a declaration.
    static func widenedAccess(in code: String) throws -> [String] {
        let found = try NSRegularExpression(pattern: widenedAccessToken)
            .matches(in: code, range: NSRange(code.startIndex..., in: code))
        return found.compactMap { match -> String? in
            guard let range = Range(match.range, in: code) else { return nil }
            let word = String(code[range])
            let isModifierWord = word == "open" || word == "package"
            let isName = isModifierWord && followsExpressionContext(range.lowerBound, in: code)
            return isName ? nil : word
        }
    }

    /// Each is a name before a declaration of the next statement.
    private static let namesBeforeDeclarations = [
        """
        private enum E {
            case open
            var isOpen: Bool { self == .open }
        }
        """,
        """
        private enum E {
            case open
            case closed
            func f() {}
        }
        """,
        """
        private enum E {
            static func f() {
                _ = open
                let y = 2
            }
        }
        """,
        """
        private enum E {
            case package
            var isPackage: Bool { true }
        }
        """,
        """
        private enum E {
            func f() -> Bool {
                return open
                let y = 2
            }
        }
        """,
        """
        private enum E {
            case closed, open
            var isOpen: Bool { self == .open }
        }
        """,
        """
        private enum E {
            case closed,
                package
            func f() {}
        }
        """,
        """
        private enum E {
            func f() {
                let same = x == open
                let y = 2
            }
        }
        """,
    ]

    /// `open` and `package` as names, followed by a declaration that belongs to the next
    /// statement, are not widenings. Each of these was refused before #445, because the lookahead
    /// reads past a `case` or an `=` to the declaration keyword beyond it.
    ///
    /// **Mutations**, in `widenedAccess(in:)` and `followsExpressionContext`: skip the check
    /// altogether; take `case` out of `expressionKeywords`; `return` likewise; take `=` out of
    /// `expressionSeparators`; `,` likewise. Run: red here, at the fixtures that write that token.
    @Test("open and package as names before a declaration of the next statement are not widenings")
    func aNameBeforeADeclarationIsNotAWidening() throws {
        for source in Self.namesBeforeDeclarations {
            #expect(try Self.widenedAccess(in: Self.mainCode(source)).isEmpty, "\(source)")
        }
    }

    /// The same layouts with a real widening beside the name: only the widening is found, so the
    /// check that drops a name does not drop the declaration next to it.
    ///
    /// **Mutation:** skip the check altogether. Run: red here, at the first fixture.
    @Test("A real widening beside a name is still found")
    func aWideningBesideANameIsFound() throws {
        let mixed: [(source: String, words: [String])] = [
            ("private class E {\n    var x = open\n    open var y = 2\n}", ["open"]),
            ("private enum E {\n    case open\n    public var isOpen: Bool {}\n}", ["public"]),
            ("private enum E {\n    case closed, open\n    package func f() {}\n}", ["package"]),
        ]
        for (source, words) in mixed {
            #expect(try Self.widenedAccess(in: Self.mainCode(source)) == words, "\(source)")
        }
    }

    /// A member access is not a modifier, whichever word it ends in: `privacy: .public` is how a
    /// log interpolation is written, and `Mode.open` ahead of a declaration is the case the
    /// `open` lookbehind alone holds.
    ///
    /// **Mutations:** in `widenedAccessToken`, drop `.` from the first lookbehind; from the second;
    /// from both (M6). Run: red here, at `privacy: .public`; at `Mode.open` and `Mode.package`;
    /// and at all three, respectively.
    @Test("A member access ending in public, open or package is not an access level")
    func aMemberAccessIsNotAnAccessLevel() throws {
        let members = [
            #"private enum E { func f() { logger.info("x", privacy: .public) } }"#,
            #"private enum E { func f() { log("\(x, privacy: .public)") } }"#,
            """
            private enum E {
                func f() {
                    _ = Mode.open
                    let y = 2
                }
            }
            """,
            """
            private enum E {
                func f() {
                    _ = Mode.package
                    let y = 2
                }
            }
            """,
        ]
        for source in members {
            #expect(try Self.widenedAccess(in: Self.mainCode(source)).isEmpty, "\(source)")
        }
    }

    // MARK: - Every keyword

    /// One declaration per keyword in `declarationKeywords`, written as `open` or `package` would
    /// be followed by it. The list is the pattern's own; this table is the evidence, and the two
    /// are compared, so a keyword cannot be cut from the pattern or added to it unheld (#445, S-2).
    private static let declarationsByKeyword: [String: String] = [
        "func": "func f() {}", "var": "var x = 1", "let": "let x = 1", "class": "class C {}",
        "struct": "struct S {}", "enum": "enum E {}", "actor": "actor A {}",
        "protocol": "protocol P {}", "extension": "extension X {}", "init": "init() {}",
        "subscript": "subscript(i: Int) -> Int { 0 }", "typealias": "typealias T = Int",
        "associatedtype": "associatedtype T", "import": "import Foundation",
    ]

    /// Eleven of the fourteen keywords had no fixture: cutting the list to `func|var|let` left the
    /// suite green, and `private extension HelperComposition { package init(…) }` would have
    /// passed with `init` dropped.
    ///
    /// **Mutations:** cut `declarationKeywords` to `func`, `var` and `let` (M5); add a keyword to
    /// it. Run: red here, the first at each of the other eleven keywords' fixtures, once for
    /// `open` and once for `package`, and at the table's comparison, and the second at the
    /// comparison only.
    @Test("open and package widen a declaration of every keyword the pattern lists")
    func everyDeclarationKeywordIsHeld() throws {
        let listed = Self.declarationKeywords
        let held = Self.declarationsByKeyword.keys.sorted()
        #expect(Set(held) == Set(listed), "the pattern lists \(listed), the fixtures \(held)")
        for keyword in held {
            let declaration = try #require(Self.declarationsByKeyword[keyword])
            for word in ["open", "package"] {
                let source = "private enum E {\n    \(word) \(declaration)\n}"
                #expect(
                    try Self.widenedAccess(in: Self.mainCode(source)) == [word],
                    "\(word) before \(keyword): \(source)")
            }
        }
    }
}
