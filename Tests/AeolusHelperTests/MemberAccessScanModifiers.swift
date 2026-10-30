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
/// **What this does not reach:**
///
/// - The declaration line itself is still recognised at exactly four spaces. The formatter's own
///   spelling of a two-line declaration puts the second line at eight, so a member written that
///   way, new or an existing one widened in it, is not in `members(in:keyword:)`'s population at
///   all. What notices is an acknowledged entry going missing, or a member a suite judges with
///   `declaration(of:in:from:)`; see `MemberAccessScan`'s account of the four-space indent.
/// - A modifier line whose parentheses do not close on it, the first line of an attribute wrapped
///   over several, ends the run, so a modifier above such an attribute is not joined.
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
    /// a comment, carries any token that is not a modifier, or leaves a parenthesis open.
    ///
    /// A trailing `//` comment is cut first, so `nonisolated(unsafe)  // why` is still a modifier
    /// line: a comment must not be what hides a modifier from the declaration beneath it. The
    /// cut, and the parentheses that must close, are read outside string literals, so an
    /// attribute whose message holds `https://…` or `f(` is a modifier line whole. A line whose
    /// parentheses do not close on it — the first line of an attribute wrapped over several —
    /// ends the run instead: an attribute left open would consume whatever followed it.
    static func modifierOnlyTokens(of line: Substring) -> [Substring]? {
        let code = strippingTrailingComment(from: line)
        guard parenthesesClose(in: code) else { return nil }
        let written = code.split(separator: " ")
        var rest = written
        _ = consumeModifiers(from: &rest)
        return !written.isEmpty && rest.isEmpty ? written : nil
    }

    /// `line` up to a `//` that is not inside a string literal.
    ///
    /// A quote opens or closes a string unless a backslash escapes it. Raw-string delimiters
    /// (`#"…"#`) are not tracked: a modifier line has no reason to carry one.
    static func strippingTrailingComment(from line: Substring) -> Substring {
        var inString = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if inString, character == "\\" {
                index = next < line.endIndex ? line.index(after: next) : next
                continue
            }
            if character == "\"" {
                inString.toggle()
            } else if !inString, character == "/", next < line.endIndex, line[next] == "/" {
                return line[..<index]
            }
            index = next
        }
        return line
    }

    /// Whether every parenthesis opened in `text`, outside string literals, is closed in it, with
    /// no string left open.
    static func parenthesesClose(in text: Substring) -> Bool {
        var inString = false
        return parenthesisDepth(of: text, inString: &inString) == 0 && !inString
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

    /// The name a property's `spelling` ends in: its last word, because a property's key is its
    /// name and the key is the last thing `Member.spelling` appends.
    ///
    /// For the checks that read an acknowledged property's accessor block by name
    /// (`accessorBlock(of:in:)`) while the list they read holds spellings. A method's spelling
    /// ends in a signature, which has spaces in it, so this is for properties only.
    static func name(ofPropertySpelling spelling: String) -> String {
        spelling.split(separator: " ").last.map(String.init) ?? spelling
    }

    // MARK: - Parsing

    /// Drops one attribute from the head of the modifier run, counting parentheses rather than
    /// whitespace — see the type's doc comment for the spelling that made the difference — and
    /// not counting the ones inside a string literal, which a space can split across tokens.
    private static func dropAttribute(from tokens: inout [Substring]) {
        var depth = 0
        var inString = false
        repeat {
            depth += parenthesisDepth(of: tokens.removeFirst(), inString: &inString)
        } while depth > 0 && !tokens.isEmpty
    }

    /// The parentheses in `text` opened less closed, outside string literals. `inString` carries a
    /// literal that `text` leaves open into the text that follows it.
    private static func parenthesisDepth(of text: Substring, inString: inout Bool) -> Int {
        var depth = 0
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if inString, character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString, character == "(" {
                depth += 1
            } else if !inString, character == ")" {
                depth -= 1
            }
        }
        return depth
    }
}
