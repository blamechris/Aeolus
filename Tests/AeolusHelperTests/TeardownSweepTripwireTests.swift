import Foundation
import Testing

@testable import AeolusHelper

/// [#188](https://github.com/blamechris/Aeolus/issues/188): a teardown hands back **the whole
/// sweep in one `restore` call**, never one entry at a time.
///
/// ## Why a tripwire, and what it is not a substitute for
///
/// `LeaseAuthority.restore(_:because:)` registers every fan it is given in `releasing` before
/// it awaits anything, so one call puts the entire sweep inside the handback window. A loop puts
/// entry 1 inside it and leaves entries 2..n outside for the whole duration of entry 1's
/// restore, which is the window `.releaseInProgress` was introduced to close, reopened for every
/// entry but the first.
///
/// #188's own acceptance criteria says a behavioural test of that needs two entries in the table
/// and therefore *"cannot be written until the single-lease guard is relaxed"*. One is written
/// anyway —
/// `AbandonedHandbackRecoveryTests.everyFanInThePanicSweepIsInsideTheHandbackWindow` — because
/// § 7's sweep now has two **sources** rather than needing two entries. That test is the real
/// one and this suite does not replace it.
///
/// What this covers is the other four sweeps, where `guard table.isEmpty` still holds the table
/// to a single entry and the shapes are therefore behaviourally identical. They are written the
/// one way so the reachable sweep is not a special case whose reason nobody can see — and #188's
/// central complaint is that the safety of the per-entry shape rested on an invariant *"enforced
/// somewhere else entirely, by a guard whose purpose is concurrent-lease refusal rather than
/// handback safety — so nothing links the two, and nothing fails if the link is broken"*. A
/// tripwire is what makes something fail.
///
/// ## The limit, stated rather than discovered later
///
/// Text matching over stripped source. It catches the realistic regression — somebody restoring
/// per entry again because the diff reads more simply that way — and not a restore reached
/// through a name it cannot recognise. The coverage assertions are what stop a scan that reads
/// nothing from reporting the tree clean, which is the failure mode a source tripwire has and a
/// behavioural test does not.
@Suite("No teardown path awaits a restore one entry at a time")
struct TeardownSweepTripwireTests {

    private static let leaseCoreFile = "LeaseAuthority.swift"

    /// A `for … in …` header, spelled so it cannot match an argument label. `(for connection:`
    /// contains `for ` and nothing else about it is a loop; a pattern that matched it would
    /// brace-walk a function body and answer about the wrong code.
    private static let loopHeader = #"for\s+[A-Za-z_][A-Za-z0-9_]*\s+in\s"#

    /// The call this suite is about. `restore(` and not `restoreToAutomatic(` or `restored(` —
    /// the first is the actor's own private verb, the other two are the seam it calls and the
    /// log line beside it, and both legitimately appear inside loops.
    private static let restoreCall = "await restore("

    /// **Mutation:** revert `expireLapsedLeases()` to `for entry in lapsed { await
    /// restore(entry.fanIndices, because: .leaseExpired) }`. Run: red, naming
    /// `for entry in lapsed {` — and no behavioural test in the suite moves, which is why this
    /// one exists.
    /// **Mutation:** the same revert in `releaseEveryLease()`, either order. Run: red here and
    /// in `everyFanInThePanicSweepIsInsideTheHandbackWindow`, which is the overlap that says the
    /// two agree about the same defect.
    /// **Mutation (this suite's own):** replace `loopHeader` with a pattern nothing matches.
    /// Run: red on the coverage assertion at `loops >= 3` rather than passing over a file it
    /// read nothing in — the failure a source tripwire has and a behavioural test does not.
    @Test("No loop in the lease core encloses a restore")
    func noLoopInTheLeaseCoreEnclosesARestore() throws {
        let code = try Self.strippedLeaseCore()

        var loops = 0
        var offenders: [String] = []
        var search = code.startIndex
        while let header = Self.nextLoopHeader(in: code, from: search) {
            search = header.upperBound
            guard let body = Self.bracedBody(in: code, after: header.upperBound) else { continue }
            loops += 1
            if code[body].contains(Self.restoreCall) {
                let opening = String(code[header.lowerBound..<body.lowerBound])
                offenders.append(SeamScanner.collapsingWhitespace(opening))
            }
        }

        // Coverage, not decoration. A regex that stopped matching, a renamed file or a brace
        // walk that fell over would leave `offenders` empty over source nobody read — which is
        // exactly how a tripwire passes for the life of a defect. Both numbers are floors set AT
        // what the file holds as this lands — four loops, six restore call sites — so a change
        // that ADDS either need not come back here, while one that stops a currently-detected
        // site from matching does. A floor one below the true count is the same hole, one notch
        // smaller: a whole expected site can go undetected and still read as coverage.
        #expect(
            loops >= 4,
            """
            the loop scan found \(loops) for-in loops in \(Self.leaseCoreFile). It is supposed \
            to find the two log loops in the revocation paths and the two in \
            `restore(_:because:)` itself, so the assertion below is green over nothing.
            """)
        #expect(
            code.components(separatedBy: Self.restoreCall).count - 1 >= 6,
            """
            \(Self.leaseCoreFile) names `\(Self.restoreCall)` fewer than six times. Either the \
            teardown paths no longer restore — which is docs/SAFETY.md § 1's whole substance — \
            or this scan is not reading the lease core.
            """)

        #expect(
            offenders.isEmpty,
            """
            a teardown path awaits a restore inside a loop: \(offenders). \
            `restore(_:because:)` registers the fans it is given in `releasing` before it \
            awaits, so a per-entry loop leaves every entry but the first outside the handback \
            window for the whole duration of the first entry's restore — #188. Remove the \
            entries synchronously, then hand the sweep back in one call. If a loop here \
            legitimately restores one entry at a time, that is a decision about the window \
            `.releaseInProgress` closes and belongs beside \
            `AbandonedHandbackRecoveryTests.everyFanInThePanicSweepIsInsideTheHandbackWindow`, \
            which demonstrates what it costs.
            """)
    }

    // MARK: - Parsing

    /// `LeaseAuthority.swift` with its comments stripped.
    ///
    /// Stripping is not optional here: every doc comment in that file that names
    /// `restore(_:because:)` contains the `restore(` this scan looks for, and several sit above
    /// loops. A tripwire that fires on the prose explaining the rule is a tripwire nobody keeps
    /// — `PanicPathScopeTripwireTests` records the same finding.
    private static func strippedLeaseCore() throws -> String {
        let url = try #require(
            try SeamScanner.swiftFiles().first { $0.lastPathComponent == Self.leaseCoreFile },
            "\(Self.leaseCoreFile) is not in the source tree")
        return SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// The next `for … in …` header at or after `from`, or `nil` when there is none.
    ///
    /// A named call rather than the `code.range(of:options:range:)` expression inline in the
    /// `while` condition: wrapped across lines, that condition puts the loop's opening brace on
    /// a line of its own, which `swift format` requires and SwiftLint's `opening_brace` rejects.
    /// One authority per concern is this repository's answer to that class of conflict, and here
    /// it costs nothing to satisfy both.
    private static func nextLoopHeader(
        in code: String, from index: String.Index
    ) -> Range<String.Index>? {
        code.range(
            of: Self.loopHeader, options: .regularExpression, range: index..<code.endIndex)
    }

    /// The brace-balanced body that opens at the first `{` at or after `index`, or `nil` when
    /// the braces do not balance.
    ///
    /// Local for `PanicPathScopeTripwireTests.functionBody`'s reason: `SeamScanner` owns the
    /// primitives more than one suite has to agree on, and a one-caller brace walk is not one
    /// of them.
    private static func bracedBody(
        in code: String, after index: String.Index
    ) -> Range<String.Index>? {
        guard let open = code.range(of: "{", range: index..<code.endIndex) else { return nil }
        var depth = 1
        var cursor = open.upperBound
        while cursor < code.endIndex, depth > 0 {
            if code[cursor] == "{" { depth += 1 }
            if code[cursor] == "}" { depth -= 1 }
            cursor = code.index(after: cursor)
        }
        guard depth == 0 else { return nil }
        return open.upperBound..<code.index(before: cursor)
    }
}
