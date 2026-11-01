import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Which refused engagements open level 6's account of a fan
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment).
/// The line is a write **issued**, not one that landed: an engagement that issued a write is
/// undone, a refused mode write included, and a refused undo of it keeps the fan. A first step that
/// failed before it issued any write is neither undone nor kept, so the raw value alone never makes
/// the fan Aeolus's.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`, and each test names the
/// mutation it kills.
@Suite("Level 6 keeps a fan only when its engagement issued a write", .timeLimit(.minutes(1)))
struct LeaseApplierIssuedWriteTests {

    /// **A first step that wrote nothing opens no account.** Fan 0 is leased on automatic; then its
    /// `F0Md` stops answering and the firmware refuses writes, as a connection gone stale would
    /// (#68). The first step fails before it issues any write, so the driver neither undoes nor
    /// registers the fan, and level 6 opens no account: no `F0Md` write either way, no refused-undo
    /// line, and § 3 holds nothing. Another program then takes the fan, and the re-apply answers
    /// `foreignManualControl`, registering and writing nothing.
    ///
    /// **Mutation:** drop `.failedBeforeFirstWrite` from `EngagementDriver.wroteNothing`. Run: red,
    /// the refused undo kept the fan and the re-apply adopted another program's. **Mutation:** in
    /// `ScriptedControlPlane.unlockStep`, rethrow the pre-state read's `.readFailed` as it is. Run:
    /// red, the same.
    @Test("A first step that wrote nothing opens no account, and the fan stays someone else's")
    func aFirstStepThatWroteNothingOpensNoAccount() async throws {
        let machine = ReclamationMachine(
            stages: [
                .nominal(),
                ScriptedControlPlane.Stage(
                    writes: .refused(reason: "the SMC refused"), unreadableModes: [0]),
                .nominal(),
            ],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        await machine.plane.advance()

        let first = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }

        #expect(
            first as? AeolusXPCFault == .helperFailed(detail: LeaseApplyRules.Detail.unexpected),
            "answered \(first as Any)")
        let written = await machine.plane.keyWrites
        #expect(written.isEmpty, "a fan whose mode was never read was written: \(written)")
        #expect(machine.safetyLog.lines(containing: EngagementUndoRefusedTests.undoRefused).isEmpty)
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)

        await machine.plane.advance()
        await machine.plane.setMode(.manual, ofFan: 0)
        let writesBefore = await machine.plane.keyWrites.count
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(
            reApplied as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "another program's fan was answered \(reApplied as Any)")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(
            await machine.plane.keyWrites.dropFirst(writesBefore).isEmpty,
            "another program's fan was written")
    }

    /// Where a read-back fails after its mode write: on the first step itself, or on a later one.
    enum LostReadBack: String, CaseIterable, Sendable {
        /// `.naive`: the first step's own read-back, through `failNextReadBack(ofFan:)`.
        case firstStep
        /// `.heldUntilForced(stepsToYield: 1)`: the yield's step, on a stage whose `F0Md` does not
        /// answer.
        case laterStep
    }

    /// **A read-back that fails after its mode write keeps the account.** Fan 0's mode write lands,
    /// its read-back does not answer, and the firmware then refuses the driver's undo, so the fan
    /// is in manual and Aeolus's. Level 6 keeps it; once writes are taken again, the re-apply
    /// re-adopts it, and § 3 holds it throughout. The converse of
    /// `aFirstStepThatWroteNothingOpensNoAccount`: only the plane knows whether its failing read
    /// came before its first write.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, do not keep the fan when the wrapper's cause is
    /// `.readFailed`. Run: red on both rows, the re-apply answered `.foreignManualControl`.
    /// **Mutation (the first-step row):** in `ScriptedControlPlane.unlockStep`, throw
    /// `.failedBeforeFirstWrite` for a first step's failed read-back too. Run: red on that row, the
    /// fan neither undone nor kept.
    @Test(
        "A read-back that fails after its mode write keeps the account",
        .disabled(
            """
            Unreachable while a refused apply that keeps a fan ends its lease whole (#670): no \
            re-apply follows under that lease, so no kept fan is re-adopted. Re-enable when run \
            1d lifts the rule.
            """),
        arguments: LostReadBack.allCases)
    func aReadBackThatFailsAfterTheModeWriteKeepsTheAccount(_ lost: LostReadBack) async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [0: .automatic(at: 1_800)]
        let refused = ScriptedControlPlane.Stage(writes: .refused(reason: "F0Md refused"))
        let plane: ScriptedControlPlane
        switch lost {
        case .firstStep:
            plane = ScriptedControlPlane(fans: fans, stages: [.nominal(), refused, .nominal()])
            await plane.failNextReadBack(ofFan: 0)
        case .laterStep:
            plane = ScriptedControlPlane(
                fans: fans,
                stages: [
                    .nominal(), ScriptedControlPlane.Stage(unreadableModes: [0]), refused,
                    .nominal(),
                ],
                unlock: .heldUntilForced(stepsToYield: 1))
        }
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(plane, during: .refusedEngageStep)
        await writes.interfere { await plane.advance() }
        if lost == .laterStep {
            await writes.interfere(beforeEngageStep: 3) { await plane.advance() }
        }
        let levelSix = machine.levelSix(writingThrough: writes)

        let first = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }

        #expect(await writes.didFire, "the step was never refused")
        #expect(
            first as? AeolusXPCFault == .helperFailed(detail: LeaseApplyRules.Detail.unexpected),
            "answered \(first as Any)")
        #expect(
            machine.safetyLog.levels(containing: EngagementUndoRefusedTests.undoRefused)
                == [.fault])
        #expect(try await plane.firmwareMode(ofFan: 0) == .manual, "the mode write did not land")

        await plane.advance()
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(reApplied == nil, "Aeolus's own fan was answered \(reApplied as Any)")
        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.emergency.fansUnderManualControl == [0])
    }

    /// **A refused mode write, whose restore is refused too, keeps the account.** The firmware
    /// refuses fan 0's `F0Md = 1` and then the driver's `F0Md = 0`. The write was issued, and its
    /// answer cannot say it did not take effect (#291), so it was undone, § 3 holds the fan, and
    /// the refusal's notice names it as not handed back.
    ///
    /// **Mutation:** count `.firmwareRefusedControl` among the refusals that wrote nothing in
    /// `EngagementDriver.wroteNothing`, the "landed" line. Run: red, no undo, § 3 told nothing and
    /// the notice saying no engagement returned.
    @Test("A refused mode write whose restore is refused keeps the account")
    func aRefusedModeWriteWhoseRestoreIsRefusedKeepsTheAccount() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .refused(reason: "F0Md refused")), .nominal()],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()

        let refused = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }

        #expect(
            refused as? AeolusXPCFault
                == .helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused),
            "answered \(refused as Any)")
        let written = await machine.plane.keyWrites
        #expect(
            written == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)],
            "the refused mode write was not undone: \(written)")
        #expect(await machine.emergency.fansUnderManualControl == [0])
        let notice = machine.safetyLog.lines(containing: "Level 6's apply was refused")
        #expect(notice.count == 1)
        #expect(
            notice.allSatisfy { $0.contains("The hand-back of [0] was refused") },
            "the notice did not name fan 0 as not handed back: \(notice)")
    }
}
