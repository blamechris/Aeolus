import FanKit
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 5's mechanism: what it decides, and — more importantly — what it
/// refuses to decide.
///
/// Two of these are named in [#126](https://github.com/blamechris/Aeolus/issues/126) as
/// mutation checks, and they are the reason the suite exists in this shape rather than as a
/// list of happy paths:
///
/// - `itDoesNotReadAnEmergencyRampAsReclamation` dies if the primary signal becomes
///   actual-versus-target.
/// - `itNeverReassertsWhileTheThermalLatchHolds` dies if the arbiter consultation is
///   deleted.
///
/// Both were run against their mutants. Neither passes without the code it names.
@Suite("The reclamation watchdog")
struct ReclamationWatchdogTests {

    // MARK: - The primary signal, and what it must not be

    /// **Mutation check.** Switch the primary signal to actual-versus-target and this goes
    /// red.
    ///
    /// The scenario is § 3's own emergency ramp, which is the one moment § 5 must not fire:
    /// the fan has been commanded to maximum, `F<n>Tg` reads back exactly that, and
    /// `F<n>Ac` is still climbing through 2,000 RPM because a fan slews toward its target
    /// rather than stepping. The written target agrees with the read-back target, so there
    /// is no divergence — and a watchdog comparing actual against target here would take
    /// the fans back from the mechanism that is cooling the machine.
    ///
    /// The secondary signal sees the same shortfall and does not fire either, because its
    /// dwell has not elapsed. That is asserted separately below; here it is what makes the
    /// mutation check honest, since a single cycle must produce **no** action at all.
    @Test("An emergency ramp in flight is not read as reclamation")
    func itDoesNotReadAnEmergencyRampAsReclamation() async throws {
        let machine = ReclamationMachine(
            fans: [0: .ramping(target: 5_777, actual: 2_000)])
        try await machine.hold(fan: 0, commanding: 5_777)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.reclaimedFans.isEmpty)
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.commandedRPMs.isEmpty)
    }

    /// The primary signal fires when the firmware is holding a different number.
    ///
    /// A `.reverted` write leaves exactly this behind: the command succeeded, and `F<n>Tg`
    /// kept what it had.
    @Test("A target that reads back as something else is divergence")
    func aDivergedTargetIsReclamation() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0))
    }

    /// The mode is the unambiguous half, and it needs no commanded target to read.
    @Test("A fan the firmware reports as automatic is divergence")
    func anAutomaticModeIsReclamation() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .automatic, targetRPM: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0))
    }

    /// An unreadable target read-back is divergence, **never** "no divergence".
    ///
    /// #126's acceptance criterion and the reason `FanRPMReadback` is an enum rather than a
    /// `Double?`. `FanCondition.undecodableBounds`' sibling case: a NaN target decodes to
    /// `.unreadable` through the seam's finiteness rule, and a watchdog that treated that as
    /// convergence would report a fan it can no longer see as healthy.
    ///
    /// Make `primaryDivergence` return `nil` for `.unreadable` and this goes red.
    @Test("An unreadable target read-back is divergence, not silence")
    func anUnreadableTargetIsReclamation() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .manual, targetRPM: .nan)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.safetyLog.faults.contains { $0.contains("could not be read") })
    }

    /// A fan holding exactly what it was told stays ours, and says so once.
    @Test("A converged fan is not reported as reclaimed")
    func aConvergedFanIsLeftAlone() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.reclaimedFans.isEmpty)
        #expect(await machine.didRestore(fan: 0) == false)
    }

    // MARK: - The secondary signal and its dwell

    /// The dwell is real: the shortfall is present from the first cycle and fires on the
    /// fifth.
    ///
    /// **Driven rather than asserted against the constant.** The loop runs
    /// `ReclamationLimits.actualDwellCycles` times and checks that nothing happened until
    /// the last of them, so lowering the constant to 1 turns the "not yet" assertion red
    /// rather than quietly agreeing with a new number.
    @Test("The secondary signal does not fire before its dwell has elapsed")
    func theSecondarySignalWaitsForItsDwell() async throws {
        let machine = ReclamationMachine(
            fans: [0: .ramping(target: 2_400, actual: 1_000)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for cycle in 1..<ReclamationLimits.actualDwellCycles {
            await machine.watchdog.cycle()
            #expect(
                await machine.ledger.reclaimedFans.isEmpty,
                "the secondary signal fired on cycle \(cycle), before its dwell elapsed")
        }

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0))
    }

    /// A fan turning *faster* than commanded is not divergence.
    ///
    /// The shortfall is one-directional on purpose: a fan running above its target is the
    /// system helping or a sensor reading high, and firing on it would take fans back from a
    /// machine that is cooling perfectly well.
    @Test("A fan turning faster than commanded is never a shortfall")
    func anOverspeedingFanIsNotReclamation() async throws {
        let machine = ReclamationMachine(
            fans: [0: .ramping(target: 2_400, actual: 3_600)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0...ReclamationLimits.actualDwellCycles {
            await machine.watchdog.cycle()
        }

        #expect(await machine.ledger.reclaimedFans.isEmpty)
    }

    // MARK: - Never fighting above the ceiling

    /// **Mutation check.** Delete the `ruling.permitsWrite` guard and this goes red.
    ///
    /// § 3 holds the latch, so level 2 is the incumbent and level 3 is pre-empted —
    /// `SafetyArbiter`'s first production ruling. The fan really is diverged, so a watchdog
    /// without the guard would re-assert into a machine § 3 has just handed to Apple's
    /// thermal management, which is two safety mechanisms fighting over a fan while a CPU
    /// sits above its ceiling.
    ///
    /// What it must do instead: finalise the release, leave the latch alone, and report.
    @Test("It never re-asserts while the thermal emergency latch holds")
    func itNeverReassertsWhileTheThermalLatchHolds() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.engageThermalEmergency()

        await machine.watchdog.cycle()

        #expect(await machine.commandedRPMs.isEmpty, "level 3 wrote while level 2 held")
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        // The latch is § 3's, and § 5 does not touch it — releasing it here would hand the
        // fans back on a machine nobody has read since it was above its ceiling.
        #expect(await machine.latch.isActive)
    }

    /// Below the ceiling the same divergence produces a re-assert, which is what proves the
    /// test above is about the latch rather than about divergence being ignored.
    @Test("Below the ceiling, the same divergence is re-asserted")
    func belowTheCeilingItReasserts() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.commandedRPMs == [2_400])
        // Re-engaged first: a reclaimed fan is on automatic, so a target written without
        // the mode verb is a number nothing honours.
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
    }

    // MARK: - The bounded budget

    /// The budget is **driven to exhaustion**, not asserted against its constant.
    ///
    /// `WriteBehaviour.reverted` is the machine § 5 cannot win against: every write is
    /// accepted and discarded, so each cycle re-reads the same divergence. The loop runs
    /// until the fan is restored, and then checks that the number of re-asserts issued was
    /// the budget — so changing `reassertAttemptBudget` changes what this test observes
    /// without changing whether it passes, and removing the budget entirely makes it spin
    /// past its bound and fail.
    @Test("A re-assert that never holds exhausts its budget and then restores")
    func theReassertBudgetIsSpentAndThenFallsBack() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .reverted)],
            fans: [0: .held(at: 1_800)])
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 2_400)

        var cycles = 0
        let bound = ReclamationLimits.reassertAttemptBudget + 5
        while await !machine.didRestore(fan: 0), cycles < bound {
            await machine.watchdog.cycle()
            cycles += 1
        }

        #expect(await machine.didRestore(fan: 0), "the budget never ran out")
        #expect(await machine.commandedRPMs.count == ReclamationLimits.reassertAttemptBudget)
        // The lease goes with it, labelled for what happened: a client left holding a lease
        // over a fan the firmware is not honouring is told it has control it does not have.
        #expect(await machine.restorer.causes == [.systemReclaimed])
    }

    /// Once the budget is spent the watchdog stops watching that fan, so it cannot go on
    /// commanding a fan it has already handed back.
    @Test("A fan that has been given up on is no longer watched")
    func aReleasedFanLeavesTheRegistry() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .reverted)],
            fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<(ReclamationLimits.reassertAttemptBudget + 3) {
            await machine.watchdog.cycle()
        }

        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.commandedRPMs.count == ReclamationLimits.reassertAttemptBudget)
    }

    /// A re-assert that cannot obtain an envelope **restores rather than commanding**.
    ///
    /// #126's acceptance criterion, and `docs/SAFETY.md` § 2's closing rule reached from
    /// § 5: the only action a fan with untrusted bounds is subject to is the bounds-free
    /// restore verb. It also spends no budget — there is nothing to retry when the bounds
    /// themselves cannot be established.
    @Test("A re-assert with no obtainable envelope restores instead of commanding")
    func aReassertWithoutAnEnvelopeRestores() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let machine = ReclamationMachine(
            fans: [0: .held(at: 1_800)], sensing: EnvelopeRefusingSensing(plane))
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.commandedRPMs.isEmpty, "it commanded a fan with no bounds")
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.safetyLog.faults.contains { $0.contains("no range to clamp") })
    }

    /// Divergence before anything was ever commanded has nothing to re-assert to.
    @Test("A fan reclaimed before any target was commanded is restored, not re-asserted")
    func aFanWithNoCommandedTargetIsRestored() async throws {
        let machine = ReclamationMachine(
            fans: [0: ScriptedControlPlane.FanCondition(mode: .automatic)])
        try await machine.holdWithoutCommanding(fan: 0)

        await machine.watchdog.cycle()

        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.didRestore(fan: 0))
    }

    // MARK: - Blindness is divergence

    /// One unreadable cycle changes nothing. Taking a fan from a client because a single
    /// read missed would be over-firing on noise.
    @Test("A transient read failure changes nothing")
    func aTransientReadFailureIsNotDivergence() async throws {
        let machine = ReclamationMachine(
            stages: [.blind(), .nominal()],
            fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.ledger.reclaimedFans.isEmpty)

        await machine.plane.advance()
        await machine.watchdog.cycle()

        #expect(await machine.didRestore(fan: 0) == false)
        #expect(
            await machine.safetyLog.lines.contains { $0.contains("can read fan 0 again") },
            "recovery was not logged, so a reader sees a fan go quiet and never come back")
    }

    /// Persistent read failure **is** divergence: reconnect, then restore and report.
    ///
    /// ADR 0007's hole 2 — `SAFETY.md` § 5 covered divergence of values and nothing covered
    /// the inability to obtain them, while a lease keeps the fans pinned. Driven to the
    /// threshold rather than asserted against it.
    @Test("Persistent read failure attempts a reconnect and then restores")
    func persistentBlindnessReconnectsThenRestores() async throws {
        let machine = ReclamationMachine(
            stages: [.blind()],
            fans: [0: .held(at: 2_400)])
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 2_400)

        for cycle in 1..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
            #expect(
                await machine.didRestore(fan: 0) == false,
                "it gave up on cycle \(cycle), before the failure was persistent")
        }

        await machine.watchdog.cycle()

        #expect(await machine.attempts.contains(ScriptedControlPlane.Attempt.reconnect))
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        // `.supervisorBlind`, not `.systemReclaimed`. A helper that has gone blind and a
        // helper losing a contest with the OS are diagnosed differently, which is what
        // `FanRestoreCause` exists to keep apart.
        #expect(await machine.restorer.causes == [.supervisorBlind])
    }

    /// The restore does not wait on the reconnect having worked.
    ///
    /// § 5 says reconnect **then** restore and report — not reconnect and hope. A reconnect
    /// that returns cleanly has read nothing since, so it is no evidence that reading works,
    /// and waiting for the next cycle to find out is another cycle with a fan pinned on a
    /// machine nobody can see. Make the restore conditional on the reconnect throwing and
    /// this goes red.
    @Test("A reconnect that succeeds does not cancel the restore")
    func aSuccessfulReconnectStillRestores() async throws {
        let machine = ReclamationMachine(
            stages: [.blind(reconnects: .succeeded)],
            fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }

        #expect(await machine.attempts.contains(ScriptedControlPlane.Attempt.reconnect))
        #expect(await machine.didRestore(fan: 0))
    }

    // MARK: - The restore is the floor

    /// A refused restore is logged, never swallowed, and the fan still leaves the registry.
    ///
    /// `no_silent_write_failure`: converting "the fan is still pinned" into "the watchdog
    /// completed" is the inversion this whole subsystem exists to prevent.
    @Test("A refused restore is reported rather than swallowed")
    func aRefusedRestoreIsLogged() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .refused(reason: "firmware said no"))],
            fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<(ReclamationLimits.reassertAttemptBudget + 2) {
            await machine.watchdog.cycle()
        }

        #expect(await machine.safetyLog.faults.contains { $0.contains("could not restore") })
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - Reporting

    /// The ledger is the snapshot's source, and it clears when the fan comes back.
    ///
    /// The re-assert is to 2,000 RPM against a fan turning at 1,800, so the recovered state
    /// converges on **both** signals: the target reads back exactly, and the 200 RPM lag is
    /// inside `actualToleranceFraction`. A scenario whose fan could never satisfy the
    /// secondary signal would leave the ledger legitimately marked and would be asserting
    /// the wrong thing — the flag follows what the mechanism believes, and a sustained
    /// shortfall is still a belief that something is wrong.
    @Test("A fan that converges again stops being reported as reclaimed")
    func convergenceClearsTheLedger() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_000)

        await machine.watchdog.cycle()
        #expect(await machine.ledger.isReclaimed(fanAt: 0))

        // The re-assert landed: the firmware now holds what was asked for.
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
        #expect(await machine.safetyLog.lines.contains { $0.contains("no longer reported") })
    }

    /// Detection is logged on the transition, not once per cycle.
    ///
    /// #124's forward constraint: a line per tick at 1 Hz is a denial of service against the
    /// reader, and it would bury the line that matters.
    @Test("A persistent reclamation is announced once, not once per cycle")
    func detectionIsLoggedOnTheTransition() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .reverted)],
            fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<ReclamationLimits.reassertAttemptBudget {
            await machine.watchdog.cycle()
        }

        let announcements = await machine.safetyLog.lines.filter {
            $0.contains("Reclamation detected on fan 0")
        }
        #expect(announcements.count == 1)
    }

    // MARK: - Scheduling

    /// Fans are examined **one at a time**, which is #126's answer to
    /// [#134](https://github.com/blamechris/Aeolus/issues/134).
    ///
    /// `SMCReadScheduler` is FIFO within `.supervisor` and forces a snapshot turn after
    /// every two overtakes, so each additional outstanding supervisor read delays § 3's
    /// cycle by its own turn *plus* a share of a quota-forced 64-key snapshot turn.
    /// Examining sequentially means this mechanism contributes at most one waiter however
    /// many fans the machine has.
    ///
    /// The gate is what makes that observable: `ScriptedControlPlane`'s methods have no
    /// suspension point, so two concurrent callers could never be caught overlapping there,
    /// and a test built on the mock alone would pass against a `withTaskGroup`
    /// implementation. Rewrite `cycle()`'s loop as a task group and `peakOutstanding`
    /// reaches 2.
    @Test("It examines one fan at a time, never several at once")
    func itExaminesFansSequentially() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)])
        let sensing = GatedFanStateSensing(plane)
        let machine = ReclamationMachine(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        try await machine.hold(fan: 1, commanding: 2_400)

        let sweep = Task { await machine.watchdog.cycle() }

        let arrived = await yieldUntil("the first fan's control-state read") {
            await sensing.controlStateRequests.isEmpty == false
        }
        #expect(arrived)

        // Give a concurrent implementation every opportunity to issue the second read.
        for _ in 0..<100 { await Task.yield() }
        #expect(
            await sensing.controlStateRequests == [0],
            "fan 1 was asked about while fan 0's read was still in flight")

        await sensing.open()
        await sweep.value

        #expect(await sensing.controlStateRequests == [0, 1])
        #expect(await sensing.peakOutstanding == 1)
    }

    /// An empty registry does no work at all — no read, no latch consultation, nothing.
    ///
    /// The ordinary state of every build that ships today, and the reason a running
    /// supervisor costs nothing while no lease exists.
    @Test("A cycle with no fan under manual control touches the machine not at all")
    func anEmptyRegistryIssuesNoReads() async throws {
        let machine = ReclamationMachine()

        await machine.watchdog.cycle()

        #expect(await machine.attempts.isEmpty)
    }
}
