import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The read-only authority against the real SMC.
///
/// Gated on `HardwareIdentity.current()` matching this project's sole verified machine and
/// not merely on `SMCConnection.isHardwareAvailable()`, which is true of every Mac
/// including a fanless Air. The assertions below are facts about `Mac16,5` — that it has
/// fans at all, that it exposes sensor keys — so on any other machine they would fail
/// honestly rather than because something is broken. CI has no SMC and skips the lot.
/// `.serialized` because these tests contend for one piece of hardware. Run in parallel,
/// three concurrent `readAll()` enumerations against the same SMC turned a 5.9 s cold
/// discovery into 24.9 s and a 0.35 s warm snapshot into 0.89 s — measured, not guessed.
/// A timing assertion whose number depends on what else the suite happens to be doing is
/// not a measurement.
@Suite(
    "The helper's read path, real hardware",
    .serialized,
    .enabled(
        if: SMCConnection.isHardwareAvailable()
            && HardwareIdentity.current().modelIdentifier == "Mac16,5")
)
struct HelperHardwareTests {

    private static let log = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Hardware")

    /// A foreign tool holding a fan in manual is a legitimate state of this development
    /// machine, not a regression in it. Macs Fan Control was observed holding both fans on
    /// 2026-09-05 (`docs/SMC-RESEARCH.md` § "`F0Md`/`F1Md` have now been observed reading
    /// `1`"), releasing them again within the hour while still running. `#expect(fan.mode ==
    /// .automatic)` conflated two different claims: "controllable by nothing" is a fact about
    /// `manualControlAvailability`, which this build's write path makes true regardless of
    /// what else is running; "the firmware reports automatic" is a fact about the machine's
    /// *current* state, which depends on what else is running. This test reports the helper,
    /// not whatever the reviewer's desktop happened to be doing.
    @Test(
        "A snapshot from real hardware reports real fans in whatever mode the firmware declares, controllable by nothing"
    )
    func snapshotFromRealHardware() async throws {
        // One provider, read through twice: the fans and the mode key must come from the
        // same source, or a snapshot is one instant's report assembled from two.
        let provider = SMCSensorProvider()
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger())

        let snapshot = try await authority.snapshot()

        #expect(!snapshot.fans.isEmpty)
        #expect(!snapshot.sensors.isEmpty)
        #expect(snapshot.activeLease == nil)
        #expect(snapshot.isThermalEmergencyActive == false)
        for fan in snapshot.fans {
            // `F<n>Md` on this machine legitimately declares either `.automatic` (nothing
            // is holding the fan) or `.manualFixed` (something is) — see
            // `ReadOnlyFanReport.controlMode(_:)` — and which one this run observes is a
            // fact about the machine, not about this build. Printed rather than pinned to
            // one value, for the same reason `everyFanIsOnAutomaticControlAtStart` pins it
            // deliberately: that test is the executable checklist row that wants `0`
            // specifically; this one is not.
            print(
                "fan \(fan.index) reads .\(fan.mode.rawValue) "
                    + "(F\(fan.index)Md == \(fan.mode == .manualFixed ? 1 : 0))")
            // Still not a tautology: this excludes `.manualCurve`, which nothing outside
            // Aeolus can produce and which this build grants no lease to reach, so any
            // fan reporting one would mean a lease was live in a build with no write path.
            // It does not separately exclude "the mode key was unreadable" as a third wrong
            // answer, because `controlMode(_:)` folds a `nil` read into `.automatic` as a
            // documented compromise (#178) rather than a distinct case — there is no third
            // representation here to pin against, and this test cannot see that gap either.
            #expect(fan.mode == .automatic || fan.mode == .manualFixed)
            #expect(fan.targetRPM == nil)
            #expect(fan.manualControlAvailability == .unavailable(.writePathNotBuilt))
        }
        // Deliberately no assertion comparing `actualRPM` against `minimumRPM`: `F0Ac` was
        // measured at 1343.07 against a declared `F0Mn` of 1350 on this machine, so a
        // reading below the declared minimum is a legitimate observation and a test
        // encoding the opposite would be wrong about real hardware.

        // The rule, checked against the hardware that would otherwise tempt someone to
        // decorate: the root daemon attaches no labels, ever.
        for sensor in snapshot.sensors {
            #expect(sensor.label == nil)
            #expect(sensor.labelConfidence == nil)
        }
    }

    /// ADR 0006 makes the helper the machine's only continuous SMC reader whenever the
    /// app is running, which puts `snapshot` on a 1 Hz path. The first snapshot pays for
    /// discovery; every one after it must be a subset read.
    ///
    /// ## What this measured, which is not what the ADR assumed
    ///
    /// On `Mac16,5` / macOS 26.5.2, serialised: this machine exposes **2929** readable
    /// sensor keys. The first snapshot costs 2.2 s against a warm SMC key cache and 5.9 s
    /// against a cold one; a warm snapshot costs **~0.5 s**. Discovery is off the hot path
    /// as designed — a 4x to 11x difference — but **half a second is not "cheap at 1 Hz"**:
    /// it is half the interval spent in a root daemon reading firmware, plus a 2929-sample
    /// payload crossing the boundary every second. ADR 0006's "snapshot cost at 1 Hz is
    /// accepted" was written without a measurement to hand, and this is the measurement.
    /// The remedy that ADR already names is an additive subset-request capability within
    /// v1, never a second continuous reader. Recorded here rather than fixed here: #72
    /// builds the helper side, and the app-side client that would ask for a subset is not
    /// in it.
    ///
    /// The payload is measured here too, because the byte count arguably decides whether the
    /// subset-request capability is required more clearly than the half-second does:
    /// **~138 KB** of JSON for 2929 samples, so roughly 138 KB/s crossing the boundary at
    /// 1 Hz. Six runs on this machine have landed between 137,750 and 138,402 bytes, the last
    /// digits moving with how many significant figures the readings themselves print to.
    /// Treat that as provenance, not a bound: a narrower range was quoted here until a run
    /// fell below it. Printed rather than asserted, for the same reason the sensor count is:
    /// a figure that drifts with the machine is a measurement, not a budget.
    ///
    /// ## What the two-second threshold actually buys, stated honestly
    ///
    /// It is a **coarse regression tripwire, and on its own it did not kill the mutation it
    /// was written for** — which is why the assertion that carries this test's name is now
    /// the *count* below, and the clock is kept only as a tripwire that says so. Measured on
    /// this machine, a warm snapshot costs **roughly half a second** — six runs have ranged
    /// from 0.48 s to 0.60 s — so two seconds is only about **3x to 4x** it, not the order of
    /// magnitude an earlier version of this comment claimed.
    ///
    /// The mutation it names — `readAll()` back on every snapshot, reproduced by making
    /// `readSensors()` ignore its cached key set — **survived the clock**. Three runs put
    /// `warmest` at 1.216 s to 1.221 s, well inside the threshold, and `warmest < cold` held
    /// too, because the mutant's first snapshot still pays discovery on top of the re-read.
    /// The **2.46 s** figure once quoted here as the mutant's cost is the mutant's *first*
    /// snapshot, which includes discovery; the assertion is on `warmest`, so that number was
    /// never the one the threshold is compared against. The underlying reason a warm mutant
    /// is cheap: by the second snapshot `SMCConnection`'s per-key metadata cache is fully
    /// populated, so re-running the enumeration costs about half what the first one did.
    ///
    /// ## What kills it: counting the walks, per
    /// [#97](https://github.com/blamechris/Aeolus/issues/97)
    ///
    /// `ReadAllCountingProvider` wraps the real `SMCSensorProvider` and counts, so "discovery
    /// is off the snapshot path" is asserted as the structural fact it is —
    /// `readAllCount == 1` across a cold snapshot and three warm ones — rather than inferred
    /// from a duration. That assertion cannot be satisfied by a fast machine and cannot be
    /// broken by a loaded one, which is the failure mode every measured figure in this suite
    /// has. The mutation above turns it red at the first warm snapshot.
    ///
    /// The two assertions are kept apart on purpose: the count says discovery did not come
    /// back, and the clock says the snapshot is still fast enough for the 1 Hz path ADR 0006
    /// puts it on. Neither answers the other's question.
    ///
    /// The threshold is still **not** to be loosened, since raising it toward the cold cost
    /// gives up what little it does catch. If it ever goes flaky, the finding is that the
    /// snapshot got slower — or that the machine was busy, which on a shared development
    /// machine is worth confirming before anything else.
    @Test("Discovery stays off the snapshot path")
    func warmSnapshotIsCheap() async throws {
        let provider = ReadAllCountingProvider(wrapping: SMCSensorProvider())
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger())

        let coldStart = ContinuousClock.now
        let first = try await authority.snapshot()
        let cold = ContinuousClock.now - coldStart

        var warmest = Duration.zero
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let snapshot = try await authority.snapshot()
            warmest = max(warmest, ContinuousClock.now - started)
            #expect(!snapshot.fans.isEmpty)
        }

        let encoded = try AeolusXPCCoding.encoder().encode(first)

        print(
            """
            snapshot cost on \(HardwareIdentity.current().modelIdentifier ?? "unknown"): \
            \(first.sensors.count) sensors; first (with discovery) \(cold); \
            warmest of three subsequent \(warmest); \
            \(await provider.readAllCount) full walk(s) and \
            \(await provider.subsetReadCount) subset reads across four snapshots; \
            encoded payload \(encoded.count) bytes, which is the per-tick wire cost at 1 Hz
            """
        )
        // The assertion this test is named for, and the only one here a busy machine cannot
        // move: four snapshots, one index-table walk.
        #expect(
            await provider.readAllCount == 1,
            "a warm snapshot walked the index table again — discovery is back on the hot path")
        #expect(warmest < .seconds(2))
        #expect(warmest < cold, "discovery is supposed to be the expensive one")
    }

    /// [#127](https://github.com/blamechris/Aeolus/issues/127), measured on the one machine
    /// that can measure it.
    ///
    /// `SMCReadSchedulerTests` proves the *ordering* against a scripted double, where every
    /// turn costs nothing and no firmware is involved. This measures the one thing a double
    /// cannot: **what the safety cycle actually waits when a real 2929-key refresh is on the
    /// connection**, in milliseconds, against real firmware.
    ///
    /// ## What it does not prove, said plainly
    ///
    /// It is **not** a test of the composition root, and an earlier version of this comment
    /// claimed it was — "exactly what `AeolusHelperMain` builds". `AeolusHelperMain` builds
    /// no `SMCFanControlPlane` at all in this build, which the comment beside the scheduler
    /// there says in as many words; two comments from one change asserted opposite things
    /// about the same file. This test constructs its own three objects and never reaches
    /// `main()`. `HelperCompositionTests` is what guards the wiring, at the source, because
    /// `main()` ends in `dispatchMain()` and has no seam to drive.
    ///
    /// It is also **not** the guard on the starvation quota. The loop below awaits each
    /// cycle before issuing the next, so at most one supervisor read is ever queued; a lone
    /// supervisor turn ending leaves `supervisorWaiters` empty, which resets
    /// `consecutiveOvertakes`, so the quota never fires. Deleting
    /// `maxConsecutiveOvertakes` entirely leaves this test passing with the same numbers —
    /// measured, not supposed. `SMCReadSchedulerTests.snapshotStarvationIsBounded` is the
    /// test that catches that; this one would tell you nothing.
    ///
    /// ## The load, as it actually is
    ///
    /// One cycle in flight at a time, re-issued immediately: 49 cycles against an ~898 ms
    /// snapshot, so **~55 Hz** — well above § 3's 1 Hz, and nowhere near the ~87 Hz that
    /// would spend the quota at every boundary. Read the printed snapshot cost as
    /// one-overtake-per-boundary, never as the ceiling the bound permits.
    ///
    /// ## The assertion
    ///
    /// A *ratio*, never a millisecond count.
    /// [#118](https://github.com/blamechris/Aeolus/issues/118) is what a hardware test with
    /// an absolute tolerance turns into. A cycle that queued behind the snapshot would cost
    /// about what the snapshot costs; a quarter of it is far outside anything scheduling
    /// noise produces and far inside the failure being guarded against.
    ///
    /// The deadline on the loop is worth keeping but not for the reason first given here: a
    /// single serial issuer cannot starve the snapshot at all, so "the snapshot would never
    /// finish" is not a state this test can reach. What the deadline actually buys is that a
    /// *deadlocked* scheduler — a turn taken and not given back, the failure
    /// `aThrowingReadReleasesItsTurn` covers — is reported as a failed expectation rather
    /// than as a killed job.
    @Test("A safety cycle stays prompt while a real snapshot is on the connection")
    func theSafetyCycleStaysPromptDuringARealSnapshot() async throws {
        // The one connection, named here for the reason `HelperComposition.production(log:)`
        // names one: the provider reads through it and the plane recycles it, and a second
        // one would make this fixture disagree with the daemon's wiring. Nothing below
        // reconnects — this test is about contention — but the shape is the shipped shape.
        let connection = SMCConnection()
        let scheduler = SMCReadScheduler(provider: SMCSensorProvider(connection: connection))
        let authority = ReadOnlyFanAuthority(
            provider: scheduler.snapshotReader,
            fanMode: SnapshotFanModeReads(provider: scheduler.snapshotReader), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger())
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: connection)
        let critical = CriticalSensorSet.resolve(for: HardwareIdentity.current())
        try #require(!critical.isEmpty, "no curated critical set on the machine it was cut for")

        // Pay discovery first: the contention this issue is about is with the *warm*
        // refresh, which is what runs every tick.
        _ = try await authority.snapshot()

        let soloStarted = ContinuousClock.now
        _ = try await plane.readCriticalTemperatures(critical.keys)
        let solo = ContinuousClock.now - soloStarted

        let discoveryDone = CompletionFlag()
        let snapshotStarted = ContinuousClock.now
        let snapshot = Task {
            let taken = try await authority.snapshot()
            await discoveryDone.mark()
            return taken
        }

        var worst = Duration.zero
        var cycles = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while await !discoveryDone.isSet, ContinuousClock.now < deadline {
            let started = ContinuousClock.now
            _ = try await plane.readCriticalTemperatures(critical.keys)
            worst = max(worst, ContinuousClock.now - started)
            cycles += 1
        }
        let contendedSnapshot = ContinuousClock.now - snapshotStarted

        #expect(
            await discoveryDone.isSet,
            "the snapshot never completed under supervisor load; starvation is unbounded")
        let taken = try await snapshot.value

        print(
            """
            supervisor read latency on \(HardwareIdentity.current().modelIdentifier ?? "?"): \
            \(critical.keys.count) curated keys cost \(solo) uncontended; \
            worst of \(cycles) cycles issued against an in-flight \(taken.sensors.count)-key \
            snapshot was \(worst); that snapshot took \(contendedSnapshot) under the load
            """
        )

        #expect(!taken.sensors.isEmpty)
        // A cycle that queued behind the snapshot would cost about what the snapshot costs.
        #expect(
            worst * 4 < contendedSnapshot,
            "worst cycle \(worst) against a \(contendedSnapshot) snapshot: it queued behind")
    }

    /// End to end over a real XPC connection, on real hardware: app to boundary to root
    /// authority to SMC and back, with no write path anywhere in it.
    @Test("A real snapshot crosses a real connection and decodes")
    func snapshotCrossesTheBoundary() async throws {
        // One provider, read through twice: the fans and the mode key must come from the
        // same source, or a snapshot is one instant's report assembled from two.
        let provider = SMCSensorProvider()
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider), log: Self.log,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger())
        let harness = AnonymousListenerHarness(authority: authority)

        _ = await harness.payloadMessage { proxy, reply in
            proxy.hello(request: (try? helloPayload()) ?? Data(), reply: reply)
        }
        let result = await harness.payloadMessage { proxy, reply in
            proxy.snapshot(reply: reply)
        }

        let data = try #require(result.payload)
        let snapshot = try AeolusXPCCoding.decoder().decode(SystemSnapshot.self, from: data)
        #expect(!snapshot.fans.isEmpty)
        #expect(snapshot.protocolVersion == AeolusXPCVersion.current)
    }

    /// The **whole composed helper** — the graph `main()` builds — against the real SMC.
    ///
    /// ## In this suite rather than a suite of its own, deliberately
    ///
    /// Swift Testing's `.serialized` orders a suite's own tests; separate suites still run in
    /// parallel, and this file's own header records what that costs against one piece of
    /// hardware — *"three concurrent `readAll()` enumerations against the same SMC turned a
    /// 5.9 s cold discovery into 24.9 s"*. Measured again while writing this: the same test in
    /// a sibling suite put its first snapshot at **22.0 s**, against **3.3 s** when run inside
    /// this one. A seventh concurrent hardware suite would also have been new load underneath
    /// `warmSnapshotIsCheap`'s two-second threshold, which is the assertion in this file most
    /// likely to go flaky for reasons nobody chose.
    ///
    /// ## Read-only, and structurally so
    ///
    /// The test process runs as the user and cannot register a launch daemon. It does not
    /// need to: every write verb on `SMCFanControlPlane` throws `.controlPathNotBuilt` before
    /// touching IOKit, and `writeCapability` refuses the lease before anything gets that far.
    /// The supervisors started below really do read — § 3 samples the curated thirty-four keys
    /// once per second — and really cannot write.
    ///
    /// ## The bring-up latency #103 asked for
    ///
    /// #103 left *"bring-up latency vs. launchd on-demand connect"* unsettled and assigned
    /// the measurement to E5.4a. The number a client actually experiences is bring-up **plus**
    /// the first snapshot, because `main()` advertises the Mach service only after bring-up
    /// returns — so a connection that triggers an on-demand launch waits for both. Printed
    /// rather than asserted, for the reason every measured figure in this suite is printed: a
    /// figure that drifts with the machine is a measurement, not a budget.
    ///
    /// The three claims share one bring-up because composing the graph twice would put two
    /// `SMCReadScheduler`s on this machine's single connection — the hazard the whole
    /// composition-root suite exists to prevent, and the thing the timing would then be
    /// measured against.
    @Test("A helper composed with the real control plane serves a snapshot and refuses a lease")
    func theComposedHelperServesRealHardware() async throws {
        let composingStarted = ContinuousClock.now
        // Both teardown seams are the test's, and neither is fastidiousness. The shipping
        // source would `SIG_IGN` this process's `SIGTERM`, `SIGINT` and `SIGHUP` and then
        // `exit(0)` the test runner on the next one; the shipping terminator would end this
        // process outright when the teardown is run at the end of the test. Everything else
        // here is production's.
        let teardown = TeardownJournal()
        let helper = HelperComposition.production(
            log: Self.log,
            teardown: TeardownSeams(
                sources: RecordingSignalSources(),
                terminate: { outcome in await teardown.record(.exited(outcome)) }))
        let composed = ContinuousClock.now - composingStarted

        // The three supervisors this bring-up starts are 1 Hz loops on the real SMC, so
        // they have to be stopped however this test leaves — a `snapshot()` that throws
        // included. `defer` cannot do it: a `defer` body may not `await`, which is a
        // compiler rule and not a style choice, so the catch below is the same guarantee
        // spelled the way Swift allows. Leaking them is the concurrent-load hazard this
        // suite's header names, and this test is the only one here that starts any.
        do {
            let bringUpStarted = ContinuousClock.now
            await helper.bringUp()
            let broughtUp = ContinuousClock.now - bringUpStarted

            let snapshotStarted = ContinuousClock.now
            let snapshot = try await helper.authority.snapshot()
            let firstSnapshot = ContinuousClock.now - snapshotStarted

            print(
                """
                helper bring-up on Mac16,5: composing the graph \(composed); \
                bringUp() — the registries bound and three supervisors started — \(broughtUp); \
                first snapshot, which pays for sensor discovery, \(firstSnapshot); \
                total before a first client could be answered \
                \(composed + broughtUp + firstSnapshot)
                """)

            #expect(!snapshot.fans.isEmpty, "the composed helper enumerated no fans")
            #expect(!snapshot.sensors.isEmpty, "the composed helper discovered no sensors")
            #expect(snapshot.activeLease == nil, "no lease can be granted in this build")
            #expect(snapshot.isThermalEmergencyActive == false)
            for fan in snapshot.fans { Self.expectHonestAvailability(of: fan) }

            // The capability gate, end to end: no double anywhere between this call and
            // `SMCFanControlPlane.writeCapability`.
            await #expect(
                throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
            ) {
                _ = try await helper.authority.acquireLease(
                    LeaseFixture.request(fans: [snapshot.fans[0].index]), from: ConnectionID())
            }

            // Both safety mechanisms are running against this machine rather than merely
            // constructed, which is the whole of #163 stated as a fact a test can read.
            #expect(await helper.restorer.isBound)
            #expect(await helper.thermalSupervisor.isRunning)
            #expect(await helper.reclamationSupervisor.isRunning)
            #expect(await helper.leaseExpirySupervisor.isRunning)
            #expect(
                await helper.thermalEmergency.fansUnderManualControl.isEmpty,
                "nothing can be off automatic control in a build with no write path")

        } catch {
            await helper.shutDown()
            throw error
        }

        // § 6's orderly teardown, run against the **real** plane rather than a scripted one.
        //
        // This is the hardware row E5.4d can execute today, and it is worth being exact
        // about what it does and does not show. `SMCFanControlPlane.restoreToAutomatic(_:)`
        // throws `.controlPathNotBuilt` before touching IOKit, so what is demonstrated on
        // this machine is the **nothing-to-restore** half of the exit-code contract, ruling
        // D15's: the keystone is issued twice, it is refused by the *build* rather than by
        // the firmware, and the process would exit zero so that launchd leaves it down. The
        // row that matters more — `launchctl bootout` or `kill -TERM` with a lease held, and
        // a fan that actually comes back — needs a signed daemon and a write path, and
        // belongs to E3/E4 bring-up. So does the row that would show a non-zero exit: it
        // takes a firmware that refuses a mode write, and no build here can issue one.
        //
        // It also doubles as this test's `shutDown()`: stopping the supervisors is the
        // teardown's own fourth step, and running it here rather than beside it is the point.
        await helper.signalTeardown.run(stoppingSupervisorsWith: { await helper.shutDown() })

        #expect(
            await teardown.events == [.exited(.nothingToRestore)],
            """
            the orderly teardown did not report "nothing to restore" on a build whose \
            keystone write cannot reach the firmware. A non-zero exit here would make \
            #165's `SuccessfulExit = false` restart this helper after every bootout and \
            every quit, over fans it could never have touched.
            """)
        #expect(await helper.thermalSupervisor.isRunning == false, "§ 3 outlived the teardown")
        #expect(await helper.reclamationSupervisor.isRunning == false, "§ 5 outlived it")
        #expect(await helper.leaseExpirySupervisor.isRunning == false, "§ 1's TTL loop did")
    }

    /// What the composed helper must answer about one real fan, in **either** state this
    /// machine is legitimately in.
    ///
    /// Two honest answers, and which one applies depends on what else is running rather than
    /// on this build. `SupervisedFanAuthority` re-states a fan the firmware reports in
    /// manual, that Aeolus is not accountable for, as `.foreignManualControl`
    /// ([ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md)) — and
    /// on the development machine that is a live condition rather than a hypothesis: Macs
    /// Fan Control was observed holding both fans on 2026-09-05, and releasing them again
    /// within the hour while still running (`docs/SMC-RESEARCH.md`).
    ///
    /// Asserting `.writePathNotBuilt` unconditionally, as this did, made the test a report
    /// about whatever was on the reviewer's desktop. Asserting the pair makes it a report
    /// about the helper, and it still cannot pass by accident: each branch pins a different
    /// answer, and answering the *other* one fails.
    private static func expectHonestAvailability(of fan: FanState) {
        let expected: ManualControlAvailability =
            fan.mode == .automatic
            ? .unavailable(.writePathNotBuilt) : .unavailable(.foreignManualControl)
        #expect(
            fan.manualControlAvailability == expected,
            """
            Fan \(fan.index) reads \(fan.mode) and the composed helper answers \
            \(fan.manualControlAvailability). A fan on Apple's thermal management must \
            answer .writePathNotBuilt — this build has no write path for any fan — and a fan \
            in manual that no lease covers must answer .foreignManualControl, because \
            something outside Aeolus is holding it and telling the user to look at Aeolus \
            sends them to the wrong program.
            """)
    }

    /// The hardware-checklist row #164 makes executable: what `F<n>Md` actually reads on this
    /// machine at the moment a helper would start.
    ///
    /// Read-only, and it is the one row of that issue's list that needs neither a signing
    /// identity nor a write path. Everything else about reconciliation — the restore landing,
    /// boot-start, `kill -9` — waits for E3/E4.
    ///
    /// **The number is printed and the mode is asserted, and the asymmetry is deliberate.**
    /// `0` is what the pass expects to find on a healthy machine with nothing holding the
    /// fans, and a `1` is a genuine observation rather than a test failure — it would mean
    /// something on this machine is holding a fan, which is exactly the condition ADR 0011
    /// exists for. The assertion is here anyway, because the checklist row is *"both fans
    /// read `F<n>Md == 0`"* and a row that cannot fail records nothing: if this goes red,
    /// read the printed values and the failure is the finding.
    @Test("Every fan on this machine reads F<n>Md == 0 at the moment a helper would start")
    func everyFanIsOnAutomaticControlAtStart() async throws {
        // One provider for both reads. Two would be two views of the same connection on a
        // suite whose other tests are timing the SMC, and this row needs neither.
        let provider = SMCSensorProvider()
        let plane = supervisorPlane(over: provider)
        let fans = try await SMCFanEnumeration.enumerate(provider: provider)

        var observed: [String] = []
        for index in fans.fanIndices.sorted() {
            let state = try await plane.readControlState(ofFan: index)
            observed.append("F\(index)Md=\(state.mode == .automatic ? 0 : 1)")
            #expect(
                state.mode == .automatic,
                """
                Fan \(index) is in manual control on this machine. Startup reconciliation \
                would hand it back — and on this build be refused, because there is no write \
                path. Every fan-state measurement taken here while that is true is \
                contaminated: find what is holding the fan before trusting any of them.
                """)
        }

        print(
            """
            startup fan modes on Mac16,5: \(observed.joined(separator: ", ")) \
            (0 = Apple's thermal management). Read through the production plane's scheduler, \
            one supervisor turn per fan, exactly as startup reconciliation reads them.
            """)
        #expect(!observed.isEmpty, "no fan was enumerated, so the row measured nothing")
    }
}
