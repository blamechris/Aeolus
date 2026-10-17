import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What the undo leaves in the engaged set (ADR 0014's A6 PR-2 amendment): a fan whose hand-back
/// returned leaves it, so the next `apply` engages it again; a fan whose hand-back the firmware
/// refused stays, so the next `apply` under the lease puts it back under § 5's watch without
/// engaging it again, and the refusal is said at `.fault`.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`. Each test names the
/// mutation it kills.
@Suite("Level 6's undo and the engaged set", .timeLimit(.minutes(1)))
struct LeaseApplierHandBackTests {

    /// What `controlLoopHandBackRefused(fan:detail:)` says for fan 0.
    private static let handBackRefused = "Could not hand fan 0 back after level 6's apply"

    /// **A hand-back that returned.** Fan 1's command is refused and the undo hands fans 0 and 1
    /// back. A retry of fan 0 under the same lease engages it again, and is applied with the fan
    /// in manual.
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
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        await machine.plane.advance()
        let afterTheRefusal = await machine.attempts.count

        try await levelSix.apply(fixed((0, 2_400)), under: lease)

        #expect(
            await machine.attempts.dropFirst(afterTheRefusal).contains(
                .engageManualControl(fan: 0)),
            "the retry did not engage the fan the undo handed back")
        #expect(
            try await machine.plane.firmwareMode(ofFan: 0) == .manual,
            "the retry was answered applied while fan 0 is on automatic control")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
    }

    /// **A hand-back the firmware refused.** Fan 0 is engaged, its command is refused, and then the
    /// undo's restore is refused too: the fan stays in manual and in the engaged set, and the
    /// refusal is said at `.fault`. Once the firmware takes writes again, a re-apply under the
    /// lease registers it with § 5 and commands it without engaging it again, and is applied. The
    /// refused `apply`'s own line never says that fan was handed back.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, delete the `continue` after a refused hand-back, so
    /// the fan leaves the engaged set regardless. Run: red, the re-apply engages a fan already in
    /// manual and is answered `.foreignManualControl`. **Mutation:** delete the
    /// `controlLoopHandBackRefused` call. Run: red on the `.fault` line.
    @Test("A fan whose hand-back was refused is re-applied without engaging it again")
    func aRefusedHandBackKeepsTheFansAccount() async throws {
        let machine = ReclamationMachine(
            stages: [
                .nominal(targetWrites: .refused(reason: "F0Tg refused")),
                .nominal(writes: .refused(reason: "F0Md refused")), .nominal(),
            ],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .refusedCommandWrite)
        await writes.interfere { await machine.plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual, "the restore landed")
        #expect(machine.safetyLog.levels(containing: Self.handBackRefused) == [.fault])
        let refusal = machine.safetyLog.lines(containing: "Level 6's apply was refused")
        #expect(refusal.count == 1)
        #expect(refusal.allSatisfy { $0.contains("The hand-back of [0] was refused") })
        #expect(refusal.allSatisfy { !$0.contains("were handed back") })
        await machine.plane.advance()
        let afterTheRefusal = await machine.attempts.count

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(
            await machine.attempts.dropFirst(afterTheRefusal).contains(.engageManualControl(fan: 0))
                == false,
            "the re-apply engaged a fan already in manual")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **Residual: a hand-back that threw after the fan's mode write landed.** The fan is engaged
    /// under the force key and its command is refused; the undo's restore lands `F0Md = 0`, and
    /// then the force key's clear is refused, so the hand-back throws with the fan on automatic.
    /// The fan is kept in the engaged set all the same, so the next re-apply registers and commands
    /// it without engaging it, and is answered applied on an automatic fan. That lasts one § 5
    /// cycle, which marks the fan reclaimed by the system, spends an attempt and re-asserts the
    /// reported target, and the fan ends in manual at it. This pins the accepted one-cycle cost,
    /// and its self-correction; it is not a fix (ADR 0014's A6 PR-2 amendment, "What remains").
    ///
    /// **Mutation:** in `ReclamationWatchdog.diverged`, delete the `reassert` call, the attempt
    /// still spent. Run: red on the self-correction, the fan left on automatic.
    @Test("Residual: a fan kept after a landed mode write is applied on automatic for one cycle")
    func aKeptFanAfterALandedModeWriteSelfCorrectsInOneCycle() async throws {
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
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "the mode write did not land")
        #expect(machine.safetyLog.levels(containing: Self.handBackRefused) == [.fault])
        await plane.advance()
        let afterTheRefusal = await machine.attempts.count

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }
        let reApply = await machine.attempts.dropFirst(afterTheRefusal)
        let modeAfterTheReApply = try await plane.firmwareMode(ofFan: 0)
        try await finished("§ 5's cycle", observing { await machine.watchdog.cycle() })

        // The residual: applied, on an automatic fan, with nothing engaged.
        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(reApply.contains(.engageManualControl(fan: 0)) == false)
        #expect(modeAfterTheReApply == .automatic)
        // Its one cycle: a false mark and a spent attempt, then the re-assert.
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(machine.safetyLog.lines(containing: "Reclamation detected on fan 0").count == 1)
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2000 RPM, attempt 1 of").count == 1,
            "§ 5 did not re-assert the reported target")
        #expect(
            try await plane.firmwareMode(ofFan: 0) == .manual,
            "the fan was left on automatic after § 5's cycle")
        #expect(await machine.commandedRPMs.last == 2_000)
    }
}
