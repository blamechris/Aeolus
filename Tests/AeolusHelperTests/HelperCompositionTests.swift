import Foundation
import Testing

@testable import AeolusHelper

/// The composition root, guarded at the source.
///
/// ## Why a source tripwire rather than a behavioural test
///
/// `AeolusHelperMain.main()` resolves a code-signing requirement, binds a Mach service and
/// calls `dispatchMain()`, which never returns. There is no seam to drive it through and
/// nothing to assert against afterwards — so the one line of production code #127 changes,
/// `provider: scheduler.snapshotReader`, had **no coverage of any kind**. A review panel
/// demonstrated the cost: reverting that line to the pre-#127 wiring, deleting the entire
/// production effect of the change while leaving the scheduler constructed, left
/// `swift test --filter AeolusHelperTests` green — 261 tests in 33 suites at the time,
/// hardware suite included. (Figures in this PR come from two baselines: that helper-only
/// filter, and the whole suite. Each is labelled where it is used.)
///
/// `WritePathAbsenceTests` and `WriteAuthorisationTests` already assert properties of the
/// source tree this way, through `SeamScanner`, for the same reason: some invariants are
/// about what is *written*, and no runtime can observe them.
///
/// ## The hazard this exists for
///
/// Two `SMCReadScheduler`s arbitrate nothing while looking exactly like one that does. Each
/// grants turns against a queue the other cannot see, so the safety cycle and the client
/// snapshot contend exactly as they did before #127 — with all the machinery for fixing it
/// present, tested, and bypassed. `AeolusHelperMain` warns #103 about this in a comment;
/// this is the same warning in a form that fails.
@Suite("The helper's composition root")
struct HelperCompositionTests {

    private static func mainSource() throws -> String {
        let file = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == "AeolusHelperMain.swift" },
            "AeolusHelperMain.swift was not found in Sources")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// **Mutation:** restore the pre-#127 line —
    /// `ReadOnlyFanAuthority(provider: SMCSensorProvider(), …)`. Run: red here, and green
    /// everywhere else in the repository, which is the whole point of the file.
    @Test("The read-only authority is given the scheduler's snapshot reader, not a raw provider")
    func theAuthorityReadsThroughTheScheduler() throws {
        let source = Self.strippingComments(try Self.mainSource())

        #expect(
            source.contains("provider: scheduler.snapshotReader"),
            "the snapshot path no longer takes its turns from the scheduler")
        #expect(
            source.contains("SMCReadScheduler(") && source.contains("SMCSensorProvider()"),
            "the scheduler is no longer the thing holding the real provider")
    }

    /// The mode read goes through the **same** reader as the fans beside it, at snapshot
    /// priority.
    ///
    /// Two ways this line can regress and neither shows up at runtime here. Dropping the
    /// argument is impossible — the initialiser requires it — but wiring it to a *second*
    /// source would make one snapshot a composite of two connections, and wiring it to an
    /// `SMCFanControlPlane` would issue a client's 1 Hz reporting at `.supervisor`, which is
    /// the priority § 3's safety cycle is meant to have to itself. `main()` ends in
    /// `dispatchMain()` and has no seam to drive, so this is asserted at the source for the
    /// reason the whole suite exists.
    ///
    /// **Mutation:** change `main()` to
    /// `fanMode: SnapshotFanModeReads(provider: SMCSensorProvider())`. Run: red here — and
    /// red in `nothingInTheHelperReadsAroundTheGate` too, which is the pair working.
    @Test("The mode read is wired to the scheduler's snapshot reader, like the fan read")
    func theModeReadTakesTheSameTurnsAsTheFanRead() throws {
        let source = Self.strippingComments(try Self.mainSource())

        // Two fragments rather than one exact single-line literal, which is the brittleness
        // this file's own documentation records: the wired expression is nested, and a nested
        // construction is exactly what `swift format` wraps — so a one-line match would turn a
        // *correct* composition red the day the line grew past the column limit. Each fragment
        // names one of the two ways this line can regress, and each survives a wrap.
        #expect(
            source.contains("fanMode: SnapshotFanModeReads("),
            """
            F<n>Md is no longer read through the snapshot path's own conformer, so it is \
            either a second source or a supervisor-priority read on a client's 1 Hz path.
            """)
        // The provider inside that construction, matched on the whitespace-stripped source so
        // the label may sit on its own line. Anchored to `SnapshotFanModeReads(` so it cannot
        // be satisfied by the authority's own `provider:` argument two lines above.
        #expect(
            Self.strippingWhitespace(source)
                .contains("SnapshotFanModeReads(provider:scheduler.snapshotReader)"),
            """
            F<n>Md is no longer read through the scheduler's snapshot reader, so one \
            snapshot is a composite of two connections or a read that takes no turn.
            """)
    }

    /// Nothing in the helper may hold a raw `SMCSensorProvider`, anywhere.
    ///
    /// **Scoped to the whole of `Sources/AeolusHelper`, and it was one file until a review
    /// caught that.** The earlier version counted occurrences inside `AeolusHelperMain.swift`
    /// alone, so a second raw provider in any *other* helper file was invisible: a probe file
    /// doing `try await SMCSensorProvider().read(keys:)` left both tests in this suite green.
    /// Such a read takes no turn, sees no queue and is invisible to the safety cycle — and it
    /// is the shortest path to a read at boot, which is exactly what
    /// [#103](https://github.com/blamechris/Aeolus/issues/103)'s startup reconciliation wants
    /// before the scheduler holds any state at all. The hazard was never confined to one
    /// file, so neither is the guard.
    ///
    /// `fanctl` and the app are deliberately **not** covered: ADR 0006 makes them direct
    /// readers in their own processes, and the corollary it states — at most one continuous
    /// poller per machine — is about the helper's connection, not theirs.
    ///
    /// **Mutation:** add `SMCSensorProvider()` to any file under `Sources/AeolusHelper`.
    /// Run: red.
    @Test("Only the scheduler holds a raw provider, across the whole helper")
    func nothingInTheHelperReadsAroundTheGate() throws {
        var sites: [String] = []
        for file in try SeamScanner.swiftFiles()
        where file.pathComponents.contains("AeolusHelper") {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let count = Self.occurrences(of: "SMCSensorProvider(", in: code)
            if count > 0 { sites.append("\(file.lastPathComponent) x\(count)") }
        }

        #expect(
            sites == ["AeolusHelperMain.swift x1"],
            """
            a helper-side SMC read that takes no turn is invisible to the safety cycle: \
            \(sites). The one permitted construction is the scheduler's own.
            """)
    }

    /// **Matched on `SMCReadScheduler(`, not on `SMCReadScheduler(provider:`.** The narrower
    /// string was the first version and it had a hole big enough to drive #103 through: a
    /// nested construction is exactly what `swift format` wraps, so
    ///
    /// ```swift
    /// let plane = SMCFanControlPlane(
    ///     scheduler: SMCReadScheduler(
    ///         provider: scheduler.snapshotReader))
    /// ```
    ///
    /// puts the label on the next line and slips past — a second scheduler, both guards
    /// green, the formatter satisfied. That is the precise shape this suite exists to catch,
    /// so the pattern has to survive line wrapping.
    ///
    /// Comment lines are stripped first, because the mirror-image false positive is just as
    /// live: `AeolusHelperMain` names the type in a comment addressed to #103, and a scanner
    /// that counted it would fail on prose. `SeamScanner` warns about exactly this.
    ///
    /// **Mutation:** add a second construction anywhere in `Sources/`, wrapped or not,
    /// including `SMCReadScheduler.init(provider:)`. Run: red.
    @Test("Exactly one scheduler is constructed in the whole of Sources")
    func onlyOneSchedulerIsEverBuilt() throws {
        var constructions: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = Self.strippingComments(source)
            let count =
                Self.occurrences(of: "SMCReadScheduler(", in: code)
                + Self.occurrences(of: "SMCReadScheduler.init(", in: code)
            if count > 0 {
                constructions.append("\(file.lastPathComponent) x\(count)")
            }
        }

        #expect(
            constructions == ["AeolusHelperMain.swift x1"],
            """
            the SMC connection is arbitrated by one scheduler or by none: \(constructions). \
            A second scheduler grants turns against a queue the first cannot see, so the \
            safety cycle and the snapshot contend exactly as they did before #127.
            """)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The same source with **every** whitespace character removed.
    ///
    /// So a match can name one composed expression exactly without depending on where
    /// `swift format` chose to wrap it. `contains("A(b: c)")` is precise and brittle;
    /// `contains("A(") && contains("c")` is wrap-proof and imprecise; this is both.
    private static func strippingWhitespace(_ source: String) -> String {
        source.filter { !$0.isWhitespace }
    }

    /// Drops `//` line comments so prose naming a type is not mistaken for code building one.
    ///
    /// Line comments only: this scans a composition root, and a block comment there would be
    /// a stranger thing than the hazard being guarded against.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
