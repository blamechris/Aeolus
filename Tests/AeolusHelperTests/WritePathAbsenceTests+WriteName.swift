import Foundation
import Testing

/// The name scan behind `WritePathAbsenceTests.helperNeverCallsWrite`, in a file of its own so the
/// suite stays inside `type_body_length`. Internal rather than private for that reason only.
extension WritePathAbsenceTests {

    /// Every occurrence of the *name* `write` followed by an argument list, whether or not
    /// it is reached through a receiver.
    ///
    /// #226's review found the hole this replaces. The scan matched the literal `.write(`,
    /// which is every call written through a receiver — and the reachability probe was an
    /// `extension SMCConnection`, so inside it `self` was the actor and an **unqualified**
    /// `write(bytes, to: key)` compiled into a real SMC write that this scan could not see.
    /// The reviewer's mutation of exactly that shape built clean and left all four controls
    /// green. `WriteSeamReachability` is a free `enum` again, and
    /// `noHelperFileOpensSMCConnectionsIsolation` keeps it that way — but the scan is
    /// widened too, because a receiver-only pattern was never what this test meant.
    ///
    /// A lookbehind on the preceding character is what distinguishes `write(` and
    /// `connection.write(` — both of which count — from `overwrite(` and `didWrite(`, which
    /// are different names.
    ///
    /// A generic clause between the name and the parenthesis — `write<T>(` — is inside the
    /// match too, so a generic declaration or call is not a spelling that hides one.
    static let writeName = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])write\s*(?:<[^<>]*>\s*)?\("#)

    /// One occurrence of the name `write` with a parenthesis after it.
    enum WriteOccurrence: Equatable {
        /// `func write(…)`.
        case declaration
        /// `write(_:to:)`: a compound name, which names a function and calls nothing.
        case reference
        /// Anything else, with its argument list.
        case call(String)
    }

    /// Every `write(…)` occurrence in `code`, classified. The argument list is read
    /// parenthesis-balanced rather than stopped at the first `)`, so a nested call in an
    /// argument is not read as the end of the list; `func` before the name, across any
    /// whitespace, makes it a declaration whatever the list holds.
    static func writeOccurrences(in code: String) throws -> [WriteOccurrence] {
        let pattern = try #require(Self.writeName)
        var occurrences: [WriteOccurrence] = []

        let whole = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in pattern.matches(in: code, range: whole) {
            guard let matched = Range(match.range, in: code) else { continue }
            var depth = 1
            var index = matched.upperBound
            while index < code.endIndex, depth > 0 {
                if code[index] == "(" { depth += 1 }
                if code[index] == ")" { depth -= 1 }
                index = code.index(after: index)
            }
            let close = depth == 0 ? code.index(before: index) : code.endIndex
            let arguments = String(code[matched.upperBound..<close])

            if Self.isDeclared(before: matched.lowerBound, in: code) {
                occurrences.append(.declaration)
            } else if Self.isCompoundName(arguments) {
                occurrences.append(.reference)
            } else {
                occurrences.append(.call(arguments))
            }
        }
        return occurrences
    }

    /// The rule for one occurrence in the helper file `name`: a declaration only in the channel,
    /// a reference only in the probe, and a call nowhere.
    static func judge(_ occurrence: WriteOccurrence, in name: String) {
        switch occurrence {
        case .declaration:
            #expect(
                name == Self.writeChannelDeclaration,
                """
                \(name) declares a write. Only \(Self.writeChannelDeclaration) may, as the \
                channel protocol's one requirement — ADR 0014's B1 amendment.
                """)
        case .reference:
            #expect(
                name == Self.writeSeamProbe,
                """
                \(name) names the SMC write API. Only \(Self.writeSeamProbe) may, and only as a \
                reference — see docs/ADR/0008-write-authorisation.md.
                """)
        case .call(let arguments):
            Issue.record(
                """
                \(name) calls a write: write(\(arguments)). B1 builds no write turn, and the \
                probe references the seam without invoking it.
                """)
        }
    }

    /// Whether the word immediately before `position`, across whitespace, is `func`.
    static func isDeclared(before position: String.Index, in code: String) -> Bool {
        let before = code[..<position].reversed().drop { $0.isWhitespace }
        let word = before.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(word.reversed()) == "func"
    }

    /// Whether the channel file's one `func write(` is inside `protocol SMCWriteChannel`'s
    /// braces: the requirement, rather than a free function or a member of something else.
    static func channelProtocolDeclaresTheWrite() throws -> Bool {
        let file = try #require(
            try SeamScanner.swiftFiles().first {
                $0.lastPathComponent == Self.writeChannelDeclaration
            },
            "\(Self.writeChannelDeclaration) was not found under Sources/")
        let code = SeamScanner.strippingAllComments(try String(contentsOf: file, encoding: .utf8))
            .replacingOccurrences(of: "`", with: "")
        let body = try #require(
            try WriteChannelSeamTests.protocolBodies(in: code)["SMCWriteChannel"],
            "\(Self.writeChannelDeclaration) declares no protocol SMCWriteChannel")
        return try Self.writeOccurrences(in: body) == [.declaration]
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
