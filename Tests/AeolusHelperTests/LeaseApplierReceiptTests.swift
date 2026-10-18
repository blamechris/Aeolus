import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What § 5 did with level 6's report, and where level 6 tells it (ADR 0014's A6 PR-2 amendment):
/// `apply` answers applied only for a report § 5 recorded, and the registration and the report are
/// both made under the fan's gate.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`. Each test names the
/// mutation it kills.
@Suite("Level 6 answers applied only for a report § 5 recorded", .timeLimit(.minutes(1)))
struct LeaseApplierReceiptTests {

    // MARK: - The receipt

    /// **`.notHeld`.** Fan 0 is held at 2,400 under the lease. A re-apply's write to 3,000 lands,
    /// and before it is reported the fan is restored and § 5 told it was released, as a teardown
    /// would: § 5 answers the report `.notHeld`, so the re-apply is refused `.releaseInProgress`
    /// rather than answered applied for a fan nothing watches. The fan has left the engaged set:
    /// the next `apply` engages it again, and is applied.
    ///
    /// **Mutation:** in `LeaseApplier.step`, ignore the receipt (`_ = await
    /// reclamation.commandedTarget(commanded, under: lease)`). Run: red, the re-apply answered
    /// applied. **Mutation:** delete the `.notHeld` case's `engagements.remove`. Run: red, the next
    /// `apply` writes to the automatic fan without engaging it.
    @Test("A report § 5 no longer holds is refused, and the fan leaves the engaged set")
    func aReportSectionFiveNoLongerHoldsIsRefused() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        try await levelSix.apply(fixed((0, 2_400)), under: lease)
        await writes.interfere {
            await machine.plane.setMode(.automatic, ofFan: 0)
            await machine.watchdog.manualControlReleased(fanAt: 0)
        }

        let refused = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 3_000)), under: lease)
        }
        let afterTheRefusal = await machine.attempts.count
        try await levelSix.apply(fixed((0, 2_000)), under: lease)

        #expect(await writes.didFire)
        #expect(
            refused as? AeolusXPCFault == .manualControlUnavailable(reason: .releaseInProgress),
            "the re-apply was answered \(refused as Any)")
        #expect(
            await machine.attempts.dropFirst(afterTheRefusal).contains(
                .engageManualControl(fan: 0)),
            "the next apply did not engage the fan again")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
    }

    /// **`.notHeld` on a fan this `apply` engaged.** § 5 is told fan 0 was released while its
    /// first command write lands, so the report is answered `.notHeld`: the step is refused
    /// `.releaseInProgress`, and the undo still hands the fan back, though the `.notHeld` answer
    /// has already taken it out of the engaged set.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, open the loop with `guard
    /// engagements.account(of: index, under: lease) != nil else { continue }`. Run: red, the fan
    /// left in manual with nothing watching it.
    @Test("A report not held on a newly engaged fan is refused, and the fan is handed back")
    func aReportNotHeldOnANewlyEngagedFanIsHandedBack() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.interfere { await machine.watchdog.manualControlReleased(fanAt: 0) }

        let refused = await LeaseApplierAnswerTests.answer {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400)), under: lease)
        }

        #expect(await writes.didFire)
        #expect(
            refused as? AeolusXPCFault == .manualControlUnavailable(reason: .releaseInProgress),
            "answered \(refused as Any)")
        #expect(await machine.didRestore(fan: 0), "the fan was not handed back")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
    }

    /// **`.refused`.** The write returns 50 RPM, a target no permit can produce: § 5's record
    /// refuses it, so the `apply` answers `helperFailed` and the fan it engaged is undone.
    ///
    /// **Mutation:** in `LeaseApplier.step`, answer `.refused` with `return`. Run: red, applied.
    @Test("A report § 5's record refuses is never answered applied, and the fan is undone")
    func aReportTheRecordRefusesIsNeverApplied() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.misreport(commandedRPM: 50)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.unexpected)
        ) {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400)), under: lease)
        }
        #expect(await machine.didRestore(fan: 0), "the newly engaged fan was not undone")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - Under the gate

    /// **The registration and the report are each made under the fan's gate** (#383: what the
    /// next examination judges against lands where no examination can be inside). A two-fan
    /// `apply` through a witness that records `gate.isHeld(fanAt:)` at each call level 6 makes on
    /// § 5.
    ///
    /// **Mutation:** in `LeaseApplier.step`, insert `gate.leave(pass)` between `hold` and the
    /// report. Run: red, "report 0: false" and "report 1: false".
    @Test("The registration and the report are made under the fan's gate")
    func theRegistrationAndTheReportAreUnderTheGate() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let witness = GateWitnessRole(machine.watchdog, gate: machine.gate)
        let levelSix = machine.levelSix(writingThrough: machine.plane, reclamation: witness)

        try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)

        let seen = await witness.seen
        #expect(
            seen == ["register 0: true", "report 0: true", "register 1: true", "report 1: true"],
            "the witness saw \(seen)")
        #expect(machine.gate.isIdle)
    }
}

/// § 5 as level 6 sees it, recording whether the fan's gate is held at each call level 6 makes.
/// The registration and the hand-back go on to the watchdog. The report does not: the role's
/// report is synchronous on its conformer, so this answers `.recorded` itself, and a scenario
/// through it judges where each call was made, not what § 5 made of it.
private actor GateWitnessRole: ReclamationRegistrationRole {
    private let watchdog: ReclamationWatchdog<ScriptedControlPlane>
    private let gate: FanExaminationGate
    private(set) var seen: [String] = []

    init(_ watchdog: ReclamationWatchdog<ScriptedControlPlane>, gate: FanExaminationGate) {
        self.watchdog = watchdog
        self.gate = gate
    }

    func manualControlEngaged(_ fan: CommandableFan, under lease: UUID) async throws {
        seen.append("register \(fan.index): \(gate.isHeld(fanAt: fan.index))")
        try await watchdog.manualControlEngaged(fan, under: lease)
    }

    func commandedTarget(_ commanded: CommandedTarget, under lease: UUID) -> ReportReceipt {
        seen.append("report \(commanded.fanIndex): \(gate.isHeld(fanAt: commanded.fanIndex))")
        return .recorded
    }

    func manualControlHandedBack(fanAt index: Int, under lease: UUID) async {
        seen.append("hand-back \(index): \(gate.isHeld(fanAt: index))")
        await watchdog.manualControlHandedBack(fanAt: index, under: lease)
    }
}
