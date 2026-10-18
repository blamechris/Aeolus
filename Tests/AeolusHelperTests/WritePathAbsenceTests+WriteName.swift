import Foundation
import Testing

/// The name scan behind `WritePathAbsenceTests.helperNeverCallsWrite`, in a file of its own so the
/// suite stays inside `type_body_length`. Internal rather than private for that reason only.
extension WritePathAbsenceTests {

    /// The name `write` with an argument list after it, through a receiver or not — `write(`,
    /// `connection.write(`, `write<T>(`, `write /* c */ (` once block comments are gone — and not
    /// `overwrite(` or `didWrite(`, which a lookbehind on the preceding character tells apart.
    ///
    /// #226's review is why it is not `.write(` alone: inside an `extension SMCConnection`, `self`
    /// was the actor, and an unqualified `write(bytes, to: key)` was a real write that scan could
    /// not see.
    static let writeCall = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])write\s*(?:<[^<>]*>\s*)?\("#)

    /// The name `write` taken as a member, whether or not a call follows — `let submit =
    /// channel.write` is a use, and the call pattern above cannot see it (#436's review).
    static let writeMember = try? NSRegularExpression(pattern: #"\.\s*write(?![A-Za-z0-9_])"#)

    /// The name `write` bare — not after a `.`, which `writeMember` reads — where it is neither
    /// called (`writeCall` reads that), declared, nor a label: `let submit = write` inside an
    /// extension, or `apply(write, key)`, takes the requirement as a value through an implicit
    /// `self` (#436's delta review, B5).
    static let bareWrite = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(?<!func\s)write(?![A-Za-z0-9_])(?!\s*[(<])"#)

    /// Every bare use of `write` in `code`, which must already have its comments and its string
    /// literals' text removed: prose in a log message is not a use, an interpolation is code.
    ///
    /// A `write:` after `(`, `,` or a word is a label — an argument's, or a parameter's internal
    /// name — and not a use; after `?` it is a ternary's operand, which is.
    static func bareWriteUses(in code: String) throws -> [String.Index] {
        let bare = try #require(Self.bareWrite)
        return bare.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            guard let found = Range($0.range, in: code) else { return nil }
            let next = code[found.upperBound...].first { !$0.isWhitespace }
            let previous = code[..<found.lowerBound].last { !$0.isWhitespace }
            let labelled =
                next == ":"
                && previous.map { "(,".contains($0) || $0.isLetter || $0.isNumber || $0 == "_" }
                    ?? false
            return labelled ? nil : found.lowerBound
        }
    }

    /// One occurrence of the name `write`.
    enum WriteOccurrence: Equatable {
        /// `func write(…)`.
        case declaration
        /// `write(_:to:)`: a compound name, which names a function and calls nothing.
        case reference
        /// A call, or the member taken as a value — anything that can reach the write — with the
        /// text after the name for a failure message.
        case use(String)
    }

    /// Every occurrence of the name in `code`, classified, at the position of its `w`.
    static func writeOccurrences(
        in code: String
    ) throws -> [(occurrence: WriteOccurrence, at: String.Index)] {
        let call = try #require(Self.writeCall)
        let member = try #require(Self.writeMember)
        let whole = NSRange(code.startIndex..<code.endIndex, in: code)
        var found: [String.Index: WriteOccurrence] = [:]

        for match in call.matches(in: code, range: whole) {
            guard let matched = Range(match.range, in: code) else { continue }
            let arguments = argumentList(after: matched.upperBound, in: code)
            if Self.isDeclared(before: matched.lowerBound, in: code) {
                found[matched.lowerBound] = .declaration
            } else if Self.isCompoundName(arguments) {
                found[matched.lowerBound] = .reference
            } else {
                found[matched.lowerBound] = .use("(\(arguments))")
            }
        }
        for match in member.matches(in: code, range: whole) {
            guard let matched = Range(match.range, in: code) else { continue }
            let name = code.index(matched.upperBound, offsetBy: -"write".count)
            if found[name] == nil { found[name] = .use(" taken as a value") }
        }
        return found.sorted { $0.key < $1.key }.map { (occurrence: $0.value, at: $0.key) }
    }

    /// The text inside the parentheses that open at `start`, parenthesis-balanced rather than
    /// stopped at the first `)`, so a nested call in an argument is not read as its end.
    private static func argumentList(after start: String.Index, in code: String) -> String {
        var depth = 1
        var index = start
        while index < code.endIndex, depth > 0 {
            if code[index] == "(" { depth += 1 }
            if code[index] == ")" { depth -= 1 }
            index = code.index(after: index)
        }
        let close = depth == 0 ? code.index(before: index) : code.endIndex
        return String(code[start..<close])
    }

    /// Whether the word immediately before `position`, across whitespace, is `func`.
    static func isDeclared(before position: String.Index, in code: String) -> Bool {
        let before = code[..<position].reversed().drop { $0.isWhitespace }
        let word = before.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(word.reversed()) == "func"
    }

    /// Where in its file an occurrence sits: inside `protocol SMCWriteChannel`, inside
    /// `DaemonWriteChannel`'s `func write` body, elsewhere inside `DaemonWriteChannel`, or none of
    /// those.
    static func container(of position: String.Index, in code: String) throws -> String {
        if let actor = try Self.braced(#"actor\s+DaemonWriteChannel\b[^{]*"#, in: code),
            actor.contains(position)
        {
            let body = String(code[actor])
            if let write = try Self.braced(#"func\s+write\s*\([^{]*"#, in: body) {
                let offset = code.distance(from: actor.lowerBound, to: position)
                let lower = body.distance(from: body.startIndex, to: write.lowerBound)
                let upper = body.distance(from: body.startIndex, to: write.upperBound)
                if (lower..<upper).contains(offset) { return "DaemonWriteChannel.write's body" }
            }
            return "DaemonWriteChannel"
        }
        if let channel = try Self.braced(#"protocol\s+SMCWriteChannel\b[^{]*"#, in: code),
            channel.contains(position)
        {
            return "protocol SMCWriteChannel"
        }
        return "elsewhere"
    }

    /// The range of the braces that follow the first match of `head` in `code`, balanced.
    private static func braced(_ head: String, in code: String) throws -> Range<String.Index>? {
        let pattern = try NSRegularExpression(pattern: head)
        guard
            let match = pattern.firstMatch(
                in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)),
            let matched = Range(match.range, in: code),
            let open = code[matched.upperBound...].firstIndex(of: "{")
        else { return nil }
        let body = RuleZeroScan.balanced(in: code, from: open)
        return body.startIndex..<body.endIndex
    }

    /// Whether an argument list is a compound *name* — `_:to:` — rather than arguments.
    ///
    /// A compound name is a run of `label:` and `_:` and nothing else: no values, no
    /// whitespace, and never empty. `.write()` therefore reads as a call, which is what it
    /// is.
    static func isCompoundName(_ argumentList: String) -> Bool {
        guard !argumentList.isEmpty, argumentList.hasSuffix(":") else { return false }
        return argumentList.split(separator: ":", omittingEmptySubsequences: false)
            .dropLast()
            .allSatisfy { label in
                label == "_"
                    || (!label.isEmpty
                        && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
            }
    }
}
