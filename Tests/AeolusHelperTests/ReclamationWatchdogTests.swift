import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 5's **signals**: what makes this mechanism decide a fan has been taken,
/// and what it must decline to read that way.
///
/// The verdicts only. What § 5 then *does* about a verdict — re-assert, fall back, escalate
/// blindness — is `ReclamationWatchdogRecoveryTests`, and what happens when the machine moves
/// while § 5 is mid-read is `ReclamationWatchdogStalenessTests`. Three suites because one
/// crossed SwiftLint's `type_body_length` limit, split on subject rather than on line count,
/// the same way `ThermalEmergencyReportingTests` was split from `ThermalEmergencyTests`.
///
/// Everything here runs through `ScriptedControlPlane`, which is what #100 built it for.
@Suite("The reclamation watchdog's signals")
struct ReclamationWatchdogTests {

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

    /// The dwell is real: the shortfall is present from the first cycle and reports on the
    /// fifth.
    ///
    /// **Driven rather than asserted against the constant.** The loop runs
    /// `ReclamationLimits.actualDwellCycles` times and checks that nothing was said until
    /// the last of them, so lowering the constant to 1 turns the "not yet" assertion red
    /// rather than quietly agreeing with a new number.
    @Test("The secondary signal says nothing before its dwell has elapsed")
    func theSecondarySignalWaitsForItsDwell() async throws {
        let machine = ReclamationMachine(
            fans: [0: .ramping(target: 2_400, actual: 1_000)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for cycle in 1..<ReclamationLimits.actualDwellCycles {
            await machine.watchdog.cycle()
            #expect(
                machine.safetyLog.lines(containing: "has turned at").isEmpty,
                "the secondary signal reported on cycle \(cycle), before its dwell elapsed")
        }

        await machine.watchdog.cycle()

        #expect(machine.safetyLog.lines(containing: "has turned at").count == 1)
    }

    /// **The defect this rework exists for.** A sustained shortfall reports and does
    /// nothing else.
    ///
    /// The fixture is `.ramping` — the mock's own doc calls it "a ramp in flight" — so
    /// `F0Tg` reads back exactly the 2,400 that was commanded on every cycle. The primary
    /// signal therefore converges every cycle, which is the *precondition* for the secondary
    /// being evaluated at all. Aeolus is fully in control of this fan.
    ///
    /// It used to end with the fan restored to automatic and every lease on the machine
    /// revoked, roughly eight cycles in: dwell 5 marked the ledger, then three re-assert
    /// attempts were spent in three consecutive cycles because nothing reset the dwell, then
    /// the budget ran out. A user who asked for a speed their fan could not physically reach
    /// lost manual control, and both the log and `isReclaimedBySystem` blamed the OS.
    ///
    /// Every assertion below is one of the four things that must now not happen. Route the
    /// shortfall back through `diverged(_:fanAt:)` and all four go red.
    @Test("A sustained shortfall reports, and never reaches the terminal action")
    func aSustainedShortfallOnlyReports() async throws {
        let machine = ReclamationMachine(
            fans: [0: .ramping(target: 2_400, actual: 1_000)])
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 2_400)

        // Well past the dwell and past the re-assert budget it used to consume.
        for _
            in 0...(ReclamationLimits.actualDwellCycles
            + ReclamationLimits.reassertAttemptBudget + 2)
        {
            await machine.watchdog.cycle()
        }

        #expect(
            await machine.ledger.reclaimedFans.isEmpty,
            "a fan whose target reads back correctly was reported as reclaimed")
        #expect(
            await machine.didRestore(fan: 0) == false,
            "a fan Aeolus still controls was handed back to automatic")
        #expect(
            await machine.commandedRPMs.isEmpty, "a converged target was pointlessly rewritten")
        #expect(
            await machine.leases.activeLease() != nil,
            "the user's lease was revoked over a fan that was never taken")
        // Still watched: the mechanism has not given up on it, it has only said so.
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        // And it said so exactly once, not once per cycle.
        #expect(machine.safetyLog.lines(containing: "has turned at").count == 1)
        // `.notice`, not `.fault`: nothing unsafe happened.
        #expect(machine.safetyLog.levels(containing: "has turned at") == [.notice])
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
        // **Not marked reclaimed**, and this is the half an earlier version got wrong. A
        // latched machine is exactly where § 5 should expect to find a fan reading
        // automatic, because `ThermalEmergency.fire(_:from:)` restores every fan it bridges.
        // Recording that as the *system* reclaiming produced a false `.fault` line about
        // Aeolus's own thermal override doing its job, and an `isReclaimedBySystem` that
        // stayed true for the rest of the process.
        #expect(
            await machine.ledger.reclaimedFans.isEmpty,
            "§ 3's own restore was attributed to the operating system")
        #expect(machine.safetyLog.lines(containing: "**not** recording it as reclaimed").count == 1)
        // **This is the assertion that discriminates**, and the one above cannot.
        // Mutation-checked: re-adding `ledger.markReclaimed` to the pre-empted branch left
        // `reclaimedFans.isEmpty` green, because `releaseToThermalEmergency(fanAt:)` ends
        // with `ledger.clearReclaimed(fanAt:)` — the same call path marks the fan and then
        // erases the mark, so the end state is identical either way. What survives the
        // round trip is the `.fault` line `markReclaimed`'s transition report fires on the
        // way through: "Reclamation detected", asserting that the system took a fan § 3
        // deliberately released. That is `CLAUDE.md` rule 6 in the direction the test's own
        // comment names, so its absence is the thing worth pinning.
        #expect(
            machine.safetyLog.lines(containing: "Reclamation detected").isEmpty,
            "§ 3's own restore was announced as a reclamation by the operating system")
        // Stopped watching it: level 2 owns this fan now.
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        // The latch is § 3's, and § 5 does not touch it — releasing it here would hand the
        // fans back on a machine nobody has read since it was above its ceiling.
        #expect(await machine.latch.isActive)
    }

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
