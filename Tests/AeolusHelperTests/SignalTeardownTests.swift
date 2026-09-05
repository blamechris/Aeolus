import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 6's orderly exit path, driven through the **composed** helper.
///
/// Every behavioural test below builds `HelperComposition` — the type `AeolusHelperMain`
/// builds — over a journalling wrapper around `ScriptedControlPlane`, acquires a real lease
/// through the real `LeaseAuthority`, and then invokes the signal handler's body directly.
/// Nothing is paraphrased, for `HelperRestorerTests`' reason: what E5.4d adds is an
/// *ordering* between mechanisms that already exist, and a test that constructed
/// `SignalTeardown` beside the graph rather than out of it would pass while the daemon wired
/// it to a different lease core, or to none.
///
/// ## Why the assertions are on one ordered journal
///
/// The contract is an order, and the end state cannot express one. "Released, then restored"
/// and "restored, then released" both leave an empty lease table and every fan automatic —
/// so an end-state assertion is green for both, which is the mutation surviving. The journal
/// records each restore *with the control gate's state at that instant*, which is how the
/// gate-closes-first claim becomes falsifiable too: a `#expect(gate.isClosed)` taken after
/// the teardown is true whichever order the two ran in.
///
/// ## The exit is a seam, not a process ending
///
/// `TeardownExit.process` really does call `exit`, so a test that let the shipping seam run
/// would end the `swift test` process — reporting success for a run that never finished.
/// `TeardownSeams` exists for that, and the recorder it takes is what puts the exit into the
/// same ordered journal as the restores, so "then exit, in that order" is asserted rather
/// than assumed from a return value.
@Suite("The orderly signal teardown", .timeLimit(.minutes(1)))
struct SignalTeardownTests {

    private static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Teardown")
    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    /// One composed helper over journalled scripted firmware, with fan 0 already in manual.
    ///
    /// The plane is pointed at the gate *after* construction, exactly as
    /// `RegistryObservingPlane` is pointed at the registries: the graph is circular, and the
    /// gate belongs to the authority, which needs the lease core, which needs the restorer,
    /// which needs this plane.
    private static func composed(
        journal: TeardownJournal,
        signals: RecordingSignalSources = RecordingSignalSources(),
        writes: ScriptedControlPlane.WriteBehaviour = .honoured
    ) async -> HelperComposition<JournallingPlane> {
        let plane = JournallingPlane(
            journal: journal,
            wrapping: ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
                stages: [
                    .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                ]))
        let helper = HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog,
            teardown: TeardownSeams(
                sources: signals,
                terminate: { outcome in await journal.record(.exited(outcome)) }))
        await plane.observe(gate: helper.authority.controlGate)
        await helper.bindSafetyRegistries()
        return helper
    }

    /// The supervisor-stop step, recorded into the same journal as everything else.
    ///
    /// The real one is `HelperComposition.shutDown()`, which `bringUp()` passes in. This
    /// stands in for it in the tests that drive `run(stoppingSupervisorsWith:)` directly,
    /// because none of them starts a supervisor — three 1 Hz loops over the same scripted
    /// firmware would move the state these tests assert on, which is `HelperRestorerTests`'
    /// reason for the same choice.
    private static func stopRecorder(
        _ journal: TeardownJournal
    ) -> @Sendable () async -> Void {
        { await journal.record(.supervisorsStopped) }
    }

    private static func acquireLease(
        over fan: Int, in helper: HelperComposition<JournallingPlane>
    ) async throws {
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [fan]), from: ConnectionID())
    }

    // MARK: - The order

    /// Gate, then release, then the machine-wide restore, then the supervisors, then exit.
    ///
    /// A lease is held, so `releaseEveryLease()` has real work: fan 0's own restore is the
    /// `.fan(0)` entry, and the `.everyFan` entry after it is the keystone this path issues
    /// unconditionally. Both carry the gate's state at the write, which is what pins step 1
    /// ahead of step 2.
    ///
    /// **Mutation:** swap the `gate.close()`/`releaseEveryLease()` pair with the
    /// `restoreToAutomatic(.everyFan)` block in
    /// `SignalTeardown.run(stoppingSupervisorsWith:)`. Run: red.
    /// **Mutation:** move `await gate.close()` below `await leases.releaseEveryLease()`.
    /// Run: red — the first restore is recorded with the gate still open.
    /// **Mutation:** move `await stop()` above the restore. Run: red.
    @Test("A signal releases every lease, then restores every fan, then stops, then exits")
    func theTeardownRunsItsStepsInOrder() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)
        try await Self.acquireLease(over: 0, in: helper)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        #expect(
            await journal.events == [
                .restored(.fan(0), gateClosed: true),
                .restored(.everyFan, gateClosed: true),
                .supervisorsStopped,
                .exited(.restored),
            ],
            """
            the teardown's steps did not run in § 6's order. A machine-wide restore issued \
            before the lease table is emptied leaves § 5 watching fans that have just gone \
            automatic; a restore issued before the gate closes can be undone by a lease \
            granted behind it; and an exit before either is a helper that stopped counting \
            a TTL for fans it never handed back.
            """)
        #expect(
            await helper.leases.leaseCount == 0,
            "the teardown left a lease in the table it had already stopped supervising")
    }

    /// The keystone is issued even with nothing to release.
    ///
    /// It is the step that covers what the lease core cannot see: a fan a previous process
    /// left in manual, and a fan engaged by a lease granted in the window the gate does not
    /// close. Both are invisible to `releaseEveryLease()`, which walks the table.
    ///
    /// **Mutation:** guard the restore on `leases.leaseCount > 0`. Run: red.
    @Test("Every fan is restored even when no lease was held")
    func theKeystoneIsIssuedWithNoLeaseHeld() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        #expect(
            await journal.restoreScopes == [.everyFan],
            """
            the machine-wide restore is conditional on something this process knows about, \
            so a fan the previous helper left in manual is never handed back.
            """)
    }

    // MARK: - The exit code

    /// A refused mode write exits non-zero, which is what makes launchd restart the helper.
    ///
    /// Decision A3 pairs this with `KeepAlive = { SuccessfulExit = false }`: `exit(0)` means
    /// *the fans are back*, and nothing else may claim it.
    ///
    /// **Mutation:** replace the `do`/`catch` in `SignalTeardown.run(stoppingSupervisorsWith:)`
    /// with `let outcome = TeardownOutcome.restored` — the `exit(0)`-unconditionally
    /// mutation, at the seam a test can observe. Run: red.
    @Test("A restore the firmware refuses yields a non-zero exit")
    func aFailedRestoreExitsNonZero() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(
            journal: journal, writes: .refused(reason: "the firmware refused the mode write"))

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        #expect(
            await journal.events.last == .exited(.restoreFailed),
            """
            a teardown that could not hand the fans back exited claiming it had. launchd \
            will not restart the helper, and nothing else will clear a fan left in manual.
            """)
        #expect(
            TeardownOutcome.restoreFailed.rawValue != 0,
            "the failure code is zero, so `SuccessfulExit = false` cannot see it")
    }

    /// `exit(0)` is reachable, and it is the code a successful teardown produces.
    ///
    /// Asserted separately from the ordering test because that one would stay green if both
    /// outcomes mapped to zero — it asserts the *outcome*, and this asserts what the shipping
    /// seam does with it. The two halves together are the contract A3 names.
    @Test("The two outcomes carry the two exit codes the restart policy distinguishes")
    func theOutcomesCarryTheirExitCodes() {
        #expect(TeardownOutcome.restored.rawValue == 0)
        #expect(TeardownOutcome.allCases.count == 2, "a third outcome needs a code and a rule")
    }

    // MARK: - The gate

    /// A control verb arriving after the gate closes is refused, and never reaches the core.
    ///
    /// Driven over a real `HelperConnectionSession` — a handshaken one, so the refusal cannot
    /// be the handshake gate doing this test's work. The assertion is on
    /// `leases.leaseCount`, not on the fault alone: `ScriptedControlPlane` answers
    /// `writeCapability == .built`, so an ungated `acquireLease` here really would be
    /// granted, and a gate that refused the client while dispatching anyway returns an
    /// identical refusal.
    ///
    /// **Mutation:** delete the `refuseIfShuttingDown` call from
    /// `SupervisedFanAuthority.acquireLease`. Run: red.
    /// **Mutation:** delete `await gate.close()` from
    /// `SignalTeardown.run(stoppingSupervisorsWith:)`. Run: red.
    @Test("A lease requested after the teardown began is refused and never granted")
    func aControlVerbAfterTheGateClosesIsRefused() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)
        let session = HelperConnectionSession(
            id: ConnectionID(),
            authority: helper.authority,
            helperBuild: "test",
            log: Self.helperLog)
        _ = await session.hello(payload: try helloPayload())

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))
        let reply = await session.acquireLease(payload: try leasePayload())

        #expect(
            reply.fault == AeolusXPCFault.helperFailed(detail: "the helper is shutting down"),
            "the refusal does not say the helper is shutting down")
        #expect(
            await helper.leases.leaseCount == 0,
            """
            a lease was granted after the teardown had already released every lease and \
            restored every fan. Nothing counts its TTL, and no further restore is coming.
            """)
    }

    /// `snapshot` is deliberately **not** gated, and neither is the panic verb.
    ///
    /// Both are exemptions with reasons — see `SupervisedFanAuthority.refuseIfShuttingDown`
    /// — and an exemption nothing pins is one a later edit removes without noticing. A
    /// helper that refused to hand fans back because it was shutting down would be a safety
    /// mechanism defeating safety.
    @Test("Reading and the panic verb still work while the helper is shutting down")
    func theReadPathAndThePanicVerbAreNotGated() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        let snapshot = try await helper.authority.snapshot()
        #expect(!snapshot.fans.isEmpty, "the read path was gated by the teardown")
        try await helper.authority.restoreAllToAutomatic(from: ConnectionID())
    }

    // MARK: - The sources

    /// Bring-up installs the teardown on exactly the three orderly signals.
    ///
    /// `SIGQUIT` is absent on purpose: it is a crash signal by convention, its default
    /// disposition is a core dump, and § 6 gives crash signals no in-process restore at all.
    ///
    /// **Mutation:** delete `await signalTeardown.install(...)` from
    /// `HelperComposition.bringUp()`. Run: red.
    /// **Mutation:** add `SIGQUIT` to `SignalTeardown.served`. Run: red.
    @Test("Bring-up serves SIGTERM, SIGINT and SIGHUP, and nothing else")
    func bringUpInstallsTheOrderlySignals() async throws {
        let journal = TeardownJournal()
        let signals = RecordingSignalSources()
        let helper = await Self.composed(journal: journal, signals: signals)

        await helper.bringUp()
        await helper.shutDown()

        #expect(await signals.served == [SIGTERM, SIGINT, SIGHUP])
        #expect(await signals.isServing, "bring-up installed no handler")
    }

    /// A delivered signal runs the whole body, through the installed handler.
    ///
    /// The tests above call `run(stoppingSupervisorsWith:)` directly, which says nothing
    /// about whether the handler the source was given is wired to it. This is the one that
    /// goes the whole way round.
    ///
    /// **Mutation:** make `install`'s handler body empty. Run: red — the wait times out and
    /// the suite's `.timeLimit` cancels it.
    @Test("A delivered signal runs the teardown body")
    func aDeliveredSignalRunsTheTeardown() async throws {
        let journal = TeardownJournal()
        let signals = RecordingSignalSources()
        let helper = await Self.composed(journal: journal, signals: signals)
        await helper.signalTeardown.install(stoppingSupervisorsWith: Self.stopRecorder(journal))

        await signals.fire()
        try await journal.finished.wait()

        #expect(await journal.restoreScopes == [.everyFan])
        #expect(await journal.events.last == .exited(.restored))
    }

    /// A second signal is dropped rather than served a second time.
    ///
    /// `SIGTERM` followed by `SIGINT` is ordinary for a dying daemon. Two teardowns racing
    /// would issue the keystone write twice and call `exit` twice, and the first one already
    /// restores every fan.
    ///
    /// **Mutation:** delete the `guard !hasBegun` in
    /// `SignalTeardown.run(stoppingSupervisorsWith:)`. Run: red.
    @Test("A second signal does not run the teardown again")
    func aSecondSignalIsIgnored() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))
        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        #expect(
            await journal.events == [
                .restored(.everyFan, gateClosed: true),
                .supervisorsStopped,
                .exited(.restored),
            ],
            "the teardown ran twice, so the process was told to exit twice")
    }

    // MARK: - What must not be in the tree

    /// No crash-signal source, no mach exception port, no `atexit`, anywhere in the helper.
    ///
    /// A source tripwire because there is nothing to observe at runtime: a crash handler is
    /// visible only when the process crashes, and by then the test is the crash. § 6's
    /// ruling is that crash coverage is restart plus reconciliation, uniformly — a handler
    /// calling `IOConnectCallStructMethod` from signal context is undefined behaviour on the
    /// one path it exists to serve.
    ///
    /// `atexit` is here for a **different** reason and the two must not be conflated. It runs
    /// in normal context, so it is not undefined behaviour; it is simply useless for this,
    /// because every step of the teardown is `async` and an `atexit` body is synchronous. The
    /// only bridge is blocking an exiting process on a semaphore. ADR 0007 permitted the belt
    /// when it was written and its amendment records the correction.
    ///
    /// `sigaction` is on the list although the acceptance criteria do not name it: installing
    /// one puts a handler body back into signal context, which is the whole of what § 6's
    /// `SIG_IGN`-plus-`DispatchSourceSignal` shape exists to avoid. It is the same defect
    /// reached by a different call.
    ///
    /// **Mutation:** add a `DispatchSource.makeSignalSource(signal: SIGSEGV, queue: …)` — or
    /// any of the other nine tokens — to a file under `Sources/AeolusHelper`. Run: red.
    @Test("The helper installs no crash handler, no exception port, and no atexit")
    func noCrashHandlingExistsInTheTree() throws {
        let forbidden = [
            "SIGSEGV", "SIGBUS", "SIGILL", "SIGABRT", "SIGFPE",
            "task_set_exception_ports", "thread_set_exception_ports",
            "host_set_exception_ports", "atexit", "sigaction",
        ]

        var found: [String] = []
        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            for token in forbidden where code.contains(token) {
                found.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            found.isEmpty,
            """
            \(found.sorted()). A crash is exactly when heap and lock state are unknown, and \
            `IOConnectCallStructMethod` is not async-signal-safe — docs/SAFETY.md § 6 gives \
            crash signals no in-process restore at all. `atexit` is excluded for its own \
            reason: the restore is `async`, so an `atexit` body could only block an exiting \
            process on a semaphore.
            """)
    }

    /// The orderly path is the only thing in the helper that ends the process, and `exit(0)`
    /// is written exactly once.
    ///
    /// A3 makes the exit code a contract: `SuccessfulExit = false` means launchd reads
    /// `exit(0)` as *the fans are back, do not restart me*. A second `exit(0)` anywhere would
    /// compile, pass every behavioural test here, and quietly tell launchd that about a
    /// helper that restored nothing.
    ///
    /// **Mutation:** add `exit(0)` to any other file under `Sources/AeolusHelper` — or a
    /// second one to `SignalTeardown.swift`. Run: red.
    @Test("The helper ends the process in one place, and exits zero on one path")
    func theOrderlyPathIsTheOnlyExit() throws {
        let call = try NSRegularExpression(pattern: #"(?<![\w.])exit\s*\("#)
        var sites: [String] = []
        var zeroExits = 0

        for file in try SeamScanner.swiftFiles(under: "AeolusHelper") {
            let code = SeamScanner.strippingComments(
                try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            if call.numberOfMatches(in: code, range: range) > 0 {
                sites.append(file.lastPathComponent)
            }
            zeroExits += code.components(separatedBy: "exit(0)").count - 1
        }

        #expect(
            sites == ["SignalTeardown.swift"],
            """
            the helper ends the process somewhere other than the orderly teardown: \
            \(sites.sorted()). Every other exit is a root daemon leaving the fans wherever \
            they were, with launchd told nothing useful about it.
            """)
        #expect(
            zeroExits == 1,
            """
            `exit(0)` is written \(zeroExits) times. It is the one code that means "every \
            fan is back" — decision A3 pairs it with `KeepAlive = { SuccessfulExit = false }` \
            — so a second one is a helper that will not be restarted after failing to \
            restore anything.
            """)
    }
}
