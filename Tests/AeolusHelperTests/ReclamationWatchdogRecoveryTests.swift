import Testing

@testable import AeolusHelper

/// What § 5 *does* once it has decided a fan is gone: the bounded re-assert, the fallback it
/// is floored by, and the blindness escalation.
///
/// Split from `ReclamationWatchdogTests` on subject when that suite crossed SwiftLint's
/// `type_body_length` limit. The seam is the one `docs/SAFETY.md` § 5 itself draws — *"the
/// helper either re-asserts control or falls back to automatic — and either way tells the
/// user"* — so the signals are next door and the actions are here.
///
/// **The budget and the blind-cycle threshold are driven to exhaustion, never compared
/// against their constants.** A test that asserts `attempts == ReclamationLimits.reassertAttemptBudget`
/// agrees with whatever the constant becomes; these count real cycles until the mechanism
/// gives up, so changing a constant changes what the test observes rather than what it
/// expects.
@Suite("The reclamation watchdog's recovery paths")
struct ReclamationWatchdogRecoveryTests {

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

    /// A half-landed re-assert restores immediately rather than spending another attempt.
    ///
    /// The firmware accepts `F<n>Md` and refuses `F<n>Tg`, which leaves the fan **off**
    /// Apple's thermal management holding whatever speed the system last wrote — the worst
    /// reachable state in this project, and the opposite of what refusing both leaves
    /// behind. Wrapping both writes in one `do`/`catch` made those indistinguishable.
    @Test("A re-assert whose target write is refused restores rather than retrying")
    func aHalfLandedReassertRestoresImmediately() async throws {
        let machine = ReclamationMachine(
            stages: [
                .nominal(
                    writes: .honoured,
                    targetWrites: .refused(reason: "the firmware refused the target"))
            ],
            fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(
            await machine.didRestore(fan: 0),
            "a fan was left off automatic holding a speed nobody chose")
        #expect(machine.safetyLog.lines(containing: "could not command a target").count == 1)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

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
        // `.supervisorBlind`, not `.systemReclaimed`. A helper that has gone blind and a
        // helper losing a contest with the OS are diagnosed differently, which is what
        // `FanRestoreCause` exists to keep apart.
        #expect(await machine.restorer.causes == [.supervisorBlind])
    }

    /// The ledger keeps that distinction too, and #140 is where it did not.
    ///
    /// The blindness path called `markReclaimed(fanAt:)` and then revoked the lease
    /// `because: .supervisorBlind`, so the one field the user sees — `isReclaimedBySystem`,
    /// rendered verbatim as "Reclaimed by system" — said the operating system had taken a
    /// fan that nothing had been learned about. All that was learned is that the helper
    /// cannot read: a stale `io_connect_t` after wake ([#68]), which is ADR 0007's hole 2
    /// and not a contest with Apple's thermal management. Telling the user the system took
    /// the fan sends them to look at macOS's thermal behaviour instead of at Aeolus's dead
    /// SMC connection, and it is `CLAUDE.md` rule 6 in the direction this file's ledger
    /// documents: claiming to have *lost* control that nobody has shown was lost.
    ///
    /// Collapse `ReclamationLedger.Cause`'s two cases — have `markSupervisorBlind(fanAt:)`
    /// record `.systemReclaimed` — and this goes red on both assertions.
    @Test("A blind episode is recorded as blindness, not as a system reclamation")
    func blindnessIsNotRecordedAsASystemReclamation() async throws {
        let machine = ReclamationMachine(
            stages: [.blind()],
            fans: [0: .held(at: 2_400)])
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }

        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
        #expect(await machine.ledger.isSupervisorBlind(fanAt: 0))
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

    /// Falling back drops **every** fan, because the revocation it performs is whole-machine.
    ///
    /// `revokeEveryLease(because:)` drops every lease and the lease core restores the fans
    /// they covered, so a sibling left in the registry is a fan that is now unleased and on
    /// automatic. Keeping it produced the worst possible follow-up: the next cycle read
    /// `.modeReclaimed` on that sibling and **re-engaged manual control on a fan with no
    /// lease behind it**.
    ///
    /// Change `held.removeAll()` back to dropping only `index` and the last assertion goes
    /// red.
    @Test("Falling back stops watching every fan, not just the one that diverged")
    func fallingBackClearsTheWholeRegistry() async throws {
        let machine = ReclamationMachine(
            fans: [0: .nominal, 1: .held(at: 2_400)])
        try await machine.lease(fans: [0, 1])
        try await machine.holdWithoutCommanding(fan: 0)
        try await machine.hold(fan: 1, commanding: 2_400)

        // Fan 0 reads automatic with nothing ever commanded: it falls straight through to
        // the terminal action, which revokes the lease covering fan 1 as well.
        await machine.watchdog.cycle()

        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.safetyLog.lines(containing: "also stopped watching").count == 1)
        // Fan 1 was given up, not taken: it must not be reported as reclaimed.
        #expect(await machine.ledger.isReclaimed(fanAt: 1) == false)

        // The sibling is not re-engaged on any later cycle.
        await machine.watchdog.cycle()
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 1)) == false,
            "§ 5 re-engaged manual control on a fan whose lease it had just revoked")
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
}
