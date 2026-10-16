import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The next judged examination settles every hold (#390). A hold is vindicated only if it read an
/// announced step that was the record when that examination began; any other held target is
/// barred until an examination converges on the record. Each scenario follows A6's contract
/// unless it says otherwise, and every seam suspends.
///
/// - **Q1**, a hold never barred: T17, T18, T19, T23.
/// - **Q3**, the bar lifted by a judgement that holds nothing: T17, T18.
/// - **Q6**, the vindication ignored: T21, T23.
/// - **Q8**, an unvindicated hold refusing every hold of the next examination: T21.
/// - **V**, a hold vindicated by a report of its step rather than by the record at the next
///   stamp, the credit this replaced: T17.
/// - **K**, `.held` concluding as `.converged` does: T17.
/// - **W**, `HeldFan.command(_:)` taking a report no plane can write: T22.
/// - **FMT**, a bare `Int(_:)` conversion restored at any of the seven log sites: the last test.
///
/// T17, both T18 cases, T19 and T22 were red at 94aca31, T22 by crashing the test process; T20
/// and T21 were green there by design, and pin what the bar must leave alone.
@Suite("§ 5 settles each hold at the next examination", .timeLimit(.minutes(1)))
struct ReclamationHoldSettlementTests {

    private typealias View = ReclamationJudgementViewTests
    /// Runs one cycle and says whether the terminal action has come, and whether the fan is marked.
    private static func cycle<Writes>(
        _ machine: ReclamationMachine<Writes>
    ) async -> (terminal: Bool, marked: Bool) {
        await machine.watchdog.cycle()
        return (
            await machine.restorer.causes.contains(.systemReclaimed),
            await machine.ledger.isReclaimed(fanAt: 0)
        )
    }

    /// **T17, Codex's sequence.** The system holds 1,800 against a record of 2,400 and discards
    /// target writes, and cycle 0 marks the fan. Each iteration then announces, writes and
    /// reports 1,800 around the cycle, and then announces, writes and reports 2,400. Every report
    /// truthfully describes a write that returned. The 1,800 hold is not vindicated, because the
    /// next examination begins with 2,400 as the record, so the terminal action lands one
    /// iteration later than with no hold, the mark held throughout.
    @Test("A step reported and then superseded before the next examination is not vindicated")
    func aStepSupersededBeforeTheNextExaminationIsNotVindicated() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)
        #expect(await Self.cycle(machine).marked, "cycle 0 did not mark the fan")

        var outcomes: [(terminal: Bool, marked: Bool)] = []
        for _ in 1...(ReclamationLimits.reassertAttemptBudget + 1) {
            let low = try await View.step(
                machine, to: 1_800, under: lease, permit: permit, reporting: false)
            outcomes.append(await Self.cycle(machine))
            await machine.watchdog.commandedTarget(low, under: lease)
            _ = try await View.step(machine, to: 2_400, under: lease, permit: permit)
        }

        #expect(outcomes.allSatisfy { $0.marked }, "K: a hold cleared the mark")
        #expect(outcomes.dropLast().allSatisfy { !$0.terminal }, "the terminal action came early")
        #expect(outcomes.last?.terminal == true, "V/Q1: the hold renewed itself on its own report")
    }

    /// **T17's pre-mark half.** The same iterations from registration: the first is held, the
    /// second marks the fan, and the terminal action lands one cycle after it would with no hold.
    @Test("Codex's sequence from registration marks the fan on its second cycle")
    func codexSequenceFromRegistrationMarksOnTheSecondCycle() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        var outcomes: [(terminal: Bool, marked: Bool)] = []
        for _ in 1...(ReclamationLimits.reassertAttemptBudget + 2) {
            let low = try await View.step(
                machine, to: 1_800, under: lease, permit: permit, reporting: false)
            outcomes.append(await Self.cycle(machine))
            await machine.watchdog.commandedTarget(low, under: lease)
            _ = try await View.step(machine, to: 2_400, under: lease, permit: permit)
        }

        #expect(outcomes.first?.marked == false, "the first cycle was not held")
        #expect(outcomes.dropFirst().allSatisfy { $0.marked }, "the second cycle was not marked")
        #expect(outcomes.dropLast().allSatisfy { !$0.terminal }, "the terminal action came early")
        #expect(outcomes.last?.terminal == true, "the terminal action was postponed")
    }

    /// **T18, the delta reviewer's P2 and P1, on A6's contract.** Each cycle 1,800 is announced
    /// and its write throws, so it never lands; level 6 then announces, writes and reports another
    /// step: the record's own 2,400 (P2), or a fresh step each cycle (P1).
    @Test(
        "An announced step that never lands holds once, whatever is reported after it",
        arguments: [false, true])
    func anAnnouncedStepThatNeverLandsHoldsOnce(freshSteps: Bool) async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        var outcomes: [(terminal: Bool, marked: Bool)] = []
        for cycle in 1...(ReclamationLimits.reassertAttemptBudget + 2) {
            await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)
            outcomes.append(await Self.cycle(machine))
            let next = freshSteps ? 2_000 + Double(cycle) * 10 : 2_400
            _ = try await View.step(machine, to: next, under: lease, permit: permit)
        }

        #expect(outcomes.dropFirst().allSatisfy { $0.marked }, "Q1: held past the first cycle")
        #expect(outcomes.last?.terminal == true, "Q1/Q3: the terminal action was postponed")
    }

    /// **T19, the stamp's twin.** Each cycle 1,800 is reported before the examination begins and
    /// 2,400 during its lease check, so every reading is the stamp's target. Held once, then
    /// barred.
    @Test("A target reported before every examination and superseded inside it holds once")
    func aStampTargetSupersededInsideEveryExaminationHoldsOnce() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)],
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        for _ in 1...(ReclamationLimits.reassertAttemptBudget + 2) {
            #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
            _ = try await View.step(machine, to: 1_800, under: lease, permit: permit)
            try await View.cycleWithLeaseCheckHeld(machine) {
                _ = try await View.step(machine, to: 2_400, under: lease, permit: permit)
            }
        }

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "Q1: the stamp's target held a system target on every cycle")
    }

    /// **T23, the residual's bound.** The longest run of holds at one system target: 1,800 is
    /// announced and held, reported, so the next examination begins with it as the record and
    /// vindicates it, and 2,400 is reported inside that examination, which holds 1,800 once more
    /// at the stamp's target. Nothing vindicates that, so 1,800 is barred: the fan is marked on the
    /// third cycle and the terminal action comes two cycles later than with no hold.
    @Test("A system target is held by at most two examinations between convergences")
    func aSystemTargetIsHeldAtMostTwice() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)],
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        var marked: [Bool] = []
        for _ in 1...((ReclamationLimits.reassertAttemptBudget + 3) / 2) {
            await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)
            await machine.watchdog.cycle()
            marked.append(await machine.ledger.isReclaimed(fanAt: 0))
            await machine.watchdog.commandedTarget(
                CommandedTarget(fanIndex: 0, rpm: 1_800), under: lease)
            try await View.cycleWithLeaseCheckHeld(machine) {
                _ = try await View.step(machine, to: 2_400, under: lease, permit: permit)
            }
            marked.append(await machine.ledger.isReclaimed(fanAt: 0))
        }

        #expect(marked.prefix(2) == [false, false], "the two holds the rule allows were not held")
        #expect(marked.dropFirst(2).allSatisfy { $0 }, "a third examination was held")
        #expect(await machine.restorer.causes.contains(.systemReclaimed))
    }

    /// **T20, a reverse-phase ramp on A6's contract.** One persistent writer steps 2,400 toward
    /// 1,000 by 200 a cycle; each step lands before the read and is reported after the judgement.
    /// Every reading is held, and each hold is vindicated by the next examination.
    @Test("A ramp whose every step lands before the read is never marked")
    func aReversePhaseRampIsNeverMarked() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)
        let writer = GovernedFanWriter(plane: machine.plane)
        await machine.watchdog.commandedTarget(
            try await writer.command(towards: 2_400, of: permit, since: .zero), under: lease)

        for step in stride(from: 2_200.0, through: 1_400, by: -200) {
            await machine.watchdog.commandAnnounced(permit.target(for: step), under: lease)
            let written = try await writer.command(towards: 1_000, of: permit, since: .seconds(1))
            #expect(written.rpm == step, "the governor no longer steps by 200 a second")
            await machine.watchdog.cycle()
            await machine.watchdog.commandedTarget(written, under: lease)
        }

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "a ramp step was marked")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
        #expect(await machine.commandedRPMs == [2_400, 2_200, 2_000, 1_800, 1_600, 1_400])
    }

    /// **T21, a forward-phase ramp that drifts to reverse and back.** Three steps land after the
    /// read; the fourth before it; the fifth after it again, so that examination reads the step it
    /// held last, vindicated by its report (Q6), and the drift to reverse is held though the hold
    /// before it is barred (Q8).
    @Test("A ramp drifting across the read in either direction is never marked")
    func aRampDriftingAcrossTheReadIsNeverMarked() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)], parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        for step in [2_200.0, 2_000, 1_800] {
            try await View.cycleWithLeaseCheckHeld(machine) {
                _ = try await View.step(machine, to: step, under: lease, permit: permit)
            }
        }
        let reverse = try await View.step(
            machine, to: 1_600, under: lease, permit: permit, reporting: false)
        await machine.watchdog.cycle()
        await machine.watchdog.commandedTarget(reverse, under: lease)
        try await View.cycleWithLeaseCheckHeld(machine) {
            _ = try await View.step(machine, to: 1_400, under: lease, permit: permit)
        }
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "a drifting step was marked")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
        #expect(await machine.commandedRPMs == [2_200, 2_000, 1_800, 1_600, 1_400])
    }

    /// **T22, Codex's second critical.** A report no plane can write leaves the record as it was,
    /// so the next cycle reads the fan holding its target and logs nothing.
    @Test(
        "A report no plane can write leaves the record alone",
        arguments: [Double.nan, .infinity, -.infinity, 0, 50])
    func aReportNoPlaneCanWriteLeavesTheRecordAlone(rpm: Double) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)

        await machine.watchdog.commandedTarget(CommandedTarget(fanIndex: 0, rpm: rpm), under: lease)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "W: the report was recorded")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
    }

    /// Every RPM a § 5 or § 3 line states goes through one total conversion. Each of the seven
    /// sites is reached here with values that `Int(_:)` traps on, so restoring the bare conversion
    /// at any one of them crashes this test. **Mutation:** restore `Int(readBack.rounded())` in
    /// `ReclamationDivergence.summary`; restore it in `reclamationReasserted`. Run: the test
    /// process dies with "Double value cannot be converted to Int".
    @Test("Every RPM in a log line is written out, whatever the value")
    func everyRPMInALogLineIsWrittenOut() {
        #expect(FanControlPlaneValue.wholeRPM(2_400.4) == "2400")
        #expect(FanControlPlaneValue.wholeRPM(.nan) == "NaN")
        #expect(FanControlPlaneValue.wholeRPM(-.infinity) == "-Infinity")
        #expect(FanControlPlaneValue.wholeRPM(1e30) == "1e+30")

        let recorded = RecordedLog()
        let log = SafetyLog(recording: { recorded.append($0, $1) })
        let divergence = ReclamationDivergence.targetDiverged(commanded: .nan, readBack: 1e30)
        log.reclamationDetected(
            fan: 0, divergence: divergence, commanded: CommandedTarget(fanIndex: 0, rpm: .nan))
        log.reclamationFanNotReachingTarget(fan: 0, actual: -1e30, commanded: .nan, dwellCycles: 3)
        log.reclamationReasserted(fan: 0, rpm: .infinity, attempt: 1, budget: 3)
        log.emergencyCommandedMaximum(fan: 0, rpm: .nan)

        #expect(recorded.lines.count == 4)
        #expect(recorded.lines.allSatisfy { $0.contains("NaN") || $0.contains("Infinity") })
        #expect(divergence.summary.contains("1e+30"))
    }
}
