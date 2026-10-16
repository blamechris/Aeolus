import Foundation
import Testing

/// [#368](https://github.com/blamechris/Aeolus/issues/368): no lease-core teardown suspends
/// between taking its lease out of the table and counting its fans into `releasing`.
///
/// `revokeLease(id:forFan:because:)` answers `.gone` once the fan it names has left
/// `releasing`, so the premise its wait rests on is that no revocation can find the lease gone
/// while the count is still zero. That interval runs from the teardown's table removal, through
/// its call to `restore(_:because:)` and that call's arguments, to the counting loop at the head
/// of `restore`'s body. The two tests here hold it: one up to the call, its arguments included,
/// one from the call to the count.
///
/// Source tripwires over the same `LeaseAuthority.swift` `TeardownSweepTripwireTests` reads,
/// beside that suite rather than in it so neither file outgrows SwiftLint's `file_length`.
@Suite("No teardown suspends between taking its lease out of the table and counting its fans")
struct TeardownCountTripwireTests {

    /// The seven lease-core teardown paths: each takes its entries out of the table and hands
    /// their fans to `restore(_:because:)`, which counts them into `releasing` before it awaits.
    private static let teardownPaths = [
        "releaseLease", "expireLapsedLeases", "connectionDidInvalidate", "revokeLeases",
        "revokeLease", "revokeEveryLease", "releaseEveryLease",
    ]

    /// A table removal, in normalised code: `table.remove(`, `table.removeLapsed(`,
    /// `table.removeAll(`.
    private static let tableRemoval = #"\btable\.remove\w*\("#

    /// The restore that counts the fans, awaited, with or without `self.`.
    private static let countingRestore = #"\bawait (self\.)?restore\("#

    /// The count itself, inside `restore(_:because:)`: `registers.beginHandback(ofFan: fan)`,
    /// the transition that runs `releasing[fan, default: 0] += 1` since #128's lease-core pass
    /// moved `releasing` into `LeaseAuthority.HandbackRegisters`. A call rather than the
    /// statement, and still the count: nothing in that type can suspend
    /// (`LeaseAuthorityRegistersAccessTests`), and an `await` written before the call is in the
    /// prologue this suite reads.
    private static let releasingCount = #"\bregisters\.beginHandback\(ofFan:"#

    /// The one member read an argument to the counting restore may make: the removed entry's fans.
    private static let readableMembers: Set<String> = ["entry.fanIndices"]

    /// [#368](https://github.com/blamechris/Aeolus/issues/368): no teardown suspends between
    /// taking its entries out of the table and calling `restore(_:because:)`, nor while that
    /// call's arguments are evaluated.
    ///
    /// `revokeLease(id:forFan:because:)` answers `.gone` once the fan has left `releasing`. A
    /// teardown that suspended after its removal and before the count would leave the lease gone
    /// and the count still zero, so a revocation landing there answers at once and the teardown's
    /// notice can erase § 5's mark again. ADR 0009's assumption table states the premise; this and
    /// `theRestoreCountsBeforeItSuspends` are what fail when it stops being true — this up to the
    /// call, that from the call to the count.
    ///
    /// **The arguments are judged by what they may be, not by what they may not.** A cross-actor
    /// read suspends under the call's own `await` with no `(` in sight —
    /// `emergencyRestores?.fansAwaitingRestoreConfirmation ?? fans` — so a ban on calls alone is
    /// not enough. Each name an argument uses must be one the function bound (a parameter, a
    /// `let`, a `var` or a loop variable), a leading-dot literal such as `.leaseExpired`, or a
    /// member read in `readableMembers`; no `(`, `[`, `{` or optional chain may appear. Anything
    /// else fails, and is either a suspension or a new shape to acknowledge here.
    ///
    /// The code is normalised first — comments stripped, whitespace and line breaks collapsed,
    /// and the space around `.` and before `(` removed — so `table . removeAll ( )`, a removal
    /// split over lines and an `await` on a line of its own read as what they compile to.
    ///
    /// **Mutation (P1):** add `await Task.yield()` to `expireLapsedLeases()` between the
    /// `reduce` and `await restore(…)`. Run: red, naming it. **Mutation:** the same in
    /// `connectionDidInvalidate(_:)`, after `guard !released.isEmpty`. Run: red.
    /// **Mutation (Earg2):** in `expireLapsedLeases()`, `await restore(fans.union(
    /// emergencyRestores?.fansAwaitingRestoreConfirmation ?? []).intersection(fans), because:
    /// .leaseExpired)`. Run: red on the call. **Mutation (Earg3):** the same read with no call,
    /// `await restore(emergencyRestores?.fansAwaitingRestoreConfirmation ?? fans, because:
    /// .leaseExpired)`. Run: red on the unbound name.
    /// **Mutation (this suite's own):** replace `tableRemoval` with a pattern nothing matches.
    /// Run: red on coverage rather than green over paths it never read.
    @Test("No teardown path suspends between its table removal and its restore")
    func noTeardownSuspendsBetweenItsRemovalAndItsRestore() throws {
        let code = Self.normalised(try Self.leaseCoreWithoutAnyComment())

        var checked: [String] = []
        var offenders: [String] = []
        for path in Self.teardownPaths {
            guard let function = Self.function(named: path, in: code),
                let removal = function.body.range(
                    of: Self.tableRemoval, options: .regularExpression),
                let restore = function.body.range(
                    of: Self.countingRestore, options: .regularExpression,
                    range: removal.upperBound..<function.body.endIndex),
                let close = Self.closingParenthesis(in: function.body, after: restore.upperBound)
            else { continue }
            checked.append(path)
            let between = function.body[removal.lowerBound..<restore.lowerBound]
            if between.range(of: #"\bawait\b"#, options: .regularExpression) != nil {
                offenders.append("\(path): \(between)")
            }
            let arguments = function.body[restore.upperBound..<close]
            let bound = try Self.boundNames(in: function)
            if let suspending = try Self.suspendingPart(of: arguments, bound: bound) {
                offenders.append("\(path)'s restore(\(arguments)): \(suspending)")
            }
        }

        #expect(
            checked == Self.teardownPaths,
            """
            the scan found a table removal followed by an awaited restore in \(checked), and \
            expected all of \(Self.teardownPaths). A path it cannot read is one it cannot judge, \
            so either a teardown was renamed or restructured, or the patterns stopped matching.
            """)
        #expect(
            offenders.isEmpty,
            """
            a teardown suspends between taking its entries out of the table and counting their \
            fans into `releasing`: \(offenders). A revocation landing in that suspension finds \
            the lease gone and nothing to outwait, and the teardown's release notice can then \
            erase § 5's mark (#368). Keep the removal and the `restore(_:because:)` call in one \
            straight-line region, and pass the call only what the function already holds.
            """)
    }

    /// The other half of the premise: `restore(_:because:)` counts its fans into `releasing`
    /// before its first suspension, so the count is in the same straight-line region as the
    /// caller's removal.
    ///
    /// **Mutation (P2):** add `await Task.yield()` to `restore(_:because:)` between
    /// `log.restored(fans:because:)` and the counting loop. Run: red, naming the prologue.
    /// **Mutation (this suite's own):** replace `releasingCount` with a pattern nothing matches.
    /// Run: red on the `#require` rather than green over a count it never found.
    @Test("restore(_:because:) counts its fans into releasing before it first suspends")
    func theRestoreCountsBeforeItSuspends() throws {
        let code = Self.normalised(try Self.leaseCoreWithoutAnyComment())
        let restore = try #require(
            Self.function(named: "restore", in: code),
            "the lease core declares no `func restore(`, so the count was not read")
        let count = try #require(
            restore.body.range(of: Self.releasingCount, options: .regularExpression),
            "restore(_:because:) has no `registers.beginHandback(ofFan:)` this scan can find")

        let prologue = restore.body[..<count.lowerBound]
        #expect(
            prologue.range(of: #"\bawait\b"#, options: .regularExpression) == nil,
            """
            restore(_:because:) suspends before it counts its fans into `releasing`: \
            \(prologue). A caller's lease is already out of the table by then, so a revocation \
            landing in that suspension finds nothing to outwait and the teardown's notice can \
            erase § 5's mark (#368). Count first; the restorer's await comes after.
            """)
    }

    // MARK: - Parsing

    /// `code` with whitespace and line breaks collapsed to single spaces, then the space around
    /// each `.` and before each `(` removed.
    private static func normalised(_ code: String) -> String {
        SeamScanner.collapsingWhitespace(code)
            .replacingOccurrences(of: #"\s*\.\s*"#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #"\s+\("#, with: "(", options: .regularExpression)
    }

    /// `LeaseAuthority.swift` with every comment stripped, trailing ones included, through the
    /// scanner's `strippingAllComments`, which leaves a `//` inside a string literal alone. A
    /// trailing `// await` would otherwise read as a suspension, and once whitespace is collapsed
    /// a trailing comment would swallow the rest of the function.
    private static func leaseCoreWithoutAnyComment() throws -> String {
        SeamScanner.strippingAllComments(try TeardownSweepTripwireTests.leaseCoreSource())
    }

    /// The parameter list and body of `func name(` in normalised `code`, or `nil` when it is not
    /// declared there. `(` is part of the match, so `revokeLease` does not find `revokeLeases`.
    private static func function(
        named name: String, in code: String
    ) -> (parameters: Substring, body: Substring)? {
        guard
            let declaration = code.range(
                of: #"\bfunc "# + name + #"\("#, options: .regularExpression),
            let close = Self.closingParenthesis(in: code[...], after: declaration.upperBound),
            let body = TeardownSweepTripwireTests.bracedBody(in: code, after: close)
        else { return nil }
        return (code[declaration.upperBound..<close], code[body])
    }

    /// The `)` closing the `(` that ends just before `index`, by depth count.
    private static func closingParenthesis(
        in text: Substring, after index: String.Index
    ) -> String.Index? {
        var depth = 1
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor] == "(" { depth += 1 }
            if text[cursor] == ")" { depth -= 1 }
            if depth == 0 { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// Every name `function` binds: its parameters' internal names, and each `let`, `var` and
    /// `for` variable in its body.
    private static func boundNames(
        in function: (parameters: Substring, body: Substring)
    ) throws -> Set<String> {
        var names: Set<String> = []
        for parameter in function.parameters.split(separator: ",") {
            guard let colon = parameter.firstIndex(of: ":"),
                let name = parameter[..<colon].split(separator: " ").last
            else { continue }
            names.insert(String(name))
        }
        let body = String(function.body)
        let binding = try NSRegularExpression(
            pattern: #"\b(?:let|var|for)\s+([A-Za-z_]\w*)"#)
        for match in binding.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            if let range = Range(match.range(at: 1), in: body) { names.insert(String(body[range])) }
        }
        return names
    }

    /// What in a counting restore's `arguments` could suspend, or `nil` when nothing can — by
    /// `noTeardownSuspendsBetweenItsRemovalAndItsRestore`'s positive grammar.
    private static func suspendingPart(
        of arguments: Substring, bound: Set<String>
    ) throws -> String? {
        let text = String(arguments).replacingOccurrences(
            of: #"\bbecause:"#, with: " ", options: .regularExpression)
        let word = try NSRegularExpression(pattern: #"\.?[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*"#)
        let all = NSRange(text.startIndex..., in: text)
        for match in word.matches(in: text, range: all) {
            guard let range = Range(match.range, in: text) else { continue }
            let name = String(text[range])
            if name.hasPrefix(".") {
                guard Self.startsALiteral(at: range.lowerBound, in: text) else {
                    return "the member read `\(name)`"
                }
            } else if name.contains(".") {
                guard Self.readableMembers.contains(name) else {
                    return "the member read `\(name)`"
                }
            } else if !bound.contains(name), !["nil", "true", "false"].contains(name) {
                return "`\(name)`, which the function does not bind"
            }
        }
        let rest = word.stringByReplacingMatches(in: text, range: all, withTemplate: " ")
        guard rest.range(of: #"[^\s,:?=!<>|&+\-0-9]"#, options: .regularExpression) == nil else {
            return "`\(rest.filter { !$0.isWhitespace })`, which no argument here needs"
        }
        return nil
    }

    /// Whether the `.` at `index` opens a literal such as `.leaseExpired` rather than reading a
    /// member: it follows a separator, or a ternary's `?` (one with a space before it), and not
    /// a name or an optional chain's `?`.
    private static func startsALiteral(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        guard before == "?" else { return " ,:=!<>|&".contains(before) }
        let question = text.index(before: index)
        return question > text.startIndex && text[text.index(before: question)] == " "
    }
}
