import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's `.systemReclaimed` mark around a re-assert
/// ([#366](https://github.com/blamechris/Aeolus/issues/366)): what `FanState.isReclaimedBySystem`
/// says from the cycle § 5 judges a fan diverged to the cycle it reads the target held, or gives
/// the fan up.
///
/// Two rules, each red at `main` before #366:
///
/// - **The mark follows the primary signal.** Every readable cycle whose primary signal converges
///   clears it, `.short` included: reaching the secondary signal means the firmware holds Aeolus's
///   target (#119). Only a cycle converged on both signals used to, so a re-asserted fan still
///   ramping to its target was reported reclaimed for the whole ramp, and for good if it could
///   not reach it.
/// - **A same-lease re-apply mid-episode leaves the mark to the episode.** `HeldFan.judge(_:)`
///   opens the episode on every `.diverged`, before the mark reaches the ledger, and closes it on
///   the next cycle whose primary converges. A registration under the record's own lease while it
///   is open is accepted and clears nothing. It used to clear the mark, and a terminal action that
///   followed gave the fan up with no mark left.
///
/// Three boundaries of those rules were green under their mutations until #384's review, and
/// each now has a test: a cycle that cannot read neither closes the episode nor clears the mark,
/// and a `.short` cycle clears the mark but does not refill the re-assert budget, through a run
/// of them long enough to reach the dwell's report (#386).
///
/// The value half — `episodeInFlight`, and what
/// `Registration.accepted(replacedEndedLease:mayClearTheMark:)` answers — is
/// `ReclamationRegistryTests`. Every test names the mutation it kills, and each was run.
@Suite(
    "§ 5's reclamation mark follows the primary signal, and its episode", .timeLimit(.minutes(1)))
struct ReclamationEpisodeMarkTests {

    /// What `reclamationResolved(fan:)` says when a mark is cleared.
    private static let resolved = "is no longer reported as taken"

    /// What `reclamationMarkLeftToItsEpisode(fan:)` says.
    private static let leftToItsEpisode = "while § 5 is contesting a reclamation of it"

    // MARK: - A re-apply mid-episode

    /// **Demo A.** Fan 0 is commanded 2,400 RPM under L1 and reads automatic, so § 5 marks it
    /// reclaimed and re-asserts. While the re-assert reads the envelope, the holder re-applies
    /// under L1: still live, nothing moved the generation, so the registration is accepted. Then
    /// the envelope fails, which is the terminal action, and it gives the fan up as
    /// `.systemReclaimed`. The mark it keeps (#346) must be there: the re-apply left it to the
    /// episode. Both ways the envelope can fail reach the terminal action.
    ///
    /// **Mutations**, each red on the mark, the "resolved" line and the notice, in both cases:
    /// (a) delete `guard mayClearTheMark else { … }` from `manualControlEngaged(_:under:)`, so the
    /// actor always clears; (b) make `Registry.register` answer `mayClearTheMark: true` always;
    /// (c) delete `episodeInFlight = true` from `HeldFan.judge(_:)`.
    @Test(
        "A same-lease re-apply during the re-assert leaves the mark to the terminal action",
        arguments: ReclamationLeaseIdentityTests.EnvelopeFailure.allCases)
    func aReapplyDuringTheReassertLeavesTheMarkToTheTerminalAction(
        failure: ReclamationLeaseIdentityTests.EnvelopeFailure
    ) async throws {
        let condition: ScriptedControlPlane.FanCondition =
            failure == .implausibleBounds
            ? .init(
                mode: .automatic, targetRPM: 1_800, actualRPM: 1_800,
                minimumRPM: 5_777, maximumRPM: 1_350)
            : .automatic(at: 1_800)
        let plane = ScriptedControlPlane(fans: [0: condition], stages: [.nominal(), .blind()])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, fans: [0: condition], interfering: sensing)
        let lease = try await machine.lease(fans: [0]).id
        let permit = try commandableFan(0, declaring: .held(at: 2_400))
        try await machine.watchdog.manualControlEngaged(permit, under: lease)
        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_400), under: lease)
        await sensing.interfere { [machine] in
            #expect(
                await machine.ledger.isReclaimed(fanAt: 0),
                "the re-apply did not land after § 5 marked the fan")
            do {
                try await machine.watchdog.manualControlEngaged(permit, under: lease)
            } catch {
                Issue.record("the re-apply under the live lease was refused: \(error)")
            }
            if failure == .readFails { await machine.plane.advance() }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.faults.contains { $0.contains("envelope") },
            "the re-assert never failed on its envelope, so the terminal action was not reached")
        #expect(await machine.restorer.causes == [.systemReclaimed], "L1 was not revoked")
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply mid-episode erased the mark the terminal action keeps")
        #expect(machine.safetyLog.lines(containing: Self.resolved).isEmpty)
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEpisode).count == 1)
        #expect(machine.safetyLog.levels(containing: Self.leftToItsEpisode) == [.notice])
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **The one-cycle bound, both ways.** The same re-apply, landing during the re-assert's
    /// envelope read as level 6's `apply` will: it registers fan 0 under L1 and commands 2,400 RPM
    /// itself. Since #381 the registration stands § 5's re-assert down, so the firmware holds the
    /// client's 2,400 RPM, not § 5's, and the fan still turns at 1,800. The re-apply does not clear
    /// the mark early, and the next readable cycle, whose primary converges while the fan is
    /// short, clears it rather than leaving it for the ramp. The attempt the stand-down booked
    /// stays spent and the `.short` cycle does not refill it, so when the system takes the fan
    /// again the re-assert is the second of the budget.
    ///
    /// **Mutations:** (a) the actor always clears, as in demo A: red on the first cycle's mark.
    /// (b) Take `.short` out of the clearing case in `examine(fanAt:)`: red on the second cycle's
    /// mark and its "resolved" line. (c) `registry.refundReassertAttempt(ofFan:)` in the envelope
    /// read's stand-down: red on the third cycle's attempt. (d) The envelope read's re-fetch back
    /// to `isHeld(_:under:)`, which lets the re-assert land: red on the stand-down line.
    @Test("A re-apply mid-episode leaves the mark for exactly one readable cycle")
    func aReapplyMidEpisodeLeavesTheMarkForOneCycle() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id
        let permit = try commandableFan(0, declaring: .held(at: 1_800))
        await sensing.interfere { [machine] in
            await ReclamationReassertViewTests.reapply(
                machine, under: lease, permit: permit, rpm: 2_400)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: "§ 5 found it at its envelope read").count == 1,
            "the re-apply did not stand the re-assert down")
        #expect(await machine.commandedRPMs == [2_400], "the re-assert wrote over the re-apply")
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty)
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply mid-episode cleared the mark before § 5 read the target held")
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEpisode).count == 1)

        await machine.watchdog.cycle()

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "a fan whose target the firmware holds was still reported reclaimed")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)
        #expect(await machine.leases.activeLease()?.id == lease)

        await machine.plane.setMode(.automatic, ofFan: 0)
        await machine.watchdog.cycle()

        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2400 RPM, attempt 2 of").count == 1,
            "the attempt the stand-down spent was given back, or the short cycle refilled it")
        #expect(await machine.commandedRPMs == [2_400, 2_400])
    }

    /// **A blind cycle does not close the episode.** Fan 0 is commanded 2,400 RPM and the
    /// firmware holds 1,800, so § 5 marks it reclaimed and re-asserts, and the re-assert lands.
    /// The next cycle cannot read the fan, and the holder re-applies under L1 after it. No cycle
    /// has read the target held, so the episode is still open and the re-apply clears nothing.
    /// The cycle after reads again, its primary converges while the fan is short, and that clears
    /// the mark.
    ///
    /// **Mutation:** add `episodeInFlight = false` to `HeldFan.recordReadFailure()`. Run: red on
    /// the mark after the re-apply and on its "left to its episode" line. The re-apply on a blind
    /// cycle cleared the mark, so the fan was reported in Aeolus's control on a machine that had
    /// stopped answering.
    @Test("A cycle that cannot read the fan does not close the episode a re-apply defers to")
    func aBlindCycleDoesNotCloseTheEpisode() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .blind(), .nominal()], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id
        let permit = try commandableFan(0, declaring: .held(at: 1_800))
        await machine.watchdog.cycle()
        #expect(await machine.commandedRPMs == [2_400], "the re-assert did not land")
        await machine.plane.advance()
        await machine.watchdog.cycle()
        #expect(
            machine.safetyLog.lines(containing: "could not read fan 0").count == 1,
            "the second cycle read the fan")
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the blind cycle cleared the mark")

        try await machine.watchdog.manualControlEngaged(permit, under: lease)

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply after a blind cycle cleared the mark before § 5 read the target held")
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEpisode).count == 1)
        #expect(machine.safetyLog.lines(containing: Self.resolved).isEmpty)

        await machine.plane.advance()
        await machine.watchdog.cycle()

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "the readable cycle whose primary converged left the mark")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.leases.activeLease()?.id == lease)
    }

    // MARK: - The mark follows the primary signal

    /// **Demo C.** Fan 0 is commanded 2,400 RPM and the firmware holds 1,800, so § 5 marks it
    /// reclaimed and re-asserts. The re-assert lands: `F0Tg` reads 2,400 and the fan still turns
    /// at 1,800, a ramp in flight. The next cycle's primary converges, so the mark goes then, and
    /// the shortfall is reported once, at the dwell, as it always was.
    ///
    /// **Mutation:** take `.short` out of the clearing case in `examine(fanAt:)` — `case
    /// .converged:` clears and `.short` joins `.graced, nil`. Run: red on the second cycle's mark
    /// and on the "resolved" line.
    @Test("A re-asserted fan still ramping to its target is not reported reclaimed")
    func aReassertedFanStillRampingIsNotReportedReclaimed() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.commandedRPMs == [2_400], "the re-assert did not land")

        await machine.watchdog.cycle()
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "a fan whose target the firmware holds was reported reclaimed while it ramped")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)

        for _ in 0..<ReclamationLimits.actualDwellCycles {
            await machine.watchdog.cycle()
        }

        #expect(
            machine.safetyLog.lines(containing: "has turned at").count == 1,
            "the shortfall was not reported once, at its dwell")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)
        #expect(await machine.ledger.causes.isEmpty)
        #expect(await machine.commandedRPMs == [2_400], "a held target was re-asserted again")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.leases.activeLease() != nil)
    }

    /// How the fan reads on every cycle of `aMarkIsClearedOnEveryCycleWhosePrimaryConverges`.
    enum PrimaryConverged: Sendable, CaseIterable {
        /// `F0Tg` holds the commanded 2,400 RPM and the fan turns at 1,000: `.short` every cycle,
        /// with the dwell rising through its report.
        case ramping
        /// `F0Tg` holds 2,400 RPM and the fan turns at it: `.converged` every cycle.
        case held
    }

    /// A mark is put in the ledger before every cycle, up to one past the dwell, as a false one
    /// is (the residual C2, a stale restore landing before a newer lease registers). Every cycle
    /// whose primary converges clears it — the report cycle at the dwell included, which is a
    /// case of its own in `examine(fanAt:)`.
    ///
    /// **Mutations:** (a) delete the clear from the dwell-report case: red at cycle
    /// `actualDwellCycles` only, for `.ramping`. (b) Drop `.converged` from the clearing case:
    /// red on every cycle, for `.held`.
    @Test(
        "A mark is cleared on every cycle whose primary signal converges",
        arguments: PrimaryConverged.allCases)
    func aMarkIsClearedOnEveryCycleWhosePrimaryConverges(
        reading: PrimaryConverged
    ) async throws {
        let condition: ScriptedControlPlane.FanCondition =
            reading == .ramping ? .ramping(target: 2_400, actual: 1_000) : .held(at: 2_400)
        let machine = ReclamationMachine(fans: [0: condition])
        try await machine.hold(fan: 0, commanding: 2_400)
        let cycles = ReclamationLimits.actualDwellCycles + 1

        for cycle in 1...cycles {
            await machine.ledger.markReclaimed(fanAt: 0)
            await machine.watchdog.cycle()
            #expect(
                await machine.ledger.isReclaimed(fanAt: 0) == false,
                "cycle \(cycle) left the mark on a fan whose target the firmware holds")
        }

        #expect(machine.safetyLog.lines(containing: Self.resolved).count == cycles)
        #expect(
            machine.safetyLog.lines(containing: "has turned at").count
                == (reading == .ramping ? 1 : 0))
        #expect(await machine.commandedRPMs.isEmpty, "a held target was re-asserted")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **A cycle that cannot read clears nothing.** Fan 0 is marked and re-asserted, as in demo
    /// C, and every cycle after cannot read it. Up to the blindness threshold those cycles leave
    /// the mark where it was: nothing read in them says who holds the fan.
    ///
    /// **Mutation:** add `await clearReclamationMark(fanAt: index)` before `cycleCouldNotSee` in
    /// `examine(fanAt:)`'s `.failure` case. Run: red on the mark after the first blind cycle.
    @Test("A cycle that cannot read the fan leaves its mark")
    func aCycleThatCannotReadTheFanLeavesItsMark() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .blind()], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.watchdog.cycle()
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "§ 5 never marked the fan")
        await machine.plane.advance()

        for cycle in 1..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
            #expect(
                await machine.ledger.isReclaimed(fanAt: 0),
                "blind cycle \(cycle) cleared the mark on a fan it could not read")
        }

        #expect(
            machine.safetyLog.lines(containing: "could not read fan 0").count == 1,
            "the cycles after the first read the fan")
        #expect(machine.safetyLog.lines(containing: Self.resolved).isEmpty)
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    // MARK: - The budget is the contest's, not the mark's

    /// **A `.short` cycle does not refill the re-assert budget.** The firmware takes fan 0 back
    /// after every re-assert: each re-assert lands, and the cycles after it read the target held
    /// while the fan is still short, `ReclamationLimits.actualDwellCycles` of them so that each run
    /// reaches the dwell's report, as a real spin-up of several seconds does. The system then
    /// takes the fan again. Each run's first `.short` cycle clears the mark, which follows the
    /// primary signal, but only a cycle converged on both signals ends the contest. So after
    /// `reassertAttemptBudget` re-asserts the next reclamation is the terminal action.
    ///
    /// **Mutations**, each in `HeldFan.judge(_:)` after `actualDwellCycles += 1` on `.short`'s
    /// return: (a) `reassertAttempts = 0`; (b) `if actualDwellCycles >= 2 { reassertAttempts = 0
    /// }`, which one `.short` cycle per re-assert left green (#386); (c) `reassertAttempts =
    /// max(0, reassertAttempts - 1)`. Run: red on each, on the restore and on the revocation. The
    /// fan was contested for ever, never given up, and its mark flapped.
    @Test("A cycle that reads the target held while the fan is short does not refill the budget")
    func aShortCycleDoesNotRefillTheReassertBudget() async throws {
        let budget = ReclamationLimits.reassertAttemptBudget
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<budget {
            await machine.plane.setMode(.automatic, ofFan: 0)
            await machine.watchdog.cycle()
            for _ in 0..<ReclamationLimits.actualDwellCycles {
                await machine.watchdog.cycle()
            }
        }

        #expect(await machine.didRestore(fan: 0) == false, "the budget ran out early")
        #expect(await machine.commandedRPMs == Array(repeating: 2_400, count: budget))
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == budget)
        #expect(
            machine.safetyLog.lines(containing: "has turned at").count == budget,
            "a run of short cycles did not reach the dwell's report after every re-assert")

        await machine.plane.setMode(.automatic, ofFan: 0)
        await machine.watchdog.cycle()

        #expect(
            await machine.didRestore(fan: 0),
            "a fan the system took back after every re-assert was contested past the budget")
        #expect(await machine.restorer.causes == [.systemReclaimed], "the lease was not revoked")
        #expect(await machine.commandedRPMs.count == budget)
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }
}
