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

        // Bound to a `Bool` before the expectation, here and below. `#expect` prints its
        // operands, so passing the `contains` call directly dumps the whole scanned file
        // into the failure — which buries the message that says what broke.
        let readsThroughTheScheduler = Self.strippingWhitespace(source)
            .contains("snapshotProvider:scheduler.snapshotReader")
        #expect(
            readsThroughTheScheduler,
            "the snapshot path no longer takes its turns from the scheduler")

        let schedulerHoldsTheProvider =
            source.contains("SMCReadScheduler(") && source.contains("SMCSensorProvider()")
        #expect(
            schedulerHoldsTheProvider,
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
    /// **Mutation:** build the plane from
    /// `SMCReadScheduler(provider: SMCSensorProvider())` instead of from `scheduler`.
    /// Run: red here, and red in both counting tests below — three failures for one edit,
    /// which is the pair working.
    @Test("The control plane is built from the one scheduler, not a second one")
    func thePlaneIsBuiltFromTheOneScheduler() throws {
        let source = Self.strippingWhitespace(try Self.compositionSource())
        let builtFromTheOneScheduler = source.contains("SMCFanControlPlane(scheduler:scheduler)")

        #expect(
            builtFromTheOneScheduler,
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
    /// **Mutation (the second assertion):** build a second `SnapshotFanModeReads(provider:)`
    /// anywhere in `Sources`. Run: red.
    ///
    /// **Mutation (the first assertion):** in `HelperComposition.init`, build the mode reader
    /// from a fresh provider — `SnapshotFanModeReads(provider: SMCSensorProvider())`. Run:
    /// red here on the first assertion, with the construction count still exactly one, and
    /// red in `nothingInTheHelperReadsAroundTheGate`. Two failures for one edit is the pair
    /// working rather than a duplicate: the assertions fail on different edits — the first on
    /// a mode reader pointed elsewhere, the second on one built twice — and an earlier review
    /// was right that the first had no mutation of its own named against it.
    @Test("The fan mode is read through the one provider the snapshot was given")
    func theModeReadIsBuiltFromTheSameProviderAsTheFanRead() throws {
        let readsThroughTheOneProvider = Self.strippingWhitespace(try Self.compositionSource())
            .contains("SnapshotFanModeReads(provider:snapshotProvider)")
        #expect(
            readsThroughTheOneProvider,
            """
            F<n>Md is no longer read through the provider the fan read was given, so one \
            snapshot is a composite of two sources.
            """)
        #expect(
            try Self.constructionSites(of: "SnapshotFanModeReads(") == [
                "HelperComposition.swift x1"
            ],
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

    /// **One** sighting cache, handed to both the grant path and § 3's cycle.
    ///
    /// [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md)'s mechanism is a cache
    /// the cycle **writes** and the lease core **reads**. Two of them is the same hazard shape
    /// as two `SMCReadScheduler`s and is quieter: the lease core would prove sightedness from
    /// a cache no cycle ever wrote, so every `acquireLease` would read the SMC for itself and
    /// [#134](https://github.com/blamechris/Aeolus/issues/134)'s storm would be back — with
    /// the coalescing machinery present, tested and bypassed. Nothing at runtime can see it:
    /// each cache behaves correctly in isolation, `GrantStormTests` composes its own graph,
    /// and every unit test in `CriticalTemperatureCacheTests` builds exactly one.
    ///
    /// Four assertions, because "one is constructed" and "that one reaches both consumers"
    /// are different edits away from each other. The construction count catches a second
    /// `CriticalTemperatureCache(` anywhere in `Sources`; the two hand-off assertions catch a
    /// consumer pointed at a fresh one inline, which keeps the count at one.
    ///
    /// The fourth is one layer down and was missing until an adversarial review ran the
    /// mutation. `HelperComposition.telemetry` claims the grant path reads *"through this same
    /// instance, memo and all"* — the sharing `CuratedCriticalTemperatures` says its
    /// `DegradationMemo` collapse depends on. Giving the cache its own
    /// `CuratedCriticalTemperatures(plane: plane, set: criticalSensors, log: safetyLog)` keeps
    /// one cache, satisfies both hand-off assertions, and leaves the whole suite green — while
    /// § 3 and the grant path each log the same partial sensor loss on their own schedule,
    /// which is the defect this composition was written to end.
    ///
    /// The types make the *last* mistake impossible rather than merely detectable: passing
    /// `telemetry` where `sightings` belongs does not compile, because
    /// `CuratedCriticalTemperatures` is no `SightednessProving`, and the cycle cannot read from
    /// the cache it writes to because `CriticalTemperatureRecording` has no `sighting()` — see
    /// both protocols.
    ///
    /// **Mutation A:** construct a second cache — give `ThermalEmergency`
    /// `sightings: CriticalTemperatureCache(source: telemetry)` inline. Run: red on the count
    /// and on the emergency's hand-off.
    /// **Mutation B:** pass the emergency a fresh cache while deleting the shared local. Run:
    /// red on the hand-off assertions.
    /// **Mutation C:** give the cache a second `CuratedCriticalTemperatures` of its own. Run:
    /// red on the curated count, and green on everything else in the repository.
    @Test("Exactly one sighting cache is constructed, and both consumers are given it")
    func onlyOneSightingCacheIsEverBuilt() throws {
        #expect(
            try Self.constructionSites(of: "CriticalTemperatureCache(")
                == ["HelperComposition.swift x1"],
            """
            § 3's reading is cached in one place or in none. A second cache is a grant path \
            proving sightedness from a reading no cycle ever wrote, which is #134's storm \
            with the mechanism present and bypassed.
            """)

        #expect(
            try Self.constructionSites(of: "CuratedCriticalTemperatures(")
                == ["HelperComposition.swift x1"],
            """
            the curated critical set is built in one place or in none. A second one is a \
            second DegradationMemo, so § 3 and the grant path each log the same partial \
            sensor loss on their own schedule — the collapse HelperComposition.telemetry \
            claims, one level below where the cache count can see it.
            """)

        // Bound to `Bool`s before the expectations, for this file's usual reason: `#expect`
        // prints its operands, and passing the `contains` call directly dumps the whole
        // composition root into the failure.
        let source = Self.strippingWhitespace(try Self.compositionSource())
        let leaseCoreProvesFromTheCache = source.contains("telemetry:sightings")
        let cycleRecordsIntoTheCache = source.contains("sightings:sightings")
        #expect(
            leaseCoreProvesFromTheCache,
            "the lease core no longer proves sightedness from the cache § 3 writes")
        #expect(
            cycleRecordsIntoTheCache,
            "§ 3's cycle no longer records into the cache the lease core reads")
    }

    /// The Mach service is advertised **after** the safety subsystem is up, and never before.
    ///
    /// #103's decision A1 states the property and the reason in one sentence: *"an advertised
    /// Mach service is a client that can acquire a lease over a fan whose reconciliation
    /// restore is still in flight."* The same window covers the safety registries, which
    /// `HelperComposition.bringUp()` binds to the restorer before anything can restore.
    ///
    /// Three assertions, because a hoist can land in either function. `main()` must contain
    /// no resume at all; `bringUp` must contain exactly one; and inside `bringUp` nothing may
    /// follow it.
    ///
    /// ## Two halves, because "last statement" is only half the contract
    ///
    /// The first version of this test asserted that `listener.resume()` came after
    /// `helper.bringUp()` in the text, and mutation B below survived it: `helper.bringUp()`
    /// sits inside the `Task { … }` that *starts* the asynchronous half, so it is textually
    /// above the `broughtUp.wait()` that makes it *complete*. Hoisting the resume above the
    /// wait therefore left it after the call, and the suite stayed green while the daemon
    /// advertised its Mach service with the safety registries unbound.
    ///
    /// The second version fixed that by asserting the resume is the **last** statement in
    /// the body, and a later review found that hole too: nothing follows the resume in a
    /// `bringUp` whose `broughtUp.wait()` has simply been **deleted**, so mutation C left the
    /// whole suite green while producing decision A1's exact failure — a Mach service
    /// advertised over a graph still being bound.
    ///
    /// So the contract is asserted in two parts, and both are needed:
    ///
    /// - **Nothing follows the resume** — it is the last statement in the body. This is
    ///   about what may run *after* the service is advertised.
    /// - **A completion barrier separates the spawn from the resume** — after the `Task`
    ///   block closes there is exactly one `.wait()`, and the semaphore it waits on starts
    ///   at zero. This is about what must have *finished* before it.
    ///
    /// The second names a spelling, and that is deliberate rather than brittle: this
    /// function's whole job is to convert an asynchronous bring-up into a synchronous
    /// precondition, and there are two ways to spell that — block on it, or `await` it. A
    /// restructuring that leaves neither has removed the precondition, so a test that fails
    /// on it is the test working. Whichever of #164 to #168 restructures this owes the
    /// barrier a new name here, in one line, in a test whose failure message says so.
    ///
    /// **Mutation A:** move `listener.resume()` into `main()`, beside `listener.delegate`.
    /// Run: red on the first two.
    /// **Mutation B:** inside `bringUp`, move `listener.resume()` above `broughtUp.wait()`.
    /// Run: red on the last-statement assertion.
    /// **Mutation C:** delete `broughtUp.wait()` entirely. Run: red on the barrier.
    /// **Mutation D:** `DispatchSemaphore(value: 0)` becomes `value: 1`. Run: red on the
    /// initial value — and green on everything else here, which is why it needs its own.
    @Test("The Mach service is advertised only after bring-up, as the last statement")
    func theServiceIsAdvertisedOnlyAfterBringUp() throws {
        let code = try Self.mainSource()
        let bringUpBody = try #require(
            Self.body(ofFunctionMatching: "static func bringUp", in: code),
            "AeolusHelperMain no longer has a bring-up function to order the resume against")
        let elsewhere =
            Self.occurrences(of: "listener.resume()", in: code)
            - Self.occurrences(of: "listener.resume()", in: bringUpBody)

        #expect(
            elsewhere == 0,
            """
            the Mach service is advertised outside the bring-up function, so a client can \
            connect while the safety registries are unbound and no supervisor is running.
            """)
        #expect(
            Self.occurrences(of: "listener.resume()", in: bringUpBody) == 1,
            "bring-up no longer advertises the service exactly once")

        // Everything after the resume, inside the body. Bound to a `Bool` before the
        // expectation so a failure names the rule rather than printing the function.
        let trailing = bringUpBody.range(of: "listener.resume()").map {
            bringUpBody[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(
            trailing?.isEmpty == true,
            """
            something runs after the Mach service is advertised. Whatever it is, a client \
            can now be answered before it has happened — which is the whole of decision A1.
            """)

        // The completion edge. Everything above is about statement *order*, and order alone
        // cannot express "the bring-up finished" once its asynchronous half runs in a `Task`
        // the enclosing function does not await.
        #expect(
            Self.occurrences(of: "Task {", in: bringUpBody) == 1,
            "bring-up no longer spawns exactly one asynchronous half")
        let spawned = try #require(
            Self.body(ofFunctionMatching: "Task", in: bringUpBody),
            "the bring-up Task's body could not be brace-matched")
        let afterTheSpawn = try #require(
            bringUpBody.range(of: spawned).map { String(bringUpBody[$0.upperBound...]) },
            "the bring-up Task's body is not a substring of the function it was taken from")

        #expect(
            Self.occurrences(of: ".wait()", in: afterTheSpawn) == 1,
            """
            nothing between the bring-up Task and the resume waits for it to finish, so the \
            Mach service is advertised while the safety registries are still being bound. \
            That is decision A1's failure reached by deleting a line rather than by moving \
            one, and the last-statement rule above cannot see it. An awaited restructuring \
            is welcome and owes this assertion a new name.
            """)

        // The barrier's *initial value*, which the statement above cannot see. A semaphore
        // constructed at 1 is already signalled, so its `wait()` returns without waiting and
        // the spawned bring-up races the resume it exists to gate — mutation C's failure
        // reached without deleting anything, and every assertion above stays green.
        #expect(
            bringUpBody.contains("DispatchSemaphore(value: 0)"),
            """
            the bring-up barrier does not start closed, so its wait returns at once and the \
            Mach service is advertised over registries that are still being bound.
            """)
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
        let servesTheComposedAuthority = code.contains("authority:helper.authority")

        #expect(
            servesTheComposedAuthority,
            "the listener no longer serves the authority the composition root built")
        #expect(
            try Self.constructionSites(of: "SupervisedFanAuthority(")
                == ["HelperComposition.swift x1"],
            "the helper's authority is composed in exactly one place")
    }

    // MARK: - Scanning

    /// The body of the first function whose declaration matches `marker`, by brace matching.
    ///
    /// Brace matching rather than "from here to the end of the file", so the assertion above
    /// means "nothing follows the resume **in this function**" rather than "`bringUp` happens
    /// to be the last thing in the file" — a coupling that would turn green into red the day
    /// somebody adds a method after it, which is a tripwire nobody keeps.
    ///
    /// Line comments are already stripped by the callers, and this target has no string
    /// literal containing a brace, so a plain depth count is sufficient here. It is not a
    /// general Swift parser and is not claimed to be.
    private static func body(ofFunctionMatching marker: String, in code: String) -> String? {
        guard let declaration = code.range(of: marker),
            let open = code[declaration.upperBound...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[code.index(after: open)..<index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The **shipped** graph is the one that can hear a sleep.
    ///
    /// `powerObserver` is optional, because most tests compose this graph to drive something
    /// else and the production conformer registers with the real power management root the
    /// moment it is asked to observe. The cost of that convenience is that the single line
    /// giving the daemon a § 4 at all — `powerObserver: IOKitSystemPowerObserver()` inside
    /// `production(log:)` — was guarded by nothing: deleting it left the whole suite green,
    /// twice measured, and `observeSystemPower()`'s `nil` branch then returned in silence. § 4
    /// could vanish from every shipped helper and be invisible in CI *and* in `log show`. (The
    /// silence is fixed too — `SystemPowerTests.aMissingPowerObserverIsAFaultRatherThanASilentReturn`
    /// — but a fault line at runtime is not a failing test, and this is the failing test.)
    ///
    /// **Behavioural rather than a source tripwire, unlike the rest of this suite**, and the
    /// reason is the one the suite header gives for preferring one where it can: there is
    /// something to observe. `production(log:)` only *constructs* — no `open()`, no read, no
    /// registration — so a test may build it, look at what it holds and throw it away, on a
    /// machine with no SMC. `observe(_:)` is what touches IOKit, and nothing here calls it.
    ///
    /// **Mutation:** delete `powerObserver: IOKitSystemPowerObserver(),` from
    /// `HelperComposition.production(log:)`. Run: red.
    @Test("The shipped daemon's graph carries a real power observer")
    func theProductionGraphIsGivenASystemPowerObserver() {
        let observer = HelperComposition.production(log: Self.silentLog).powerObserver
        let held = observer.map { String(describing: type(of: $0)) } ?? "nothing at all"

        #expect(
            observer is IOKitSystemPowerObserver,
            """
            the shipped helper's power observer is \(held). Nothing registers for \
            kIOMessageSystemWillSleep, so no fan is handed back before this machine sleeps \
            and § 1's TTL — whose clock may not advance across a sleep — is the only path \
            back. docs/SAFETY.md § 4.
            """)
    }

    /// Its own logger, so building the production graph in a test does not write into the
    /// daemon's subsystem. Nothing here emits — the construction is inert — but a shared
    /// subsystem between a test and a root daemon is worth not having by accident.
    private static let silentLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Composition")

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
