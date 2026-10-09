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
/// `itExaminesFansSequentially` runs `machine.watchdog.cycle()`, gated by
/// `GatedFanStateSensing`, as an *observed* task rather than an awaited one —
/// `finished(_:_:)`'s bounded poll-and-cancel is what is load-bearing here, the same
/// pattern `SchedulerTurnLifecycleTests` uses for its own unbounded reads. A bare `await` on
/// the task would not be saved by `.timeLimit`: cancelling *this test's* task, which is all
/// `.timeLimit` can do, does not reach a suspension inside a separate unstructured
/// `Task { ... }` this test only joins — confirmed against `GatedFanStateSensing.open()`
/// replaced with a no-op, which left the run recording `.timeLimit`'s issue and then never
/// exiting. `.timeLimit` on this `@Suite` remains the backstop for everything else here —
/// the class of defect [#109](https://github.com/blamechris/Aeolus/issues/109) is about,
/// the same fix `AnonymousListenerTests` and `SMCReadSchedulerTests` already carry.
@Suite("The reclamation watchdog, across a suspension point", .timeLimit(.minutes(1)))
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
        // Non-`nil` since #180, when the fixture started leasing every held fan: the lease
        // that was live at that instant is still live, which is the revocation the paragraph
        // above describes not happening. It read `== nil` while no lease existed to revoke.
        #expect(
            await machine.leases.activeLease() != nil,
            "an abandoned examination revoked the lease that was live while it ran")
        // **This assertion is what makes the test discriminate**, and without it the test
        // could not fail for the guard it is named after. Mutation-checked: deleting the
        // re-fetch after the read in `examine(fanAt:)` left every assertion above green,
        // because the next re-fetch — after the lease check since #180, in
        // `diverged(_:fanAt:)` before that — catches the same release one hop later and
        // returns before the ledger, the restore or the revocation is touched. The one
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

    /// **#180's write-side hole.** A fan released while the re-assert's command write is in
    /// flight is restored, not logged as re-asserted.
    ///
    /// The release arrives the way the shipped composition delivers it — the lease core drops
    /// the entry, then `HelperFanRestorer` tells § 5 — after `F<n>Tg` has landed and while
    /// § 5 is still awaiting the write. `reassert` used to assign the result through
    /// `held[index]?.commanded`, which vanished silently, and then report a successful
    /// re-assert and run the post-write ruling for a fan it no longer held, leaving it off
    /// automatic control with nothing watching it. The lease core's own restore may have
    /// landed *before* this write did, so § 5 is the only thing that can put it back.
    ///
    /// **Mutation:** restore `held[index]?.commanded = recommanded` in place of the
    /// `guard var fan = held[index]` after the command write. Run: red on the restore, the
    /// re-assert log and the release log.
    @Test("A fan released during the re-assert's command write is restored, not re-asserted")
    func aFanReleasedDuringTheCommandWriteIsRestored() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(plane: plane, interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        // Both writes landed before the release: the test is about what follows them.
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(await machine.commandedRPMs == [2_400])
        #expect(
            await machine.didRestore(fan: 0),
            "a fan released during its command write was left off automatic control")
        #expect(
            machine.safetyLog.lines(containing: "re-asserted").isEmpty,
            "§ 5 reported a re-assert of a fan it no longer held")
        #expect(machine.safetyLog.lines(containing: "during its command write").count == 1)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.ledger.causes.isEmpty)
    }

    /// The same rule one write earlier: a fan released while the re-assert's mode write is in
    /// flight is restored, and never commanded.
    ///
    /// The command write after it is the second write away from the safe state, and the
    /// re-fetch after the command write would undo it — so the assertion that discriminates
    /// is that it was never issued, not that the fan ended up restored.
    ///
    /// **Mutation:** delete the `guard held[index] != nil` between `engageManualControl` and
    /// `command` in `reassert(_:fanAt:attempt:)`. Run: red on the command assertion and the
    /// release log; the restore assertion stays green, because the re-fetch after the command
    /// write catches the same release one write later.
    @Test("A fan released during the re-assert's mode write is never commanded")
    func aFanReleasedDuringTheEngageWriteIsNeverCommanded() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(plane: plane, interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.endLease()
            await machine.watchdog.manualControlReleased(fanAt: 0)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(
            await machine.commandedRPMs.isEmpty,
            "§ 5 commanded a fan that was released during its mode write")
        #expect(await machine.didRestore(fan: 0))
        #expect(
            machine.safetyLog.lines(containing: "during its manual-control write").count == 1)
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **The residual, bounded.** A lease that lapses during the command write with nobody
    /// told leaves `held` intact, so the re-fetch passes and the re-assert completes: D2 is
    /// asked once per examination, not inside the re-assert's writes, and asking it before
    /// and after each write is ADR 0014 D4's, not #180's. What D2 guarantees is that the
    /// state is not permanent — the next cycle's lease check hands the fan back.
    ///
    /// **Mutation:** delete the `guard entitled` block from `examine(fanAt:)`. Run: red on the
    /// second cycle's restore, registry and log assertions: the fan reads back the 2,400 RPM
    /// just written, converged on both signals, and nothing else would revisit it.
    @Test("A lease that lapses during the re-assert is handed back by the next cycle")
    func aLeaseLapsingDuringTheReassertIsHandedBackNextCycle() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(plane: plane, interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in machine.lapseLease() }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_400], "the residual this test bounds is gone")
        #expect(await machine.didRestore(fan: 0) == false)

        await machine.watchdog.cycle()

        #expect(
            await machine.didRestore(fan: 0),
            "a fan re-asserted under a lease that lapsed mid-write was never handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.commandedRPMs == [2_400], "the lapsed fan was re-asserted again")
        #expect(machine.safetyLog.lines(containing: "no live lease covers it").count == 1)
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

        // Observed rather than awaited directly: `cycle()` runs as its own unstructured
        // task, and `GatedFanStateSensing`'s continuation being cancellation-aware does not
        // by itself help a bare `await sweep.value` here — cancelling *this* test's task
        // (what `.timeLimit` does) never reaches an unrelated `Task { ... }` this test
        // merely joins. `finished(_:_:)` is what makes a mutation that never calls `open()`
        // a red assertion in milliseconds instead of a hang `.timeLimit` can only report on,
        // not end — confirmed against `GatedFanStateSensing.open()` replaced with a no-op:
        // without this, the run recorded the time-limit issue and then never exited.
        let sweep = observing { await machine.watchdog.cycle() }

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
        try await finished("the sequential sweep", sweep)

        #expect(await sensing.controlStateRequests == [0, 1])
        #expect(await sensing.peakOutstanding == 1)
    }
}
