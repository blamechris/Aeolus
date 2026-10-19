import Foundation

/// Every place under `Sources/` that writes the name of one of § 5's roles, each read as the
/// statement it sits in, so the whole set can be held to a list.
///
/// A role can only reach anything by being **named**: an extension, a refinement, a conformer, a
/// `typealias`, a cast, a stored property all write it. So a census of the spellings is a closed
/// question where a list of forbidden shapes is not. `ReclamationRoleTripwireTests` used to match
/// four shapes, and the shapes it did not write were the way past it: a backticked name, a
/// module-qualified `extension AeolusHelper.ReclamationLedgerRole`, and a `typealias` whose `=`
/// ends a line were each green. A census has no shape to miss. A new spelling is unlisted unless it
/// is one of the few that were listed.
///
/// What it reads, and the limits:
///
/// - **Code, not comments.** Every comment is stripped, a trailing one included
///   (`SeamScanner.strippingAllComments`), and so are backticks, since `` `ThermalLatchRole` `` is
///   the same name. The stripper is a quote counter and not a lexer, with the limit stated at
///   `strippingBlockAndLineComments`.
/// - **Lines are kept.** The stripper drops a whole-line `//` comment, which would shift every
///   line number after it. Every line is given a leading NUL first, so that none of them reads as
///   one, and the NULs are removed after. A failure names the line the source has.
/// - **Newlines are whitespace.** A statement is read from its tokens, not its lines, so
///   `typealias LedgerView =` and `ReclamationLedgerRole` on the next line are one statement.
/// - **Statement.** The name, the tokens before it back to the previous `{ } ; ( ) ,` or the
///   declaration keyword that opens it (inclusive), and the tokens after it up to the next of
///   those, or to the next declaration keyword, access modifier or attribute. Whitespace in it is
///   collapsed. `private let latch: any ThermalLatchRole` is `let latch: any ThermalLatchRole`.
/// - **Where.** `Sources/` only. The test target's own doubles conform to the roles on purpose.
///   A file is identified by its path under `Sources/`, not its basename, so a decoy elsewhere
///   with the same name is a different file.
///
/// What it does not read is how a file uses the property that holds a role once it has one, which
/// is `ReclamationRoleTripwireTests`' last test. `RoleCensusTests` runs this against fixtures.
enum RoleCensus {

    /// A statement a census allows, in the file it is allowed in.
    struct Listing: Hashable, Sendable, CustomStringConvertible {
        let path: String
        let statement: String

        var description: String { "Sources/\(path): `\(statement)`" }
    }

    /// A statement a census found, with where.
    struct Occurrence: Hashable, Sendable, CustomStringConvertible {
        let path: String
        let line: Int
        let statement: String

        var listing: Listing { Listing(path: path, statement: statement) }
        var description: String { "Sources/\(path):\(line): `\(statement)`" }
    }

    /// What a census found that was not listed, and what was listed that it did not find.
    struct Verdict: Sendable {
        let unlisted: [Occurrence]
        let missing: [Listing]
    }

    private struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    private static let boundaries: Set<Substring> = ["{", "}", ";", "(", ")", ","]

    /// What opens a declaration. A walk back from a name ends at one, inclusive.
    private static let introducers: Set<Substring> = [
        "protocol", "actor", "class", "struct", "enum", "extension", "typealias",
        "associatedtype", "let", "var", "func", "init", "import", "case", "return", "where",
    ]

    /// What follows a declaration's last token and so ends a walk forward, with `introducers`: the
    /// next declaration, which the newline that separated it no longer does.
    private static let declarationStarts: Set<Substring> = [
        "private", "fileprivate", "internal", "public", "package", "open", "static", "final",
        "nonisolated", "@",
    ]

    /// What a walk forward from a name ends before.
    private static let forwardStops = boundaries.union(introducers).union(declarationStarts)

    /// `source` with every comment and backtick removed and every line kept.
    static func code(of source: String) -> String {
        let marked = "\u{0}" + source.replacingOccurrences(of: "\n", with: "\n\u{0}")
        return SeamScanner.strippingAllComments(marked)
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// Every spelling of any of `roles` in one file's `source`, in order.
    static func occurrences(
        inSource source: String, path: String, roles: [String]
    ) -> [Occurrence] {
        let code = Self.code(of: source)
        guard roles.contains(where: { code.contains($0) }) else { return [] }
        let tokens = Self.tokens(in: code)
        return tokens.indices.filter { roles.contains(String(tokens[$0].text)) }.map { index in
            let (first, last) = bounds(ofStatementAround: index, in: tokens)
            let statement = SeamScanner.collapsingWhitespace(
                String(code[tokens[first].range.lowerBound..<tokens[last].range.upperBound]))
            let precedingNewlines = code[..<tokens[index].range.lowerBound].filter { $0 == "\n" }
            return Occurrence(path: path, line: precedingNewlines.count + 1, statement: statement)
        }
    }

    /// Every spelling of any of `roles` under `Sources/`, by path and then position.
    static func occurrences(roles: [String]) throws -> [Occurrence] {
        let root = SeamScanner.sourcesRoot.path + "/"
        return try SeamScanner.swiftFiles().sorted { $0.path < $1.path }.flatMap { file in
            let path =
                file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.path
            return occurrences(
                inSource: try String(contentsOf: file, encoding: .utf8), path: path, roles: roles)
        }
    }

    /// Each occurrence is matched against one of `listed`, which it then uses up: a listed
    /// statement written twice is one listed occurrence and one that is not.
    static func reconcile(_ found: [Occurrence], with listed: [Listing]) -> Verdict {
        var remaining = listed
        var unlisted: [Occurrence] = []
        for occurrence in found {
            if let match = remaining.firstIndex(of: occurrence.listing) {
                remaining.remove(at: match)
            } else {
                unlisted.append(occurrence)
            }
        }
        return Verdict(unlisted: unlisted, missing: remaining)
    }

    // MARK: - Tokens

    private static func tokens(in code: String) -> [Token] {
        var tokens: [Token] = []
        var index = code.startIndex
        while index < code.endIndex {
            guard !code[index].isWhitespace else {
                index = code.index(after: index)
                continue
            }
            let start = index
            if isWordCharacter(code[index]) {
                while index < code.endIndex, isWordCharacter(code[index]) {
                    index = code.index(after: index)
                }
            } else {
                index = code.index(after: index)
            }
            tokens.append(Token(text: code[start..<index], range: start..<index))
        }
        return tokens
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func bounds(
        ofStatementAround index: Int, in tokens: [Token]
    ) -> (first: Int, last: Int) {
        var first = index
        while first > 0, !boundaries.contains(tokens[first - 1].text) {
            first -= 1
            if introducers.contains(tokens[first].text) { break }
        }
        var last = index
        while last + 1 < tokens.count {
            if forwardStops.contains(tokens[last + 1].text) { break }
            last += 1
        }
        return (first, last)
    }
}
