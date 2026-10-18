import Foundation
import Testing

/// [#368](https://github.com/blamechris/Aeolus/issues/368): no lease-core teardown suspends
/// between taking its lease out of the table and counting its fans into `releasing`, and no
/// `.gone` revocation suspends between asking for that count and waiting on it.
///
/// `revokeLease(id:forFan:because:)` answers `.gone` once the fan it names has left
/// `releasing`, so the premise its wait rests on is that no revocation can find the lease gone
/// while the count is still zero. That interval runs from the teardown's table removal, through
/// its call to `restore(_:because:)` and that call's arguments, to the counting loop at the head
/// of `restore`'s body. Two tests here hold it: one up to the call, its arguments included,
/// one from the call to the last fan's count. The third holds the wait itself: the check and
/// the park in `outwaitHandback(of:)` are one synchronous region.
///
/// Source tripwires over the same `LeaseAuthority.swift` `TeardownSweepTripwireTests` reads,
/// beside that suite rather than in it so neither file outgrows SwiftLint's `file_length`.
@Suite("No teardown suspends before its fans are counted, nor a revocation before it parks")
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

    /// The other half of the premise: `restore(_:because:)` counts **every** fan into
    /// `releasing` before its first suspension, so the whole count is in the same straight-line
    /// region as the caller's removal.
    ///
    /// The region read runs from the top of the body to the **last** count, and, when that count
    /// is inside a block — the `for fan in fans { … }` loop — to that block's closing brace. A
    /// suspension between one fan's count and the next leaves the second fan uncounted across
    /// it, which the first count alone would not show.
    ///
    /// **Mutation (P2):** add `await Task.yield()` to `restore(_:because:)` between
    /// `log.restored(fans:because:)` and the counting loop. Run: red, naming the prologue.
    /// **Mutation:** `await Task.yield()` inside the counting loop, after
    /// `registers.beginHandback(ofFan: fan)`. Run: red. **Mutation:** the count moved below
    /// `await restorer.restoreToAutomatic(…)`. Run: red.
    /// **Mutation (this suite's own):** replace `releasingCount` with a pattern nothing matches.
    /// Run: red on the `#require` rather than green over a count it never found.
    ///
    /// **Two declarations since #440, one body.** `restore(_:because:)` forwards to
    /// `restore(_:because:through:)` with the lease core's own restorer, and § 3's revocation
    /// calls the second with the handback it borrows. The count is read in the one that counts,
    /// and every other `restore` must be that forward alone — a single awaited same-actor call
    /// with nothing before it, which is the shape every teardown's own call already has.
    /// **Mutation:** add `await Task.yield()` above the forward in `restore(_:because:)`. Run: red.
    @Test("restore(_:because:) counts every fan into releasing before it first suspends")
    func theRestoreCountsBeforeItSuspends() throws {
        let code = Self.normalised(try Self.leaseCoreWithoutAnyComment())
        let declared = Self.functions(named: "restore", in: code)
        let counting = declared.filter {
            $0.body.range(of: Self.releasingCount, options: .regularExpression) != nil
        }
        #expect(
            declared.count == 2 && counting.count == 1,
            """
            the lease core declares \(declared.count) `func restore` and \(counting.count) of \
            them count into `releasing`; it should declare the counting body and one forward to it.
            """)
        for forward in declared
        where forward.body.range(of: Self.releasingCount, options: .regularExpression) == nil {
            #expect(
                forward.body.range(
                    of: #"^\s*await restore\([^()]*\)\s*$"#, options: .regularExpression) != nil,
                """
                a `restore` that does not count is more than a forward to the one that does: \
                \(forward.body). Anything it awaits first is a suspension between a caller's \
                removal and the count (#368).
                """)
        }
        let restore = try #require(
            counting.first,
            "the lease core declares no counting `func restore`, so the count was not read")
        let count = try #require(
            Self.lastMatch(of: Self.releasingCount, in: restore.body),
            "restore(_:because:) has no `registers.beginHandback(ofFan:)` this scan can find")

        let prologue = restore.body[..<Self.endOfStatement(at: count, in: code, of: restore.body)]
        #expect(
            prologue.range(of: #"\bawait\b"#, options: .regularExpression) == nil,
            """
            restore(_:because:) suspends before it has counted every fan into `releasing`: \
            \(prologue). A caller's lease is already out of the table by then, so a revocation \
            landing in that suspension finds a fan with nothing to outwait and the teardown's \
            notice can erase § 5's mark (#368). Count first; the restorer's await comes after.
            """)
    }

    /// The revocation's own half of #368's premise: `outwaitHandback(of:)` asks whether the fan
    /// has a restore on the wire, and parks, in one synchronous region — the body of
    /// `withCheckedContinuation`'s closure, which cannot suspend. A suspension between the check
    /// and the park lets the count drain unseen, and the waiter is parked on a fan nothing will
    /// ever resume, which leaves § 5 parked for the life of the process (#375's review).
    ///
    /// Two things, both read off the normalised body: it holds **exactly one** `await`, and it
    /// is `await withCheckedContinuation`; and `registers.isMidHandback(` is inside that
    /// closure. `await` is matched as a word after comments are stripped and whitespace
    /// collapsed, so `await(…)`, a doubled space and an `await` on a line of its own all count.
    ///
    /// **Mutation (X13):** move the check out of the continuation — `guard
    /// registers.isMidHandback(fan) else { return }` and `await Task.yield()` above `await
    /// withCheckedContinuation`, the closure only parking. Run: red on both. **Mutation:** add
    /// `await Task.yield()` above `await withCheckedContinuation`, the check left inside. Run:
    /// red on the count. **Mutation:** `let busy = registers.isMidHandback(fan)` above the
    /// continuation and `guard busy` inside it. Run: red on the check.
    @Test("A .gone revocation checks for a handback and parks without suspending between")
    func theOutwaitChecksAndParksInOneRegion() throws {
        let code = Self.normalised(try Self.leaseCoreWithoutAnyComment())
        let outwait = try #require(
            Self.function(named: "outwaitHandback", in: code),
            "the lease core declares no `func outwaitHandback(`, so the park was not read")

        let awaits = Self.matches(of: #"\bawait\b"#, in: outwait.body)
        let park = outwait.body.range(
            of: #"\bawait withCheckedContinuation\s*\{"#, options: .regularExpression)
        #expect(
            awaits.count == 1 && park?.lowerBound == awaits.first?.lowerBound,
            """
            outwaitHandback(of:) awaits \(awaits.count) time(s), and its one await must be the \
            park: \(outwait.body). A suspension before `withCheckedContinuation` lets the fan's \
            count drain while the revocation is not yet a waiter, and nothing resumes it after.
            """)

        let closure = try #require(
            park.flatMap { TeardownSweepTripwireTests.bracedBody(in: code, after: $0.lowerBound) },
            "outwaitHandback(of:) has no `await withCheckedContinuation { … }` this scan can read")
        #expect(
            code[closure].contains("registers.isMidHandback("),
            """
            outwaitHandback(of:) does not ask `registers.isMidHandback(_:)` inside the \
            continuation's closure: \(code[closure]). A check made before the closure is a \
            check made before the park, and the count can drain between them.
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

    /// The parameter list and body of the first `func name(` in normalised `code`, or `nil`
    /// when it is not declared there. `(` is part of the match, so `revokeLease` does not find
    /// `revokeLeases`; a generic parameter clause between the name and the `(` is allowed, so a
    /// verb that borrows a generic restorer (#440) is read too.
    private static func function(
        named name: String, in code: String
    ) -> (parameters: Substring, body: Substring)? {
        functions(named: name, in: code).first
    }

    /// Every declaration of `func name(` in normalised `code`, in order — `function(named:in:)`'s
    /// reading of each.
    private static func functions(
        named name: String, in code: String
    ) -> [(parameters: Substring, body: Substring)] {
        let pattern = #"\bfunc "# + name + #"(?:<[^<>{}]*>)?\("#
        var found: [(parameters: Substring, body: Substring)] = []
        var search = code.startIndex
        while true {
            guard
                let declaration = code.range(
                    of: pattern, options: .regularExpression, range: search..<code.endIndex)
            else { break }
            search = declaration.upperBound
            guard let close = Self.closingParenthesis(in: code[...], after: declaration.upperBound),
                let body = TeardownSweepTripwireTests.bracedBody(in: code, after: close)
            else { continue }
            found.append((code[declaration.upperBound..<close], code[body]))
        }
        return found
    }

    /// Every match of `pattern` in `text`, in order.
    private static func matches(of pattern: String, in text: Substring) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var rest = text[...]
        while let match = rest.range(of: pattern, options: .regularExpression) {
            found.append(match)
            rest = text[match.upperBound...]
        }
        return found
    }

    /// The last match of `pattern` in `text`, or `nil` when there is none.
    private static func lastMatch(of pattern: String, in text: Substring) -> Range<String.Index>? {
        matches(of: pattern, in: text).last
    }

    /// Where the statement holding `match` ends in `body`, a slice of `code`: the closing brace
    /// of the outermost block of `body` that is open at `match` — the counting loop's — or the
    /// end of `match` itself when it is written at the top level of `body`.
    private static func endOfStatement(
        at match: Range<String.Index>, in code: String, of body: Substring
    ) -> String.Index {
        var open: [String.Index] = []
        var cursor = body.startIndex
        while cursor < match.lowerBound {
            if body[cursor] == "{" { open.append(cursor) }
            if body[cursor] == "}" { _ = open.popLast() }
            cursor = body.index(after: cursor)
        }
        guard let outermost = open.first,
            let block = TeardownSweepTripwireTests.bracedBody(in: code, after: outermost)
        else { return match.upperBound }
        return block.upperBound
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
            of: #"\b(?:because|through):"#, with: " ", options: .regularExpression)
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
