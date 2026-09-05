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
/// ## Two files now, and which invariant lives where
///
/// #163 split the graph out of the entry point: `HelperComposition.swift` wires every
/// mechanism, `AeolusHelperMain.swift` owns the lifecycle. The tripwires moved with the code
/// they guard — the scheduler and provider assertions scan the composition, the advertising
/// order scans `main`. What is guarded is unchanged, and one of the four is now weaker on
/// purpose because the code became stronger: see
/// `theModeReadIsBuiltFromTheSameProviderAsTheFanRead`.
///
/// The behavioural half of this suite — a lease acquired and torn down through the composed
/// graph — is `HelperRestorerTests`, which composes the *same* type over
/// `ScriptedControlPlane`.
///
/// ## The hazard this exists for
///
/// Two `SMCReadScheduler`s arbitrate nothing while looking exactly like one that does. Each
/// grants turns against a queue the other cannot see, so the safety cycle and the client
/// snapshot contend exactly as they did before #127 — with all the machinery for fixing it
/// present, tested, and bypassed. `HelperComposition` warns about this in a comment; this is
/// the same warning in a form that fails.
@Suite("The helper's composition root")
struct HelperCompositionTests {

    private static func source(of file: String) throws -> String {
        let url = try #require(
            SeamScanner.swiftFiles().first { $0.lastPathComponent == file },
            "\(file) was not found in Sources")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func compositionSource() throws -> String {
        strippingComments(try source(of: "HelperComposition.swift"))
    }

    private static func mainSource() throws -> String {
        strippingComments(try source(of: "AeolusHelperMain.swift"))
    }

    /// **Mutation:** restore the pre-#127 wiring — `snapshotProvider: SMCSensorProvider()`.
    /// Run: red here, and green everywhere else in the repository, which is the whole point
    /// of the file.
    @Test("The snapshot path is given the scheduler's snapshot reader, not a raw provider")
    func theSnapshotPathTakesItsTurnsFromTheScheduler() throws {
        let source = try Self.compositionSource()

        #expect(
            Self.strippingWhitespace(source).contains("snapshotProvider:scheduler.snapshotReader"),
            "the snapshot path no longer takes its turns from the scheduler")
        #expect(
            source.contains("SMCReadScheduler(") && source.contains("SMCSensorProvider()"),
            "the scheduler is no longer the thing holding the real provider")
    }

    /// The control plane every safety mechanism reads and writes through is built from the
    /// **one** scheduler the snapshot takes its turns from.
    ///
    /// This is the hazard `AeolusHelperMain` spent a paragraph warning #103 about, now that
    /// #103 is here: *"the supervisor's control plane must be built from this scheduler and
    /// not from a second one."* `onlyOneSchedulerIsEverBuilt` below catches a second
    /// construction anywhere in `Sources`; this catches the narrower, likelier slip of
    /// building the plane from something other than the local that is already in hand.
    ///
    /// **Mutation:** `SMCFanControlPlane(scheduler: SMCReadScheduler(provider: SMCSensorProvider()))`.
    /// Run: red here, and red in both counting tests below — three failures for one edit,
    /// which is the pair working.
    @Test("The control plane is built from the one scheduler, not a second one")
    func thePlaneIsBuiltFromTheOneScheduler() throws {
        let source = Self.strippingWhitespace(try Self.compositionSource())

        #expect(
            source.contains("SMCFanControlPlane(scheduler:scheduler)"),
            """
            the safety subsystem's plane is no longer built from the scheduler the snapshot \
            shares. Two schedulers arbitrate nothing while looking exactly like one that does.
            """)
    }

    /// The mode read goes through the **same** reader as the fans beside it, at snapshot
    /// priority.
    ///
    /// ## This assertion is deliberately weaker than it was, because the code is stronger
    ///
    /// It used to require the literal `SnapshotFanModeReads(provider: scheduler.snapshotReader)`
    /// in `main()`, because the two reads were wired from two separate expressions and either
    /// could be pointed somewhere else. `HelperComposition.init` now takes **one**
    /// `snapshotProvider` and builds both from it, so "a snapshot assembled from two
    /// connections" is no longer a mistake a caller can make — there is no second argument to
    /// get wrong. What is left to guard is that nobody reintroduces a second source, which is
    /// the count below.
    ///
    /// Wiring it to an `SMCFanControlPlane` instead remains the other hazard, and it is
    /// caught by type: `HelperComposition.init` takes a `SensorProvider`, and a plane is not
    /// one.
    ///
    /// **Mutation:** build a second `SnapshotFanModeReads(provider:)` anywhere in `Sources`.
    /// Run: red.
    @Test("The fan mode is read through the one provider the snapshot was given")
    func theModeReadIsBuiltFromTheSameProviderAsTheFanRead() throws {
        #expect(
            Self.strippingWhitespace(try Self.compositionSource())
                .contains("SnapshotFanModeReads(provider:snapshotProvider)"),
            """
            F<n>Md is no longer read through the provider the fan read was given, so one \
            snapshot is a composite of two sources.
            """)
        #expect(
            try Self.constructionSites(of: "SnapshotFanModeReads(") == ["HelperComposition.swift x1"],
            """
            the snapshot's mode reader is built in exactly one place. A second one is a \
            second view of who owns a fan, and the two will eventually disagree.
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
            sites == ["HelperComposition.swift x1"],
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
    /// live: `HelperComposition` names the type in prose, and a scanner that counted it would
    /// fail on the explanation. `SeamScanner` warns about exactly this.
    ///
    /// **Mutation:** add a second construction anywhere in `Sources/`, wrapped or not,
    /// including `SMCReadScheduler.init(provider:)`. Run: red.
    @Test("Exactly one scheduler is constructed in the whole of Sources")
    func onlyOneSchedulerIsEverBuilt() throws {
        var constructions: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let count =
                Self.occurrences(of: "SMCReadScheduler(", in: code)
                + Self.occurrences(of: "SMCReadScheduler.init(", in: code)
            if count > 0 {
                constructions.append("\(file.lastPathComponent) x\(count)")
            }
        }

        #expect(
            constructions == ["HelperComposition.swift x1"],
            """
            the SMC connection is arbitrated by one scheduler or by none: \(constructions). \
            A second scheduler grants turns against a queue the first cannot see, so the \
            safety cycle and the snapshot contend exactly as they did before #127.
            """)
    }

    /// The Mach service is advertised **after** the safety subsystem is up, and never before.
    ///
    /// #103's decision A1 states the property and the reason in one sentence: *"an advertised
    /// Mach service is a client that can acquire a lease over a fan whose reconciliation
    /// restore is still in flight."* The same window covers the safety registries, which
    /// `HelperComposition.bringUp()` binds to the restorer before anything can restore.
    ///
    /// Three assertions, because a hoist can land in either function. `main()` must contain
    /// no resume at all; `bringUp` must contain exactly one; and inside `bringUp` it must
    /// come after the composition has been brought up.
    ///
    /// **Mutation A:** move `listener.resume()` into `main()`, beside `listener.delegate`.
    /// Run: red on the first two.
    /// **Mutation B:** inside `bringUp`, move `listener.resume()` above `helper.bringUp()`.
    /// Run: red on the third.
    @Test("The Mach service is advertised only after bring-up, as the last statement")
    func theServiceIsAdvertisedOnlyAfterBringUp() throws {
        let code = try Self.mainSource()
        let declaration = try #require(
            code.range(of: "static func bringUp"),
            "AeolusHelperMain no longer has a bring-up function to order the resume against")
        let beforeBringUp = String(code[code.startIndex..<declaration.lowerBound])
        let bringUpBody = String(code[declaration.upperBound...])

        #expect(
            Self.occurrences(of: "listener.resume()", in: beforeBringUp) == 0,
            """
            the Mach service is advertised outside the bring-up function, so a client can \
            connect while the safety registries are unbound and no supervisor is running.
            """)
        #expect(
            Self.occurrences(of: "listener.resume()", in: bringUpBody) == 1,
            "bring-up no longer advertises the service exactly once")

        let brought = try #require(bringUpBody.range(of: "helper.bringUp()"))
        let resumed = try #require(bringUpBody.range(of: "listener.resume()"))
        #expect(
            brought.upperBound < resumed.lowerBound,
            "the service is advertised before the safety subsystem has been brought up")
    }

    /// The listener is handed the supervised authority, not the read-only one.
    ///
    /// The whole of #163 in one assertion. `ReadOnlyFanAuthority` survives as the *read path*
    /// — `SupervisedFanAuthority` composes it, and the lease core enumerates the machine
    /// through it — but a delegate given one directly is a helper whose lease core, § 3 and
    /// § 5 are constructed and unreachable, which is the state this issue exists to end.
    ///
    /// **Mutation:** pass `helper.reading` instead of `helper.authority`. Run: red.
    @Test("The listener is given the supervised authority, not the read-only one")
    func theListenerServesTheSupervisedAuthority() throws {
        let code = Self.strippingWhitespace(try Self.mainSource())

        #expect(
            code.contains("authority:helper.authority"),
            "the listener no longer serves the authority the composition root built")
        #expect(
            try Self.constructionSites(of: "SupervisedFanAuthority(")
                == ["HelperComposition.swift x1"],
            "the helper's authority is composed in exactly one place")
    }

    // MARK: - Scanning

    /// Which files in `Sources` construct `needle`, and how many times each.
    private static func constructionSites(of needle: String) throws -> [String] {
        var sites: [String] = []
        for file in try SeamScanner.swiftFiles() {
            let code = strippingComments(try String(contentsOf: file, encoding: .utf8))
            let count = occurrences(of: needle, in: code)
            if count > 0 { sites.append("\(file.lastPathComponent) x\(count)") }
        }
        return sites
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
