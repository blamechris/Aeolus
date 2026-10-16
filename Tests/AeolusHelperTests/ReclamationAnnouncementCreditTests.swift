import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A hold is settled by the next judged examination (#390). It is vindicated only if it read an
/// announced step that was the record when that examination began; any other held target is
/// barred until an examination converges on the record. A held reading concludes nothing: it
/// neither marks nor clears, and it spends and refills no attempt.
///
/// T17-T23 and the log-line conversion are `ReclamationHoldSettlementTests`.
///
/// - **Q1**, a hold never barred: T11, T12, T13.
/// - **Q3**, the bar lifted by a judgement that holds nothing: T11.
/// - **H**, the first announcement kept over the next: T14.
/// - **E3**, the stamp's target re-taken after the read: T15.
/// - **G**, an announcement admitting any reading between the record and the announced step: T16.
/// - **K**, `.held` concluding as `.converged` does (clears the mark): T11.
@Suite(
    "§ 5 holds a reading once unless the next examination vindicates it", .timeLimit(.minutes(1)))
struct ReclamationAnnouncementCreditTests {

    private typealias View = ReclamationJudgementViewTests

    /// **T11, the § 5 reviewer's PA3.** The system holds 1,800 against a record of 2,400 and
    /// discards target writes. Cycle 1 marks the fan. The lease holder then announces 1,800 and
    /// its write throws, so nothing reports it. The announcement holds one reading, and the mark
    /// stays; the terminal action lands one cycle later than with no announcement, and no later.
    @Test("A step announced and never written holds one reading, and keeps the mark")
    func aStaleAnnouncementHoldsOneReadingAndKeepsTheMark() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        await machine.watchdog.cycle()
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "cycle 1 did not mark the fan")
        await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)

        for _ in 0..<ReclamationLimits.reassertAttemptBudget {
            await machine.watchdog.cycle()
            #expect(await machine.ledger.isReclaimed(fanAt: 0), "K: an announcement cleared it")
            #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
        }
        await machine.watchdog.cycle()

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "Q1: a stale announcement postponed the terminal action by more than a cycle")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").count == 1)
    }

    /// **T12.** As T11, but the lease holder announces 1,800 before every cycle and every write
    /// throws. A fresh announcement lifts no bar.
    @Test("A step announced again before every cycle holds one reading in all")
    func aRenewedAnnouncementRenewsNoCredit() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        for _ in 0...ReclamationLimits.reassertAttemptBudget {
            #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
            await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)
            await machine.watchdog.cycle()
        }
        await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)
        await machine.watchdog.cycle()

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "Q1: renewing the announcement postponed the terminal action")
    }

    /// **T13.** Each cycle the lease holder announces 1,800 but writes and reports another step,
    /// after the judgement: the order in which an announcement holds a reading. A report of a
    /// target other than the one announced confirms nothing.
    @Test("A report of another target does not confirm the announcement")
    func aReportOfAnotherTargetConfirmsNothing() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)

        for cycle in 1...(ReclamationLimits.reassertAttemptBudget + 2) {
            #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
            await machine.watchdog.commandAnnounced(permit.target(for: 1_800), under: lease)
            let written = try await View.step(
                machine, to: 2_000 + Double(cycle) * 100, under: lease, permit: permit,
                announcing: false, reporting: false)
            await machine.watchdog.cycle()
            await machine.watchdog.commandedTarget(written, under: lease)
        }

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "Q1: reports of other targets kept renewing the announcement")
    }

    /// **T14, the next announcement replaces it.** A step announced at 1,900 whose write threw,
    /// then a step to 2,000 announced and landed before the read, with its report still to come.
    @Test("The next announcement replaces one whose write threw")
    func theNextAnnouncementReplacesOneWhoseWriteThrew() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)
        await machine.watchdog.commandAnnounced(permit.target(for: 1_900), under: lease)

        _ = try await View.step(machine, to: 2_000, under: lease, permit: permit, reporting: false)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "H: the first one was kept")
        #expect(await machine.commandedRPMs == [2_000], "§ 5 re-asserted 2,400 over the step")
    }

    /// **T15, the stamp's target is taken before the read's sample.** A step is announced,
    /// written and reported once the read has sampled the fan and before it returns.
    @Test("A step reported once the read has sampled is judged against the stamp's target")
    func aStepReportedAfterTheSampleIsHeldAtTheStamp() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateSampled)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 2_400)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)
        await sensing.interfere { [machine] in
            _ = try? await View.step(machine, to: 2_000, under: lease, permit: permit)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "E3: stamped after the read")
        #expect(await machine.commandedRPMs == [2_000])
    }

    /// **T16, the step and not the goal.** One persistent writer, as level 6 keeps one: at 2,400,
    /// asked for 1,000 over one second, it writes the governed step 2,200. Announced, the step
    /// holds the reading; the goal announced in its place does not.
    @Test("A governed step is held at the step, and not at the goal", arguments: [true, false])
    func aGovernedStepIsHeldAtTheStepAndNotTheGoal(announcingTheStep: Bool) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await View.lease(machine)
        let permit = try View.permit(machine)
        let writer = GovernedFanWriter(plane: machine.plane)
        let first = try await writer.command(towards: 2_400, of: permit, since: .zero)
        await machine.watchdog.commandedTarget(first, under: lease)

        let step = permit.target(for: 2_200)
        let announced = announcingTheStep ? step : permit.target(for: 1_000)
        await machine.watchdog.commandAnnounced(announced, under: lease)
        let stepped = try await writer.command(towards: 1_000, of: permit, since: .seconds(1))
        #expect(stepped.rpm == step.rpm, "the governor no longer steps 2,400 toward 1,000 by 200")
        await machine.watchdog.cycle()

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == !announcingTheStep,
            "G: the reading was judged against something other than the announced step")
    }
}
