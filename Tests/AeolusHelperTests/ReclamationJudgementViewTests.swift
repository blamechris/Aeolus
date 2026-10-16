import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5 judges a reading against every target the fan could have been holding while the
/// examination was suspended, never against one reported after the read alone
/// ([#383](https://github.com/blamechris/Aeolus/issues/383)).
///
/// Each scenario lands an ordinary same-lease step — announce, write through level 6's real
/// `GovernedFanWriter` straight to the plane, report — around § 5's control-state read, the way
/// level 6's `apply` and a curve loop will (ADR 0014 A6 item 3). Every seam suspends; none
/// sleeps.
///
/// What each pins, against the mutation it kills. The value half is
/// `ReclamationJudgementViewValueTests`, which kills M1–M3, M5–M11 and M13 as well. #390's
/// announcement credit and held judgement are `ReclamationAnnouncementCreditTests`.
///
/// - **M1**, the stamp's target dropped from `HeldFan.holds(_:readFrom:)`: T1, T4.
/// - **M2**, the announced step dropped from it: T2.
/// - **M3**, `Registry.announce(_:)` recording nothing: T2.
/// - **M4**, the `isHeld(_:under:)` guard removed from `commandAnnounced(_:under:)`: T9.
/// - **M5**, a report leaving the announcement open: the value suite only, since every actor
///   scenario that announces either reports the same target or announces again before the next
///   cycle.
/// - **M6**, `examinedCommanded` stamped only once: T4.
/// - **M7**, the "began with nothing commanded" excuse deleted: T5.
/// - **M8**, the excuse widened past `.targetDiverged`: the value suite only, because
///   `primaryDivergence(of:against:)` refuses a reclaimed mode per candidate, downstream of it.
/// - **M9**, the issue's third option: stand down whenever the target moved since the stamp: T2,
///   T6, T8.
/// - **M10**, any reading between the stamp's target and the record's accepted: T2, T6.
/// - **M11**, the issue's second option as worded: judge against the stamp's target alone: T3.
/// - **M13**, M8 with the candidates compared on raw RPM: T7.
/// - **M14**, `Registry.announce(_:)` moving the registration generation, which would stand
///   every re-assert down while a step is announced: T10.
///
/// T1, T2, T4 and T5 were red at `main` before #383 (`d7be074`), with the announcements removed so
/// the suite compiled there. T1c, T3, T6, T7, T8 and T9 were green there by design: they pin what
/// the fix must keep. T10 needs the announcement to exist.
@Suite("§ 5 does not judge a step reported around its read a reclamation", .timeLimit(.minutes(1)))
struct ReclamationJudgementViewTests {

    static func permit<Writes>(_ machine: ReclamationMachine<Writes>) throws -> CommandableFan {
        try commandableFan(0, declaring: try #require(machine.fanConditions[0]))
    }

    static func lease<Writes>(_ machine: ReclamationMachine<Writes>) async throws -> UUID {
        try #require(await machine.leases.activeLease()).id
    }

    /// A step as A6 takes one: announce the clamped step, write it through level 6's writer, then
    /// report. A fresh writer, so the step is the clamped goal, the one `permit.target(for:)`
    /// gives; `ReclamationAnnouncementCreditTests` covers a writer mid-ramp.
    static func step<Writes>(
        _ machine: ReclamationMachine<Writes>, to rpm: Double, under lease: UUID,
        permit: CommandableFan, announcing: Bool = true, reporting: Bool = true
    ) async throws -> CommandedTarget {
        let step = permit.target(for: rpm)
        if announcing { await machine.watchdog.commandAnnounced(step, under: lease) }
        let written = try await GovernedFanWriter(plane: machine.plane)
            .command(towards: rpm, of: permit, since: .zero)
        #expect(written.rpm == step.rpm, "the helper announced a step its writer did not write")
        if reporting { await machine.watchdog.commandedTarget(written, under: lease) }
        return written
    }

    /// Runs one cycle with its lease answer held open, and runs `meanwhile` inside it: after the
    /// control-state read, before the judgement.
    static func cycleWithLeaseCheckHeld<Writes>(
        _ machine: ReclamationMachine<Writes>, meanwhile: () async throws -> Void
    ) async throws {
        let hops = try #require(machine.leaseHops)
        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease answer to park") { await hops.isParked })
        try await meanwhile()
        await hops.release()
        try await finished("the examination", sweep)
    }

    /// **T1, #383's acceptance test, the forward order.** The read sees 2,400; the client steps to
    /// 2,000 and reports it while § 5 asks about the lease. Report only, so it ran on `main`.
    @Test("A step reported during the lease check is not a reclamation")
    func aStepReportedDuringTheLeaseCheckIsNotAReclamation() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)], parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            let written = try await GovernedFanWriter(plane: machine.plane)
                .command(towards: 2_000, of: permit, since: .zero)
            await machine.watchdog.commandedTarget(written, under: lease)
        }

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the step was marked")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
        #expect(await machine.commandedRPMs == [2_000], "§ 5 wrote over the step")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
    }

    /// **T1c, the control.** The same examination with no step marks nothing, so T1 cannot pass
    /// for want of an examination.
    @Test("The same examination with no step marks nothing")
    func theSameExaminationWithNoStepMarksNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)], parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)

        try await Self.cycleWithLeaseCheckHeld(machine) {}

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
    }

    /// **T2, the reverse order.** The client announces and writes 2,000 before § 5 reads, and its
    /// report arrives only after the judgement. The read sees 2,000 against a record of 2,400.
    @Test("A step that landed before the read is not a reclamation before its report arrives")
    func aStepThatLandedBeforeTheReadIsNotAReclamation() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        let written = try await Self.step(
            machine, to: 2_000, under: lease, permit: permit, reporting: false)

        await machine.watchdog.cycle()
        await machine.watchdog.commandedTarget(written, under: lease)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the step was marked")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
        #expect(await machine.commandedRPMs == [2_000], "§ 5 re-asserted 2,400 over the step")
    }

    /// **T3.** The report lands inside the read, before the sample: the reading is the new target
    /// and so is the record. Judging against the examination's opening target alone reads it as a
    /// reclamation, which is the issue's second option as it is worded.
    @Test("A step reported before the read's sample is judged against its report")
    func aStepReportedBeforeTheSampleIsJudgedAgainstItsReport() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 2_400)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            _ = try? await Self.step(machine, to: 2_000, under: lease, permit: permit)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the step was marked")
        #expect(await machine.commandedRPMs == [2_000])
    }

    /// **T4.** The firmware discards the client's step. The cycle it was reported inside cannot
    /// tell a discarded write from one not yet landed; the next cycle can, and must.
    @Test("A step the firmware discards is a reclamation on the next cycle")
    func aDiscardedStepIsAReclamationOnTheNextCycle() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 2_400)],
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            _ = try await Self.step(machine, to: 2_000, under: lease, permit: permit)
        }
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the discarded step was excused again")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").count == 1)
    }

    /// **T5.** Nothing was commanded when the examination began, and the first step is reported
    /// during it. The read predates the step, and a fan with nothing commanded has no target to
    /// judge.
    @Test("A first step reported during the examination is not a reclamation")
    func aFirstStepReportedDuringTheExaminationIsNotAReclamation() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_350)], parkingLeaseHops: true)
        try await machine.holdWithoutCommanding(fan: 0)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            _ = try await Self.step(machine, to: 2_000, under: lease, permit: permit)
        }

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the first step was marked")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").isEmpty)
    }

    /// **T6, a genuine reclamation is not excused by a step.** The system holds 2,200, between the
    /// opening 2,400 and the step's 2,000, and the client's write is discarded.
    @Test("A system target is a reclamation though a step is reported during the examination")
    func aSystemTargetIsAReclamationThoughAStepIsReported() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 2_200)],
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            _ = try await Self.step(machine, to: 2_000, under: lease, permit: permit)
        }

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "a step excused the system's target")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected").count == 1)
    }

    /// **T7.** The mode half is never excused: a fan on automatic control has been taken back,
    /// whatever was reported, even with its target still reading the one the examination began
    /// with.
    @Test("A reclaimed mode is a reclamation though a step is reported during the examination")
    func aReclaimedModeIsAReclamationThoughAStepIsReported() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 2_400)], parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            await machine.watchdog.commandAnnounced(permit.target(for: 2_000), under: lease)
            await machine.watchdog.commandedTarget(
                CommandedTarget(fanIndex: 0, rpm: 2_000), under: lease)
        }

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "a step excused a reclaimed mode")
    }

    /// **T8, the contest stays bounded.** The firmware discards every target write. A client that
    /// steps inside every examination still meets the terminal action on the cycle after the
    /// budget is spent (#180, #366).
    @Test("A client stepping inside every examination does not postpone the terminal action")
    func aClientSteppingEveryCycleDoesNotPostponeTheTerminalAction() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .held(at: 1_800)],
            parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        for cycle in 0...ReclamationLimits.reassertAttemptBudget {
            #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
            try await Self.cycleWithLeaseCheckHeld(machine) {
                let rpm = 2_000 + Double(cycle) * 100
                _ = try await Self.step(machine, to: rpm, under: lease, permit: permit)
            }
        }

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "a client stepping every cycle postponed the terminal action")
    }

    /// **T9.** An announcement is believed only under the lease the record was registered under.
    @Test("An announcement under another lease excuses nothing")
    func anAnnouncementUnderAnotherLeaseExcusesNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        _ = try await Self.step(
            machine, to: 2_000, under: UUID(), permit: permit, reporting: false)

        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "another lease's step was excused")
    }

    /// **T10, an announcement moves no generation.** A registration under the same lease during
    /// the examination stands its re-assert down (#381); an announcement must not, or a client
    /// announcing a step every cycle would stand § 5 down on every one. The system holds 1,800
    /// against a record of 2,400, and a step to 2,000 is announced while § 5 asks about the lease
    /// and not yet written: the re-assert still writes 2,400.
    @Test("An announcement during the examination does not stand the re-assert down")
    func anAnnouncementDoesNotStandTheReassertDown() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)], parkingLeaseHops: true)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)

        try await Self.cycleWithLeaseCheckHeld(machine) {
            await machine.watchdog.commandAnnounced(permit.target(for: 2_000), under: lease)
        }

        #expect(
            machine.safetyLog.lines(containing: ReclamationReassertViewTests.leftToItsEngagement)
                .isEmpty, "an announcement stood the re-assert down")
        #expect(await machine.commandedRPMs == [2_400], "§ 5 did not re-assert the record's target")
    }
}
