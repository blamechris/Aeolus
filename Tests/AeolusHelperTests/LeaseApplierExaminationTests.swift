import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #383's and #389's acceptance with the real level 6: `LeaseApplier`'s steps land before § 5's
/// examination of a fan or after it, never inside, and its engagements never overlap § 5's
/// re-engage (ADR 0014's #383, A6 and A6 PR-2 amendments).
///
/// `ReclamationExaminationGateTests` held the same orderings with a stand-in for level 6; these run
/// the real one. **Red first:** each is red under the mutation "`apply` skips the gate" — in
/// `LeaseApplier.step`, replace the `guard let pass = await gate.enterForStep(fanAt: index)` and
/// its `defer` with nothing — on its claim, never on a setup wait, because every wait here also
/// ends when the work it waits for finished without the gate. The bypass test is the exception:
/// it bypasses the gate by hand, and its mutation is § 5 excusing a reading.
@Suite("Level 6's steps and § 5's examinations, with the real level 6", .timeLimit(.minutes(1)))
struct LeaseApplierExaminationTests {

    private typealias Gate = ReclamationExaminationGateTests

    // MARK: - #383

    /// **Forward order, with its control.** Fan 0 is held at 2,400. A cycle with nothing landing
    /// judges nothing a reclamation. Then § 5 reads the fan and its lease check is held open, and
    /// level 6 re-applies 2,000: the step waits for the gate, so § 5 judges 2,400 against 2,400,
    /// and the next cycle reads 2,000 against 2,000.
    @Test("A re-apply during the lease check waits, and is not judged a reclamation")
    func aReApplyDuringTheLeaseCheckWaits() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        try await levelSix.apply(fixed((0, 4_400)), under: lease)

        try await finished("the control cycle", observing { await machine.watchdog.cycle() })
        await Gate.expectNotJudgedAReclamation(machine)

        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease check to park") { await hops.isParked })
        let step = observing { try await levelSix.apply(fixed((0, 4_000)), under: lease) }
        #expect(
            await yieldUntil("the step to wait for the gate, or to land without it") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await step.isFinished.isSet
            })
        #expect(await machine.commandedRPMs == [4_400], "the step landed inside the examination")
        await hops.release()
        try await finished("the examination", sweep)
        try await finished("the step", step)

        await Gate.expectNotJudgedAReclamation(machine)
        try await finished("the next cycle", observing { await machine.watchdog.cycle() })
        await Gate.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_400, 4_000], "§ 5 wrote over the step")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)
        #expect(machine.gate.isIdle)
    }

    /// **Reverse order.** Level 6's write to 2,000 has landed and is not yet reported when § 5's
    /// sweep reaches the fan: § 5 waits, and reads the fan only once the step is reported.
    @Test("A step written and not yet reported is not read, and is not judged a reclamation")
    func aStepWrittenAndNotYetReportedIsNotRead() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        try await levelSix.apply(fixed((0, 4_400)), under: lease)
        let readInsideTheStep = Sightings<Bool>()
        let sweeps = Sightings<ObservableWork<Void>>()
        await writes.interfere {
            let afterTheWrite = await machine.attempts.count
            let sweep = observing { await machine.watchdog.cycle() }
            await sweeps.record(sweep)
            _ = await yieldUntil("the examination to wait for the gate, or to end without it") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await sweep.isFinished.isSet
            }
            await readInsideTheStep.record(
                await machine.attempts.dropFirst(afterTheWrite).contains(.readControlState(fan: 0)))
        }

        try await levelSix.apply(fixed((0, 4_000)), under: lease)
        let sweep = try #require(await sweeps.seen.first, "the write moment never came")
        try await finished("the examination once the step was reported", sweep)

        #expect(
            await readInsideTheStep.seen == [false],
            "§ 5 read the fan between the write and its report")
        await Gate.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_400, 4_000], "§ 5 re-asserted the old target")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)
    }

    /// **The first step after registration.** Fan 0 is engaged and registered, and its first
    /// command is still to come, when § 5's sweep reaches it: § 5 waits for the gate, and judges
    /// the 2,400 the step wrote against the 2,400 it reported. Without the gate it would read the
    /// target the fan held before the step, 1,800, and judge it against a report that landed during
    /// its lease check.
    @Test("A first step after registration is not judged a reclamation")
    func aFirstStepAfterRegistrationIsNotJudged() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true, parkingSafetyHops: true)
        let hops = try #require(machine.leaseHops)
        let ledgerHops = try #require(machine.ledgerHops)
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        await ledgerHops.parkNext(.clearReclaimed)

        let step = observing { try await levelSix.apply(fixed((0, 4_400)), under: lease) }
        #expect(
            await yieldUntil("the registration's clear to park") { await ledgerHops.isParked })
        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the examination to wait for the gate, or to reach its lease check") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await hops.isParked
            })
        await ledgerHops.release()
        try await finished("the first step", step)
        #expect(await yieldUntil("the examination's lease check to park") { await hops.isParked })
        await hops.release()
        try await finished("the examination", sweep)

        await Gate.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_400])
        #expect(machine.gate.isIdle)
    }

    /// **#383's ramp item, held as eleven re-applies.** A6 builds no loop that steps on its own,
    /// so a `fanctl set` from the 50 % point to 100 percent is eleven re-applies 200 RPM apart,
    /// each landing while § 5 holds the fan in its lease check: phase-locked to the sweep, the
    /// worst phase there is. None is judged a reclamation and the terminal action never comes;
    /// without the gate the budget is spent by the fourth and the lease is revoked mid-ramp. It
    /// was thirteen from 3,177 RPM until #670 held every target at or above 3,563.5.
    @Test("Eleven re-applies phase-locked to § 5's sweep never reach the terminal action")
    func elevenPhaseLockedReAppliesNeverReachTheTerminalAction() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        var rpm = 3_577.0
        try await levelSix.apply(fixed((0, rpm)), under: lease)

        var refused: [String] = []
        for _ in 1...11 {
            rpm += 200
            await hops.parkNextAnswer()
            let sweep = observing { await machine.watchdog.cycle() }
            // Or the sweep ended without one: with the lease revoked, § 5 holds nothing to examine.
            _ = await yieldUntil("the lease check to park, or the sweep to find nothing") {
                if await hops.isParked { return true }
                return await sweep.isFinished.isSet
            }
            let target = rpm
            let step = observing { try await levelSix.apply(fixed((0, target)), under: lease) }
            _ = await yieldUntil("the re-apply to wait for the gate, or to land without it") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await step.isFinished.isSet
            }
            await hops.release()
            try await finished("the examination", sweep)
            do {
                try await finished("the re-apply to \(target)", step)
            } catch {
                refused.append("\(target): \(error)")
            }
        }

        #expect(await machine.didRestore(fan: 0) == false, "the terminal action ran mid-ramp")
        #expect(await machine.restorer.causes.isEmpty, "a lease was revoked mid-ramp")
        #expect(refused.isEmpty, "a re-apply was refused: \(refused)")
        await Gate.expectNotJudgedAReclamation(machine)
        let ramp = Array(stride(from: 3_577.0, through: 5_777, by: 200))
        #expect(await machine.commandedRPMs == ramp)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 5_777)
    }

    /// **A level-6 write that bypasses the gate costs a false divergence at most.** Fan 0 holds
    /// level 6's 2,400, and a write and report of 2,600 are made around the gate by hand, with the
    /// writer and the report level 6 uses, inside § 5's lease check. § 5 judges the 2,400 it read
    /// against the 2,600 recorded: a false fault, a mark and one spent attempt, and the re-assert
    /// writes the record's own 2,600, never a target level 6 did not report.
    ///
    /// **Mutation:** in `ReclamationWatchdog.primaryDivergence(of:against:)`, answer `nil` for a
    /// target that diverged, an excuse. Run: red, nothing re-asserted while § 5 records a target
    /// the fan is not holding.
    @Test("A write around the gate costs a false divergence at most")
    func aWriteAroundTheGateCostsAFalseDivergenceAtMost() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let levelSix = machine.levelSix()
        let lease = try await machine.lease(fans: [0]).id
        try await levelSix.apply(fixed((0, 4_400)), under: lease)

        try await Self.writeAroundTheGate(4_600, in: machine, by: levelSix, under: lease)

        #expect(machine.safetyLog.levels(containing: Gate.detected) == [.fault])
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 4600 RPM, attempt 1 of").count == 1)
        #expect(await machine.commandedRPMs == [4_400, 4_600, 4_600])
        #expect(
            await machine.didRestore(fan: 0) == false, "one false fault reached the terminal action"
        )
    }

    /// **A level-6 write that bypasses the gate never makes § 5 hold the system's target.** The
    /// firmware keeps the 1,800 the system chose and discards every target written, level 6's and
    /// § 5's: Aeolus's 2,400 is recorded, and then 2,600 is written and reported around the gate
    /// inside § 5's lease check. § 5 judges 1,800 against 2,600, marks the fan and re-asserts
    /// 2,600, and the record is never the system's target.
    ///
    /// **Mutation:** the excuse above. Run: red, § 5 holding a fan whose firmware is at the
    /// system's 1,800 as though it held 2,600.
    @Test("A write around the gate never makes § 5 hold the system's target")
    func aWriteAroundTheGateNeverHoldsTheSystemsTarget() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(targetWrites: .reverted)], fans: [0: .automatic(at: 1_800)],
            parkingLeaseHops: true)
        let levelSix = machine.levelSix()
        let lease = try await machine.lease(fans: [0]).id
        try await levelSix.apply(fixed((0, 4_400)), under: lease)

        try await Self.writeAroundTheGate(4_600, in: machine, by: levelSix, under: lease)

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "§ 5 judged the system's target held")
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 4600 RPM, attempt 1 of").count == 1)
        #expect(await machine.commandedRPMs.allSatisfy { $0 != 1_800 })
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_600)
    }

    /// Writes `rpm` with level 6's writer and reports it, outside the gate, while § 5's sweep holds
    /// fan 0 in its lease check: the contract breach the bypass tests are about.
    private static func writeAroundTheGate(
        _ rpm: Double, in machine: ReclamationMachine<ScriptedControlPlane>,
        by levelSix: LevelSix<ScriptedControlPlane>, under lease: UUID
    ) async throws {
        let hops = try #require(machine.leaseHops)
        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease check to park") { await hops.isParked })
        let permit = try commandableFan(0, declaring: .automatic(at: 1_800))
        let written = try await levelSix.writer.hold(rpm, of: permit)
        await machine.watchdog.commandedTarget(written, under: lease)
        await hops.release()
        try await finished("the examination around the bypass", sweep)
    }

    // MARK: - #389

    /// **#389.** § 5's re-assert is re-engaging fan 0 under the lease and waits for the yield
    /// between its first and second steps, holding the fan's gate. A same-lease `apply` of fan 0
    /// arrives then: it waits for the gate, so neither engagement undoes the other. § 5 finishes,
    /// writes 2,400 and says so, and no line says nothing was written; then level 6's engagement
    /// finds the fan already in manual, refuses it `.notAutomatic` having written nothing, and
    /// answers `.foreignManualControl` (row 7).
    ///
    /// The § 5 record level 6 does not count as engaged is built by the fixture, as an earlier
    /// apply's undo would leave it. Without the gate, level 6's engagement lands inside § 5's yield
    /// wait, § 5's next step is admitted as a first step and refused, its driver hands the fan
    /// back, and § 5 logs the stand-down that says it wrote nothing.
    @Test("A same-lease engagement during § 5's yield wait waits, and neither undoes the other")
    func aSameLeaseEngagementDuringTheYieldWaitWaits() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], unlock: .heldUntilForced(stepsToYield: 0))
        let sectionFive = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sectionFive)
        try await machine.hold(fan: 0, commanding: 4_400)
        let lease = try await machine.leaseID()
        let levelSix = machine.levelSix(writingThrough: plane)
        let applied = Sightings<ObservableWork<Void>>()
        let waited = Sightings<Bool>()
        await sectionFive.interfere(beforeEngageStep: 2) {
            let apply = observing { try await levelSix.apply(fixed((0, 4_000)), under: lease) }
            await applied.record(apply)
            _ = await yieldUntil("level 6 to wait for the gate, or to engage without it") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await apply.isFinished.isSet
            }
            await waited.record(machine.gate.waiting(onFan: 0) == 1)
        }

        try await finished("§ 5's re-assert", observing { await machine.watchdog.cycle() })
        let apply = try #require(await applied.seen.first, "§ 5 never reached its second step")
        let answered = await LeaseApplierAnswerTests.answer { try await finished("level 6", apply) }

        #expect(await waited.seen == [true], "level 6 engaged inside § 5's yield wait")
        #expect(
            try await plane.firmwareMode(ofFan: 0) == .manual,
            "an engagement undid the other: the fan is on automatic")
        #expect(machine.safetyLog.lines(containing: "re-asserted 4400 RPM").count == 1)
        #expect(
            machine.safetyLog.lines(containing: "wrote nothing more").isEmpty
                && machine.safetyLog.lines(containing: Gate.leftToItsEngagement).isEmpty,
            "a line said nothing was written when § 5's driver had written and undone")
        #expect(machine.safetyLog.lines(containing: "handed back, and the restore").isEmpty)
        #expect(
            answered as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl))
        #expect(await machine.commandedRPMs == [4_400], "level 6 wrote over § 5's engagement")
    }
}
