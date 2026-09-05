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
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        restores: JournallingPlane.RestoreBehaviour = .reachTheFirmware
    ) async -> HelperComposition<JournallingPlane> {
        let plane = JournallingPlane(
            journal: journal,
            restores: restores,
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
    /// The keystone appears **twice**: once at step 3 and once at step 5, ruling D19's, after
    /// the supervisors have stopped. Both are in the journal, and their positions either side
    /// of `.supervisorsStopped` are the whole of that ruling.
    ///
    /// **Mutation:** swap the `gate.close()`/`releaseEveryLease()` pair with the first
    /// `keystone()` call in `SignalTeardown.run(stoppingSupervisorsWith:)`. Run: red.
    /// **Mutation:** move `await gate.close()` below `await leases.releaseEveryLease()`.
    /// Run: red — the first restore is recorded with the gate still open.
    /// **Mutation:** move `await stop()` above the first `keystone()`. Run: red.
    /// **Mutation:** delete the first `keystone()` call. Run: red.
    /// **Mutation:** delete the second `keystone()` call. Run: red.
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
                .restored(.everyFan, gateClosed: true),
                .exited(.restored),
            ],
            """
            the teardown's steps did not run in § 6's order. A machine-wide restore issued \
            before the lease table is emptied leaves § 5 watching fans that have just gone \
            automatic; a restore issued before the gate closes can be undone by a lease \
            granted behind it; a keystone issued only before the supervisors stop can be \
            undone by a § 3 or § 5 cycle already in flight; and an exit before any of them \
            is a helper that stopped counting a TTL for fans it never handed back.
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
            await journal.restoreScopes == [.everyFan, .everyFan],
            """
            the machine-wide restore is conditional on something this process knows about, \
            so a fan the previous helper left in manual is never handed back.
            """)
    }

    /// D19's window, closed: a fan put into manual **after** the first keystone is still
    /// automatic when the process exits.
    ///
    /// `stop()` cancels the three supervisors; it does not await a cycle already in flight,
    /// and neither `ThermalSupervisor.stop()` nor `ReclamationSupervisor.stop()` claims
    /// otherwise. So a § 3 fire or a § 5 bounded re-assert that began before step 4 can land
    /// its `engageManualControl` write after step 3 has already run. The stop closure is
    /// exactly that window — it is the last thing the teardown awaits before the write whose
    /// answer launchd reads — so the manual engage is issued from inside it, which is a
    /// stronger placement than a race the test would have to win.
    ///
    /// The assertion is on the firmware's own state rather than on the journal alone: the
    /// point of the ruling is not that a second write was issued, it is that the fan is back.
    ///
    /// **Mutation:** delete the second `keystone()` call from
    /// `SignalTeardown.run(stoppingSupervisorsWith:)` and return the first one's outcome.
    /// Run: red — fan 0 is `.manual` at exit.
    @Test("A fan put into manual while the supervisors are stopping is still handed back")
    func theKeystoneCoversTheWindowAfterTheSupervisorsStop() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)
        let plane = helper.plane
        let fan = try commandableFan(0, declaring: .held(at: 2_400))

        await helper.signalTeardown.run(stoppingSupervisorsWith: {
            await journal.record(.supervisorsStopped)
            // What a § 3 fire or a § 5 re-assert does, at the one moment it can still do it.
            try? await plane.engageManualControl(of: fan)
        })

        #expect(
            try await plane.readControlState(ofFan: 0).mode == .automatic,
            """
            a fan taken off automatic control while the supervisors were stopping was still \
            in manual when the process exited zero. Nothing in this process counts a TTL for \
            it and no further restore is coming.
            """)
        #expect(
            await journal.events.last == .exited(.restored),
            "the exit code was not derived from the write that actually ended the teardown")
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
            TeardownOutcome.restoreFailed.exitCode != 0,
            "the failure code is zero, so `SuccessfulExit = false` cannot see it")
    }

    /// Ruling D15: a build with no write path exits **zero**, and says so by name.
    ///
    /// `JournallingPlane.RestoreBehaviour.refusedAsNotBuilt` throws exactly what
    /// `SMCFanControlPlane.restoreToAutomatic(_:)` throws, from the same place — before any
    /// firmware is touched — which is the shipping helper's behaviour until E3. The refusal
    /// is proof there was nothing to hand back: nothing in this build can put a fan into
    /// manual, because `writeCapability` refuses every lease before a write is reached. A
    /// non-zero exit here would make #165's `SuccessfulExit = false` restart the helper after
    /// every `launchctl bootout` and every app quit on today's build.
    ///
    /// **Mutation:** replace the whole `do`/`catch` in `SignalTeardown.keystone()` with
    /// `return .restored` — "treat every error as success". Run: red
    /// (`aFailedRestoreExitsNonZero`).
    /// **Mutation:** delete the `catch FanControlPlaneError.controlPathNotBuilt` clause —
    /// "treat controlPathNotBuilt as failure". Run: red, here.
    ///
    /// **What no test here can distinguish, said rather than implied.** D15 also rules that
    /// the outcome be sourced from the thrown case *and never from `writeCapability`*, and
    /// that half is a design constraint rather than something this suite falsifies: a plane
    /// that reports `.built` and still throws `.controlPathNotBuilt` is a state no build can
    /// be in, so a capability-sourced implementation would agree with this test and with
    /// `aFailedRestoreExitsNonZero` on every input either can supply. What rules it out is
    /// structural instead — `SignalTeardown` holds a `SafetyActorWriter`, not a plane, so it
    /// has no capability to consult, and giving it one would be the `FanWriteCapability`
    /// literal restored under a new name and carried into the E3 build where `.built` is
    /// true and the same refusal means the firmware said no.
    @Test("A helper with no write path exits zero, because it had nothing to hand back")
    func aBuildWithNoWritePathExitsZeroWithNothingToRestore() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal, restores: .refusedAsNotBuilt)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        #expect(
            await journal.events.last == .exited(.nothingToRestore),
            """
            a helper with no SMC write path exited claiming a restore had failed. Once #165 \
            lands `SuccessfulExit = false`, launchd restarts it after every bootout and \
            every quit, forever, over fans it could never have touched.
            """)
        #expect(
            TeardownOutcome.nothingToRestore.exitCode == 0,
            "`nothingToRestore` is non-zero, so launchd restarts a helper that wrote nothing")
    }

    /// The outcome-to-exit-code mapping, executed.
    ///
    /// This is the whole of A3's launchd contract, and until #197's review it was written
    /// inside `TeardownExit.process` — a closure whose body calls `exit`, so no test could
    /// run it and inverting the switch survived the suite. `TeardownOutcome.exitCode` is a
    /// pure function, so this executes it; what is left in the closure is `exit($0.exitCode)`
    /// with no branch to invert.
    ///
    /// Written over `allCases` rather than as three literals so that a fourth outcome fails
    /// here until somebody decides which side of the contract it is on.
    ///
    /// **Mutation:** make `.restoreFailed` return `0` from `exitCode`. Run: red.
    /// **Mutation:** make `.restored` return `1`. Run: red.
    @Test("Each outcome carries the exit code the restart policy reads")
    func theOutcomesCarryTheExitCodesTheRestartPolicyReads() {
        #expect(
            TeardownOutcome.allCases.filter { $0.exitCode == 0 }
                == [.restored, .nothingToRestore],
            """
            zero means "no fan is off automatic control because of Aeolus", and exactly the \
            two outcomes that can claim it may carry it — decision A3 pairs that code with \
            `KeepAlive = { SuccessfulExit = false }`.
            """)
        #expect(
            TeardownOutcome.allCases.filter { $0.exitCode != 0 } == [.restoreFailed],
            "an outcome that could not hand the fans back exits zero and is never restarted")
        #expect(
            TeardownOutcome.allCases.count == 3, "a fourth outcome needs a code and a rule")
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
    /// **All three** gated verbs are driven, not just `acquireLease`. Until #197's review the
    /// other two calls to `refuseIfShuttingDown` were pinned by nothing: deleting both left
    /// the suite green, and `renewLease` is the one that matters most — it is how a client
    /// keeps holding fans in a process that has stopped counting their TTL.
    ///
    /// `renewLease` is driven against a lease acquired **before** the teardown, so the
    /// refusal cannot be "no such lease" wearing the gate's name.
    ///
    /// **Mutation:** delete the `refuseIfShuttingDown` call from
    /// `SupervisedFanAuthority.acquireLease`. Run: red.
    /// **Mutation:** delete it from `SupervisedFanAuthority.renewLease`. Run: red.
    /// **Mutation:** delete it from `SupervisedFanAuthority.apply`. Run: red.
    /// **Mutation:** delete `await gate.close()` from
    /// `SignalTeardown.run(stoppingSupervisorsWith:)`. Run: red.
    @Test("Every gated control verb is refused once the teardown has begun")
    func aControlVerbAfterTheGateClosesIsRefused() async throws {
        let journal = TeardownJournal()
        let helper = await Self.composed(journal: journal)
        let session = HelperConnectionSession(
            id: ConnectionID(),
            authority: helper.authority,
            helperBuild: "test",
            log: Self.helperLog)
        _ = await session.hello(payload: try helloPayload())
        let granted = try #require(
            await session.acquireLease(payload: try leasePayload()).payloadData)
        let lease = try AeolusXPCCoding.decoder().decode(Lease.self, from: granted)

        await helper.signalTeardown.run(stoppingSupervisorsWith: Self.stopRecorder(journal))

        let acquired = await session.acquireLease(payload: try leasePayload())
        let renewed = await session.renewLease(id: lease.id.uuidString)
        let applied = await session.apply(
            settings: try Self.settingsPayload(), leaseID: lease.id.uuidString)

        #expect(
            acquired.fault == Self.shuttingDown, "acquireLease was not refused by the gate")
        #expect(
            renewed.fault == Self.shuttingDown,
            """
            `renewLease` is not gated by the teardown. A renewal arriving in the window \
            between the gate closing and the table emptying is granted, and one arriving \
            after it is told the lease is unknown — which blames the client for the helper's \
            shutdown, and is `CLAUDE.md` rule 6 with the fault text as the claim.
            """)
        #expect(applied.fault == Self.shuttingDown, "apply was not refused by the gate")
        #expect(
            await helper.leases.leaseCount == 0,
            """
            a lease was granted after the teardown had already released every lease and \
            restored every fan. Nothing counts its TTL, and no further restore is coming.
            """)
    }

    /// The refusal every gated verb gives once the teardown has begun.
    private static let shuttingDown = AeolusXPCFault.helperFailed(
        detail: "the helper is shutting down")

    /// A well-formed `apply` payload. Its content is irrelevant: the gate is in front of the
    /// write, so nothing here is ever reached.
    private static func settingsPayload() throws -> Data {
        try AeolusXPCCoding.encoder().encode(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))])
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

        #expect(await journal.restoreScopes == [.everyFan, .everyFan])
        #expect(await journal.events.last == .exited(.restored))
    }

    /// The stop closure `bringUp()` supplies is the real one, and it really stops all three.
    ///
    /// Every other test here passes `stopRecorder(_:)` for the reason that function states —
    /// three 1 Hz loops over the same scripted firmware would move the state those tests
    /// assert on. That leaves the *production* closure, `{ await shutDown() }`, driven by
    /// nothing: `bringUp()` could have installed a teardown that stopped nothing and this
    /// suite would not have noticed. This is the one test that starts the supervisors, fires
    /// a signal at the composed helper, and looks at what is left running.
    ///
    /// **Mutation:** replace `bringUp()`'s
    /// `install(stoppingSupervisorsWith: { await shutDown() })` with
    /// `install(stoppingSupervisorsWith: {})`. Run: red.
    /// **Mutation:** delete `await leaseExpirySupervisor.stop()` from
    /// `HelperComposition.shutDown()`. Run: red.
    @Test("A signal after a real bring-up leaves all three supervisors stopped")
    func aDeliveredSignalStopsTheSupervisorsBringUpStarted() async throws {
        let journal = TeardownJournal()
        let signals = RecordingSignalSources()
        let helper = await Self.composed(journal: journal, signals: signals)

        await helper.bringUp()
        await signals.fire()
        try await journal.finished.wait()

        #expect(await helper.thermalSupervisor.isRunning == false, "§ 3 outlived the teardown")
        #expect(await helper.reclamationSupervisor.isRunning == false, "§ 5 outlived it")
        #expect(await helper.leaseExpirySupervisor.isRunning == false, "§ 1's TTL loop did")
        // `contains` rather than `last`: three real supervisor loops are running underneath
        // this one, and a cycle already in flight may still append to the journal after the
        // exit is recorded. What is being asserted is the teardown's, not the loops'.
        #expect(
            await journal.events.contains(.exited(.restored)),
            "the teardown installed by bring-up did not reach its exit")
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
                .restored(.everyFan, gateClosed: true),
                .exited(.restored),
            ],
            "the teardown ran twice, so the process was told to exit twice")
    }
}
