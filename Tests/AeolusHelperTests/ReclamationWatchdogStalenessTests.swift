import Testing

@testable import AeolusHelper

/// § 5 across a suspension point: what happens when the machine moves while it is looking.
///
/// `ReclamationWatchdog` is a reentrant actor, and every `await` in it — a read, a write, a
/// ledger or latch hop — is a point at which a lease can end or § 3 can latch. The original
/// implementation read state before those suspensions and acted on it after, in four separate
/// places, and **not one of the twenty tests it shipped with could see it**. An adversarial
/// review found all four; this suite is what makes them stay found.
///
/// ## Scripted, not raced
///
/// `ScriptedControlPlane`'s methods contain no suspension point a test can act inside, so a
/// scenario built on stages alone can only change the machine *between* cycles — and every
/// defect here happens *within* one. `InterferingFanStateSensing` runs a side effect inside a
/// chosen read, which makes the arrival scriptable: a concurrency test that starts all its
/// work at once cannot see a bug that needs work to **arrive**, and a repeat-until-it-races
/// loop would be the flakiness [#109](https://github.com/blamechris/Aeolus/issues/109) is
/// open about.
///
/// Each test asserts `didFire`, so a scenario that silently failed to arrange its own
/// interleaving is a failure rather than a pass. That guard is the difference between this
/// suite and one that would go green against the very code it was written to condemn.
@Suite("The reclamation watchdog, across a suspension point")
struct ReclamationWatchdogStalenessTests {

    /// **The rule-2 defect.** A fan released while the envelope read is in flight must not
    /// be written to.
    ///
    /// The interference fires inside `readEnvelope(ofFan:)` — the suspension
    /// `reassert(_:fanAt:attempt:)` resumes from — and releases the fan the way the lease
    /// core does when a TTL lapses or a connection dies. The watchdog resumes holding a
    /// `permit` for a fan it is no longer watching.
    ///
    /// It used to write `F<n>Md` and `F<n>Tg` anyway: manual control with no lease behind
    /// it, no registry entry to notice it, and nothing left to restore it. `CLAUDE.md`
    /// rule 2 — *manual control is a lease, never a setting* — with the lease gone.
    ///
    /// Delete the `guard held[index] != nil` after the envelope read and this goes red on
    /// the first two assertions.
    @Test("A fan released during its envelope read is never written to")
    func aFanReleasedDuringTheEnvelopeReadIsNotWritten() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [watchdog = machine.watchdog] in
            await watchdog.manualControlReleased(fanAt: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "§ 5 took an unleased fan off automatic control")
        #expect(
            await machine.commandedRPMs.isEmpty, "§ 5 commanded a fan it was not watching")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// The same rule one suspension earlier: a fan released during its control-state read is
    /// not judged from the copy taken before it.
    ///
    /// Acting on the pre-read copy reported an ordinary lease expiry as the system
    /// reclaiming a fan, and revoked whatever lease happened to be live at that instant —
    /// so a client that acquired one in the intervening milliseconds lost it.
    @Test("A fan released during its control-state read is not judged from the stale copy")
    func aFanReleasedDuringTheControlStateReadIsAbandoned() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateRead)
        let machine = ReclamationMachine(plane: plane, sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [watchdog = machine.watchdog] in
            await watchdog.manualControlReleased(fanAt: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        // The fan reads `.automatic`, which is `.modeReclaimed` — the strongest primary
        // signal there is. It must still not be acted on, because the fan is not ours.
        #expect(
            await machine.ledger.causes.isEmpty,
            "an ordinary lease release left an entry in § 5's ledger")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.leases.activeLease() == nil)
        // **This assertion is what makes the test discriminate**, and without it the test
        // could not fail for the guard it is named after. Mutation-checked: deleting the
        // re-fetch in `examine(fanAt:)` left every assertion above green, because the
        // second re-fetch in `diverged(_:fanAt:)` catches the same release one hop later
        // and returns before the ledger, the restore or the revocation is touched. The one
        // observable that changes is *where* the abandonment happened, so that is what is
        // asserted. Two guards that are each safe in combination are not two guards that
        // are each tested.
        #expect(
            machine.safetyLog.lines(containing: "during its control-state read").count == 1,
            "the examination was abandoned somewhere other than the control-state read")
    }

    /// The stale copy carries a stale **commanded target**, and that is the hazard the
    /// earliest re-fetch actually exists for.
    ///
    /// A release followed by a fresh engagement inside the same read leaves `held[index]`
    /// non-`nil` — so `diverged(_:fanAt:)`'s re-fetch, which catches the plain-release case,
    /// finds an entry and carries on. What it finds is a **new episode**: a new permit, and
    /// no commanded target, because nothing has written to this fan yet.
    ///
    /// Judging that episode against the previous one's 2,400 RPM is a divergence report
    /// about a fan a client has only just been granted, and it is exactly what the pre-read
    /// copy produces. Only the re-fetch in `examine(fanAt:)` prevents it, which is why this
    /// scenario is here and not folded into the one above.
    @Test("A fan re-engaged during its control-state read is not judged against the old target")
    func aFanReEngagedDuringTheReadIsNotJudgedAgainstTheOldTarget() async throws {
        // The firmware holds 1,800 — divergent against the 2,400 of the *old* episode, and
        // meaningless to the new one, which has commanded nothing at all.
        let condition = ScriptedControlPlane.FanCondition.held(at: 1_800)
        let plane = ScriptedControlPlane(fans: [0: condition])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateRead)
        let machine = ReclamationMachine(plane: plane, fans: [0: condition], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.watchdog.manualControlReleased(fanAt: 0)
            try? await machine.holdWithoutCommanding(fan: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        // The new episode is still watched — it was legitimately engaged.
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        // And nothing was concluded about it from the previous episode's target.
        #expect(
            await machine.ledger.causes.isEmpty,
            "a freshly engaged fan was recorded in the ledger, using the old episode's target")
        #expect(await machine.commandedRPMs.isEmpty, "a re-assert used a stale commanded target")
        #expect(await machine.didRestore(fan: 0) == false)
    }

    /// **Verify-after-act.** § 3 latching during the re-assert's writes undoes the
    /// re-assert.
    ///
    /// The ruling is checked before the writes, and the check cannot be atomic with them:
    /// the latch is one actor and the plane is another. So it is checked *again* afterwards.
    /// Here the interference latches § 3 inside the envelope read, which is after
    /// `diverged(_:fanAt:)` has already been told the ruling permits a write.
    ///
    /// Nothing else would correct this. `ThermalEmergency.fire(_:from:)` empties
    /// `engagedFans` as it goes and `manualControlEngaged(_:)` has no caller in `Sources/`,
    /// so a fan § 5 re-engaged is in no registry § 3 consults — its next cycle would leave
    /// the fan off automatic control indefinitely, above the ceiling. Delete the post-write
    /// `guard await currentRuling().permitsWrite` and this goes red.
    @Test("A re-assert is undone when the emergency latches mid-write")
    func itUndoesAReassertWhenTheEmergencyLatchesMidWrite() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, sensing: sensing)
        try await machine.lease(fans: [0])
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in await machine.engageThermalEmergency() }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        // The re-assert did happen — the pre-write check passed, which is what makes this a
        // test of the *post*-write one rather than of the guard before it.
        #expect(await machine.commandedRPMs == [2_400])
        // And was undone.
        #expect(await machine.didRestore(fan: 0), "a fan was left off automatic above ceiling")
        #expect(machine.safetyLog.lines(containing: "is being undone").count == 1)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

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
}
