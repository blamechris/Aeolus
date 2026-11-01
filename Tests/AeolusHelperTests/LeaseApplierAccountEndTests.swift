import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// When level 6's account of a kept fan ends
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment).
/// A `.handBackRefused` account survives a refusal of the driver's only when the refusal shows the
/// fan untouched and unread, `.failedBeforeFirstWrite`. Every other refusal ends it: the driver's
/// undo landed, the fan read another program's value, or `.superseded`, which also follows an undo
/// that landed. So a later write of the engaged value by another program finds no account, and is
/// someone else's.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`, and each test names the
/// mutation it kills.
@Suite("When level 6's account of a kept fan ends", .timeLimit(.minutes(1)))
struct LeaseApplierAccountEndTests {

    /// Every critical temperature this machine's § 3 reads, cool: its cycles are sighted.
    private static let cool = ["TPD0": 50.0]

    /// **A kept fan whose fresh engagement is handed back loses its account.** Fan 0's restore
    /// landed `F0Md = 0` and its force key's clear was refused, so it is kept on automatic. Its
    /// re-apply engages it afresh; the mode write lands, its read-back answers `0`, and the
    /// driver's undo lands: the hand-back returned, so the account ends. In the second case § 3
    /// then cycles, confirms the fan automatic and forgets it. Another program writes the engaged
    /// value, and the next re-apply answers `foreignManualControl`: § 5 holds nothing and no target
    /// is written, and § 3 is not handed a fan it would not bridge.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, throw any other refusal on a `.handBackRefused`
    /// account without ending it, as `5aa58bb` did. Run: red, another program's fan adopted,
    /// registered and commanded.
    @Test(
        "A kept fan whose fresh engagement is handed back loses its account",
        arguments: [false, true])
    func aKeptFanWhoseFreshEngagementIsHandedBackLosesItsAccount(_ sighted: Bool) async throws {
        let kept = try await KeptFan.onAutomatic(temperatures: Self.cool)
        let (machine, plane, levelSix, lease) = (
            kept.machine, kept.machine.plane, kept.levelSix, kept.lease
        )

        await plane.setRawMode(0, ofFan: 0)
        let handedBack = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_000)), under: lease)
        }
        await plane.setRawMode(nil, ofFan: 0)
        #expect(
            handedBack as? AeolusXPCFault
                == .helperFailed(detail: LeaseApplyRules.Detail.notConfirmed),
            "the fresh engagement was answered \(handedBack as Any)")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "the driver's undo")
        if sighted {
            _ = await machine.emergency.cycle()
            #expect(
                await machine.emergency.fansUnderManualControl.isEmpty,
                "§ 3 kept a fan whose hand-back it read back automatic")
        }

        await plane.setMode(.manual, ofFan: 0)
        let writesBefore = await plane.keyWrites.count
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_000)), under: lease)
        }

        #expect(
            reApplied as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "a fan whose hand-back returned was answered \(reApplied as Any)")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await plane.keyWrites.dropFirst(writesBefore).isEmpty, "a target was written")
        if sighted {
            #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        }
    }

    /// **A kept fan whose later step is superseded loses its account.** Fan 0 is kept on automatic
    /// as above, under a two-fan lease. The firmware drops the force key, as a sleep does (U12), so
    /// the re-apply's fresh engagement waits for its yield; during that wait a restore of fan 1 is
    /// requested, so the engagement's next step is `.superseded` and its undo lands. The account
    /// ends, and once another program writes the engaged value the next re-apply is foreign.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, keep the account on `.superseded`, the rule the
    /// correctness review proposed. Run: red, another program's fan adopted and commanded.
    @Test(
        "A kept fan whose later step is superseded loses its account",
        .disabled(
            """
            Unreachable while a lease must cover every fan (#670): the scenario keeps one of two \
            fans after a refused apply, and level 6 now ends that lease whole. Re-enable when \
            run 1d lifts the rule.
            """))
    func aKeptFanWhoseLaterStepIsSupersededLosesItsAccount() async throws {
        let kept = try await KeptFan.onAutomatic(
            of: [0, 1], unlock: .heldUntilForced(stepsToYield: 2))
        let (machine, plane, writes, levelSix, lease) = (
            kept.machine, kept.machine.plane, kept.writes, kept.levelSix, kept.lease
        )

        // The first apply's engagement took four steps; the re-apply's first is the fifth, and
        // the restore of fan 1 lands before its sixth.
        await plane.setForceKey(false)
        await writes.interfere(beforeEngageStep: 6) {
            try? await plane.restoreToAutomatic(.fan(1))
        }
        let superseded = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_000)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(
            superseded as? AeolusXPCFault == .manualControlUnavailable(reason: .releaseInProgress),
            "the superseded engagement was answered \(superseded as Any)")
        #expect(await plane.attempts.filter { $0 == .engageManualControl(fan: 0) }.count == 6)
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "the driver's undo")

        await plane.setMode(.manual, ofFan: 0)
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_000)), under: lease)
        }

        #expect(
            reApplied as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "a fan whose superseded engagement was undone was answered \(reApplied as Any)")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **A kept fan seen holding another value loses its account.** Fan 0 is kept in manual, and
    /// its re-apply reads raw `2`, a value no engagement of Aeolus's writes: someone else's fan,
    /// and the account ends. When raw `1` is read later, with nothing of Aeolus's written since,
    /// it is still someone else's.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, leave the account for a `.notAutomatic` with any
    /// other value. Run: red, the later raw `1` re-adopted and commanded.
    @Test("A kept fan seen holding another value loses its account")
    func aKeptFanSeenHoldingAnotherValueLosesItsAccount() async throws {
        let kept = try await KeptFan.inManual()
        let machine = kept.machine
        await machine.plane.setRawMode(2, ofFan: 0)
        let foreign = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 4_000)), under: kept.lease)
        }
        #expect(
            foreign as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "raw 2 was answered \(foreign as Any)")

        await machine.plane.setRawMode(nil, ofFan: 0)
        let later = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 4_200)), under: kept.lease)
        }

        #expect(
            later as? AeolusXPCFault == .manualControlUnavailable(reason: .foreignManualControl),
            "a fan seen as someone else's was answered \(later as Any)")
        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).isEmpty)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **A kept fan whose first step could not read it keeps its account.** Fan 0 is kept in
    /// manual. Its re-apply's first step finds `F0Md` unreadable and fails before it writes:
    /// `helperFailed`, with no key written, and nothing about the fan learned, so the account
    /// stands. Once the SMC answers again the next re-apply re-adopts the fan and is applied.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, end the account on `.failedBeforeFirstWrite` too,
    /// the rule the completeness review proposed. Run: red, Aeolus's own fan answered
    /// `foreignManualControl` once the SMC recovered.
    @Test("A kept fan whose first step could not read it keeps its account")
    func aKeptFanWhoseFirstStepCouldNotReadItKeepsItsAccount() async throws {
        let kept = try await KeptFan.inManual(
            then: [ScriptedControlPlane.Stage(unreadableModes: [0]), .nominal()])
        let machine = kept.machine
        await machine.plane.advance()
        let writesBefore = await machine.plane.keyWrites.count

        let unread = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 4_000)), under: kept.lease)
        }
        #expect(
            unread as? AeolusXPCFault == .helperFailed(detail: LeaseApplyRules.Detail.unexpected),
            "a re-apply that could not read the fan was answered \(unread as Any)")
        #expect(await machine.plane.keyWrites.dropFirst(writesBefore).isEmpty)

        await machine.plane.advance()
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 4_000)), under: kept.lease)
        }

        #expect(reApplied == nil, "Aeolus's own fan was answered \(reApplied as Any)")
        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }
}
