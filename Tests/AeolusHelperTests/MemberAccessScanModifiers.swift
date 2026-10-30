import Foundation

/// `MemberAccessScan`'s reading of the modifier run: which tokens before `let`, `var` or `func`
/// are access, which are noise, and which of them stand on a line of their own.
///
/// Its own file so `MemberAccessScan.swift` stays under SwiftLint's 400-line warning, and
/// because one walk answers three questions that have to agree: what a member's access is,
/// whether a line holds nothing but modifiers, and what the judged declaration of a named member
/// reads as. `ignorableModifiers`, the list the walk consults, is declared in `MemberAccessScan`.
///
/// ## Why a modifier on the line before is part of the declaration
///
/// Swift lets a modifier stand alone: `nonisolated(unsafe)` or `public` on one line and
/// `private(set) var interruptions` on the next. That is not an exotic spelling: the formatter
/// keeps a break the author wrote (`respectsExistingLineBreaks`) and indents the continuation by
/// eight spaces. A scan that judges the declaration's own line reads the second line and never
/// the first, so a modifier added above `private(set) var interruptions` left an equality on
/// that line green, and `public` above an acknowledged function left its entry matching
/// ([#604](https://github.com/blamechris/Aeolus/issues/604)).
///
/// The modifier-only lines directly above a declaration are therefore read as part of it: their
/// tokens come first, in source order, ahead of the declaration line's own. Blank lines and
/// whole-line comments between them are stepped over, since Swift allows both there, and a
/// trailing `//` comment on a modifier-only line is cut, since it is not part of the modifier.
/// A line with any other token on it — a `}`, a previous declaration, an argument continuation —
/// ends the run.
///
/// **What this does not reach:** the declaration line itself is still recognised at exactly four
/// spaces. The formatter's own spelling of a two-line declaration puts the second line at eight,
/// so a member written that way is not in `members(in:keyword:)`'s population at all, and what
/// notices is an acknowledged entry going missing. A *new* member written that way is seen by
/// nothing here; see `MemberAccessScan`'s account of the four-space indent.
extension MemberAccessScan {

    /// Consumes the modifier run from the head of `tokens` — attributes, ignorable modifiers,
    /// `private` and `fileprivate` — and answers whether the run made the member private.
    ///
    /// `private(set)` leaves the getter internal, so only the bare form answers yes. What is left
    /// in `tokens` starts at the introducer, or is empty when the line held modifiers alone.
    static func consumeModifiers(from tokens: inout [Substring]) -> Bool {
        var isPrivate = false

        while let token = tokens.first {
            let head = String(token.prefix { $0 != "(" })
            if token.hasPrefix("@") {
                dropAttribute(from: &tokens)
            } else if head == "private" || head == "fileprivate" {
                if head.count == token.count { isPrivate = true }
                tokens.removeFirst()
            } else if ignorableModifiers.contains(head) {
                tokens.removeFirst()
            } else {
                break
            }
        }
        return isPrivate
    }

    /// The tokens of `line` when it holds modifiers and nothing else — or `nil` when it is blank,
    /// a comment, or carries any token that is not a modifier.
    ///
    /// A trailing `//` comment is cut first, so `nonisolated(unsafe)  // why` is still a modifier
    /// line: a comment must not be what hides a modifier from the declaration beneath it.
    static func modifierOnlyTokens(of line: Substring) -> [Substring]? {
        let code = line.range(of: "//").map { line[..<$0.lowerBound] } ?? line
        let written = code.split(separator: " ")
        var rest = written
        _ = consumeModifiers(from: &rest)
        return !written.isEmpty && rest.isEmpty ? written : nil
    }

    /// The modifier tokens on the lines directly above `lines[index]`, in source order.
    ///
    /// Walks up from the declaration while each line is blank, a whole-line comment, or
    /// modifier-only, and stops at the first line that is anything else. Blank lines and comments
    /// contribute nothing.
    static func precedingModifiers(above index: Int, in lines: [Substring]) -> [Substring] {
        var runs: [[Substring]] = []
        var cursor = index

        while cursor > 0 {
            cursor -= 1
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            guard let tokens = modifierOnlyTokens(of: lines[cursor]) else { break }
            runs.append(tokens)
        }
        return runs.reversed().flatMap { $0 }
    }

    /// The spelling of every member of the requested kind that is not `private`, across `files`.
    ///
    /// What an acknowledged list is compared against: the modifier run, the introducer and the
    /// key, as `Member.spelling` reads them. `private(set)` is not private, so it is here.
    static func nonPrivateSpellings(
        in files: [String], keyword: Keyword
    ) throws -> Set<String> {
        Set(try members(in: files, keyword: keyword).filter { !$0.isPrivate }.map(\.spelling))
    }

    /// The header line of every `extension` of `type` in `target`, as `File.swift: header`, sorted,
    /// each behind any modifier-only lines above it.
    ///
    /// **The same hole one level up.** An `extension`'s own access modifier is the default for
    /// every member inside it, and sits on no member's line: `public extension HelperClient {`
    /// makes each member of the block `public` with every member spelled exactly as before, so an
    /// acknowledged list that pins members as spelled cannot see it. `swift format lint --strict`
    /// accepts it, as measured on #604. Comparing the headers is what closes it.
    static func extensionHeaders(of type: String, inTarget target: String) throws -> [String] {
        var found: [String] = []
        for url in try SeamScanner.swiftFiles(under: target) {
            let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
            found += try extensionHeaders(of: type, inSource: code)
                .map { "\(url.lastPathComponent): \($0)" }
        }
        return found.sorted()
    }

    /// `extensionHeaders(of:inTarget:)`'s parse, over one file's text.
    ///
    /// The type's name is matched whole, as in `filesDeclaring(_:inTarget:)`, and a header is the
    /// line the `extension` keyword is on, trimmed, so a trailing comment or a conformance is part
    /// of it and fails an exact comparison.
    static func extensionHeaders(of type: String, inSource code: String) throws -> [String] {
        let extending = try NSRegularExpression(
            pattern: #"\bextension\s+\#(type)(?![A-Za-z0-9_])"#)
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)

        return lines.indices.compactMap { index in
            let text = String(lines[index])
            let range = NSRange(text.startIndex..., in: text)
            guard extending.firstMatch(in: text, range: range) != nil else { return nil }
            let modifiers = precedingModifiers(above: index, in: lines).map(String.init)
            return (modifiers + [text.trimmingCharacters(in: .whitespaces)]).joined(separator: " ")
        }
    }

    /// What an exact comparison failed on, in words: the spellings only in `found`, then the ones
    /// only in `acknowledged`.
    ///
    /// Spelled entries can differ from each other by a single modifier, so printing both whole
    /// sets would leave the reader to find it.
    static func difference(_ found: Set<String>, _ acknowledged: Set<String>) -> String {
        "found and not acknowledged \(found.subtracting(acknowledged).sorted()), acknowledged "
            + "and not found \(acknowledged.subtracting(found).sorted())"
    }

    // MARK: - Parsing

    /// Drops one attribute from the head of the modifier run, counting parentheses rather than
    /// whitespace — see the type's doc comment for the spelling that made the difference.
    private static func dropAttribute(from tokens: inout [Substring]) {
        var depth = 0
        repeat {
            let token = tokens.removeFirst()
            depth += token.filter { $0 == "(" }.count
            depth -= token.filter { $0 == ")" }.count
        } while depth > 0 && !tokens.isEmpty
    }
}
