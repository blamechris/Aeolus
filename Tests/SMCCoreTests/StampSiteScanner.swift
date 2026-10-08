import Foundation

/// Finds uses of an IOKit entry point in Swift source and says whether each one sits inside the
/// closure of a `roundTrips.bracket(…)`. The tripwire in `RoundTripStampTripwireTests` is built
/// on it, and tests it against synthetic sources before trusting it on the real tree.
enum StampSiteScanner {

    /// A use of a symbol the tripwire cares about.
    struct Site: Equatable {
        /// Whether the symbol is followed by an argument list. A bare reference — an alias,
        /// `let call = IOConnectCallStructMethod` — is a way past a scan for `Symbol(`.
        let isCall: Bool
        /// The operation argument of the innermost `roundTrips.bracket(…) { … }` whose closure
        /// body contains the use, or `nil` if it is not inside the body of one.
        let bracketOperation: String?
    }

    // MARK: - Normalisation

    /// Comments removed, whitespace collapsed, and no whitespace left next to the punctuation a
    /// call is written with.
    ///
    /// The point is that the *same* program text has one spelling here: `foo (`, `foo\n(`,
    /// `foo/* x */(` and `foo(` all become `foo(`, and `roundTrips\n    .bracket(\n  .open\n)`
    /// becomes `roundTrips.bracket(.open)`. String literals are kept as code rather than
    /// dropped: a call inside an interpolation is still a call, and a string that merely
    /// mentions a symbol is a false positive that fails loudly and gets fixed, where a hidden
    /// call would not.
    static func normalise(_ source: String) -> String {
        let characters = Array(source)
        var code = ""
        var index = 0
        var blockDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if blockDepth > 0 {
                // Swift block comments nest.
                if character == "/", next == "*" {
                    blockDepth += 1
                    index += 2
                } else if character == "*", next == "/" {
                    blockDepth -= 1
                    index += 2
                    if blockDepth == 0 { code.append(" ") }
                } else {
                    index += 1
                }
                continue
            }
            if character == "/", next == "/" {
                while index < characters.count, !characters[index].isNewline { index += 1 }
                code.append(" ")
                continue
            }
            if character == "/", next == "*" {
                blockDepth = 1
                index += 2
                continue
            }
            if character == "\"" {
                index = copyStringLiteral(from: characters, at: index, into: &code)
                continue
            }
            code.append(character)
            index += 1
        }
        return squeeze(code)
    }

    /// Copies one string literal, quotes included, and returns the index after it. The reason
    /// to recognise strings at all is that a `//` inside one is not a comment: without this,
    /// `"http://…"` would hide the rest of its line, and any call after it on that line.
    ///
    /// Interpolations that themselves contain a quote end the literal early. That can only
    /// leave a real comment unstripped — a false positive — never hide code.
    private static func copyStringLiteral(
        from characters: [Character], at start: Int, into code: inout String
    ) -> Int {
        let isMultiline = isTripleQuote(characters, at: start)
        let delimiter = isMultiline ? 3 : 1
        code.append(contentsOf: String(repeating: "\"", count: delimiter))
        var index = start + delimiter

        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                code.append(character)
                if index + 1 < characters.count { code.append(characters[index + 1]) }
                index += 2
                continue
            }
            if isMultiline {
                if isTripleQuote(characters, at: index) {
                    code.append(contentsOf: "\"\"\"")
                    return index + 3
                }
            } else {
                if character == "\"" {
                    code.append(character)
                    return index + 1
                }
                // An unterminated single-line literal: stop at the line end so one stray quote
                // cannot swallow the file.
                if character.isNewline { return index }
            }
            code.append(character)
            index += 1
        }
        return index
    }

    private static func isTripleQuote(_ characters: [Character], at index: Int) -> Bool {
        guard index + 2 < characters.count else { return false }
        return characters[index...(index + 2)].allSatisfy { $0 == "\"" }
    }

    private static let tight: Set<Character> = ["(", ")", "{", "}", ".", ",", ":"]

    private static func squeeze(_ code: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in code {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, needsSpace(between: result.last, and: character) {
                result.append(" ")
            }
            pendingSpace = false
            result.append(character)
        }
        return result
    }

    /// Whitespace survives only between two things that are not punctuation a call is written
    /// with, so `foo (`, `foo\n(` and `a . b` lose theirs and `try foo` keeps its own.
    private static func needsSpace(between last: Character?, and next: Character) -> Bool {
        guard let last else { return false }
        return !tight.contains(last) && !tight.contains(next)
    }

    // MARK: - Matching

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// Every use of `symbol` as a whole identifier in already-normalised text.
    static func identifierRanges(of symbol: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: symbol, range: search) {
            search = range.upperBound..<text.endIndex
            let before =
                range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if let before, isIdentifierCharacter(before) { continue }
            if let after, isIdentifierCharacter(after) { continue }
            found.append(range)
        }
        return found
    }

    /// The index of the delimiter closing the one just before `start`, or `nil` if unbalanced.
    private static func matching(
        _ close: Character, opening open: Character, after start: String.Index, in text: String
    ) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// One `roundTrips.bracket(<operation>) { <body> }`.
    private struct BracketedRegion {
        let operation: String
        let body: Range<String.Index>
    }

    private static func bracketedRegions(in text: String) -> [BracketedRegion] {
        let opener = normalise("roundTrips.bracket(")
        var regions: [BracketedRegion] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: opener, range: search) {
            search = range.upperBound..<text.endIndex
            guard let argumentsEnd = matching(")", opening: "(", after: range.upperBound, in: text)
            else { continue }
            let afterArguments = text.index(after: argumentsEnd)
            // The body must be the trailing closure: a use inside the *argument* list is not
            // inside the bracket's protection, whatever it is passed to.
            guard afterArguments < text.endIndex, text[afterArguments] == "{",
                let bodyEnd = matching(
                    "}", opening: "{", after: text.index(after: afterArguments), in: text)
            else { continue }
            regions.append(
                BracketedRegion(
                    operation: String(text[range.upperBound..<argumentsEnd]),
                    body: text.index(after: afterArguments)..<bodyEnd))
        }
        return regions
    }

    /// Removes `deinit { … }`, which the issue exempts by name. Not because no stamp could be
    /// read from a destructor — the monitor can outlive its connection — but because the helper's
    /// one connection lives for the whole process; a reconnect that replaces the connection object
    /// must stamp its close or keep the old object alive.
    static func removingDeinit(from text: String) -> String {
        guard let start = text.range(of: "deinit{") else { return text }
        guard let end = matching("}", opening: "{", after: start.upperBound, in: text) else {
            return text
        }
        var remainder = text
        remainder.removeSubrange(start.lowerBound...end)
        return remainder
    }

    /// Every whole-identifier use of `symbol` in `source` (comments removed), classified.
    static func sites(
        of symbol: String, in source: String, excludingDeinit: Bool = false
    ) -> [Site] {
        var text = normalise(source)
        if excludingDeinit { text = removingDeinit(from: text) }
        let regions = bracketedRegions(in: text)

        return identifierRanges(of: symbol, in: text).map { range in
            let enclosing =
                regions
                .filter { $0.body.contains(range.lowerBound) }
                .max { $0.body.lowerBound < $1.body.lowerBound }
            let isCall = range.upperBound < text.endIndex && text[range.upperBound] == "("
            return Site(isCall: isCall, bracketOperation: enclosing?.operation)
        }
    }

    /// Whether `site` is a call inside a bracket whose operation starts with `operation`.
    static func isStamped(_ site: Site, as operation: String) -> Bool {
        site.isCall && site.bracketOperation?.hasPrefix(normalise(operation)) == true
    }

    /// Any other way into an IOKit user client: `IOConnectCall…`, `IOConnectTrap…`,
    /// `IOConnectSetCFPropert…`, `IOConnectMapMemory…`, `IOConnectAddClient` and
    /// `IOConnectSetNotificationPort`, other than `IOConnectCallStructMethod` itself. Each is a
    /// sibling entry point to the same user client that the stamp would not see.
    static func siblingEntryPoints(in source: String) -> [String] {
        let text = normalise(source)
        let family = "Call|Trap|SetCFPropert|MapMemory|AddClient|SetNotificationPort"
        guard let pattern = try? NSRegularExpression(pattern: "IOConnect(?:\(family))\\w*")
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        .filter { $0 != "IOConnectCallStructMethod" }
    }

    /// Every initialiser declared `public`, `package` or `open`, in `source` with comments
    /// removed. The monitor's initialisers must be internal: a public one lets a caller build a
    /// monitor that no connection stamps.
    static func exposedInitializers(in source: String) -> [String] {
        let text = normalise(source)
        guard
            let pattern = try? NSRegularExpression(
                pattern: #"\b(?:public|package|open)\s+(?:convenience\s+|required\s+)*init\b"#)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - The tree

    struct SourceFile {
        let path: String
        let text: String
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SMCCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    /// Every `.swift` file under `Sources/` and `Tools/`, by repository-relative path.
    static func treeFiles() throws -> [SourceFile] {
        var files: [SourceFile] = []
        for directory in ["Sources", "Tools"] {
            let root = repositoryRoot.appendingPathComponent(directory)
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let prefix = repositoryRoot.path + "/"
                files.append(
                    SourceFile(
                        path: String(url.path.dropFirst(prefix.count)),
                        text: try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }
}
