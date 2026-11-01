import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What the undo leaves on level 6's account (ADR 0014's A6 PR-2 and #410 refused-hand-back
/// amendments): a fan whose hand-back returned leaves it, so the next `apply` engages it again; a
/// fan whose hand-back the firmware refused is kept as one whose hand-back was refused, the refusal
/// is said at `.fault`, and the next `apply` under the lease reads it through the driver instead of
/// assuming where it is. A fan with no account, or one reading another program's value, is
/// `LeaseApplierKeptFanTests`'.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`. Each test names the
/// mutation it kills.
@Suite("Level 6's undo and the engaged set", .timeLimit(.minutes(1)))
struct LeaseApplierHandBackTests {

    /// What `controlLoopHandBackRefused(fan:detail:)` says for fan 0.
    private static let handBackRefused = "Could not hand fan 0 back after level 6's apply"

    /// **A hand-back that returned.** Fan 1's command is refused and the undo hands fans 0 and 1
    /// back. A retry under the same lease, over both fans as an `apply` must be since #670, engages
    /// fan 0 again, and is applied with the fan in manual.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, delete `engagements.remove(index, under: lease)`.
    /// Run: red, the retry writes to the automatic fan without engaging it, and is answered
    /// applied.
    @Test("A retry after a refused apply engages the fan the undo handed back")
    func aRetryAfterARefusedApplyEngagesAgain() async throws {
        let machine = ReclamationMachine(
            stages: [
                .nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused")), .nominal(),
            ],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        await writes.interfere(beforeEngageStep: 2) { await machine.plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        await machine.plane.advance()
        let afterTheRefusal = await machine.attempts.count

        try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)

        #expect(
            await machine.attempts.dropFirst(afterTheRefusal).contains(
                .engageManualControl(fan: 0)),
            "the retry did not engage the fan the undo handed back")
        #expect(
            try await machine.plane.firmwareMode(ofFan: 0) == .manual,
            "the retry was answered applied while fan 0 is on automatic control")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_400)
    }

    /// **A kept fan still in manual is re-adopted, with nothing written.** Fan 0 is engaged,
    /// its command is refused, and then the undo's restore is refused too: the fan stays in manual,
    /// level 6 keeps it as one whose hand-back was refused, and the refusal is said at `.fault`.
    /// The refused `apply`'s own line never says that fan was handed back. Once the firmware takes
    /// writes again, a re-apply runs the driver, whose first step reads raw `1`, the value the
    /// engagement wrote, and refuses `.notAutomatic` with nothing written. Level 6 reads that as
    /// the engagement returning, registers the fan with § 5 and commands it, and is applied (ADR
    /// 0014's #410 refused-hand-back amendment).
    ///
    /// **Mutation:** in `LeaseEngagements.read`, throw the refusal whatever the account, deleting
    /// the re-adoption. Run: red, the re-apply answered `.foreignManualControl`. **Mutation:** in
    /// `LeaseApplier.undo`, `remove` a fan whose hand-back was refused instead of `keep`ing it.
    /// Run: red, the same. **Mutation:** delete the `controlLoopHandBackRefused` call. Run: red on
    /// the `.fault` line.
    @Test("A kept fan still in manual is re-adopted on its re-apply without a mode write")
    func aKeptFanStillInManualIsReAdoptedWithoutAWrite() async throws {
        let kept = try await KeptFan.inManual()
        let machine = kept.machine
        #expect(machine.safetyLog.levels(containing: Self.handBackRefused) == [.fault])
        let refusal = machine.safetyLog.lines(containing: "Level 6's apply was refused")
        #expect(refusal.count == 1)
        #expect(refusal.allSatisfy { $0.contains("The hand-back of [0] was refused") })
        #expect(refusal.allSatisfy { !$0.contains("were handed back") })
        let attemptsBefore = await machine.attempts.count
        let writesBefore = await machine.plane.keyWrites.count

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 4_000)), under: kept.lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(
            await machine.attempts.dropFirst(attemptsBefore).contains(.engageManualControl(fan: 0)),
            "the re-apply did not run the driver for a fan whose hand-back was refused")
        #expect(
            await machine.plane.keyWrites.dropFirst(writesBefore).contains(.mode(fan: 0, value: 1))
                == false,
            "the re-apply wrote the mode of a fan still in manual")
        #expect(machine.safetyLog.levels(containing: KeptFan.reAdopted) == [.notice])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **A kept fan whose restore's mode write landed is engaged again.** The fan is engaged
    /// under the force key and its command is refused; the undo's restore lands `F0Md = 0`, and
    /// then the force key's clear is refused, so the hand-back throws with the fan on automatic and
    /// level 6 keeps it as one whose hand-back was refused. The next re-apply runs the driver,
    /// whose first step reads raw `0`: it engages the fan afresh, writing `F0Md = 1`, and is
    /// answered applied with the fan in manual. § 5's next cycle finds it converged: no mark, no
    /// reclamation line, and no attempt spent. Until the #410 refused-hand-back amendment this
    /// re-apply skipped the driver and was answered applied on an automatic fan for one § 5 cycle,
    /// which marked the fan reclaimed by the system and spent an attempt.
    ///
    /// **Mutation:** in `LeaseApplier.step`, skip the driver for `.handBackRefused` as for
    /// `.engaged`. Run: red, no engagement, the fan applied on automatic, and § 5's false mark.
    @Test("A kept fan whose restore's mode write landed is engaged again on its re-apply")
    func aKeptFanWhoseModeWriteLandedIsEngagedAgain() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [0: .automatic(at: 1_800)]
        let plane = ScriptedControlPlane(
            fans: fans,
            stages: [
                .nominal(targetWrites: .refused(reason: "F0Tg refused")),
                .nominal(forceKeyWrites: .refused(reason: "Ftst refused")), .nominal(),
            ],
            unlock: .heldUntilForced(stepsToYield: 0))
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(plane, during: .refusedCommandWrite)
        await writes.interfere { await plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 4_400)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "the mode write did not land")
        #expect(machine.safetyLog.levels(containing: Self.handBackRefused) == [.fault])
        await plane.advance()
        let attemptsBefore = await machine.attempts.count
        let writesBefore = await plane.keyWrites.count

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_000)), under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(
            await machine.attempts.dropFirst(attemptsBefore).contains(.engageManualControl(fan: 0)),
            "the re-apply did not run the driver for a fan whose hand-back was refused")
        #expect(await plane.keyWrites.dropFirst(writesBefore).contains(.mode(fan: 0, value: 1)))
        #expect(
            try await plane.firmwareMode(ofFan: 0) == .manual,
            "the re-apply was answered applied while fan 0 is on automatic control")
        let beforeTheCycle = await machine.attempts.count

        try await finished("§ 5's cycle", observing { await machine.watchdog.cycle() })

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "§ 5 marked the fan reclaimed")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected on fan 0").isEmpty)
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty, "§ 5 spent an attempt")
        #expect(
            KeptFan.writes(in: await machine.attempts.dropFirst(beforeTheCycle)).isEmpty,
            "§ 5's cycle wrote to a fan that was holding its target")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)
    }
}
