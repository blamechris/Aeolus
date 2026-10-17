import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The rest of `ReclamationReassertViewTests`, added by #381's review: the suspensions the first
/// round's scenarios did not reach — before the re-assert's first step, inside its mode write,
/// with a re-apply's report still to come, and once the control-state read has sampled. Kept out
/// of `ReclamationReassertViewTests.swift`, which would otherwise cross SwiftLint's `file_length`
/// and `type_body_length` warnings, as an extension of the same suite; the mutations each kills are
/// listed with the rest, in that file's header.
extension ReclamationReassertViewTests {

    /// **I, before the first step.** The client re-engages the fan under the same lease, registers
    /// it and commands 2,000 after § 5's envelope re-fetch and before its first engagement step's
    /// turn, where the double's engage-step effect runs (`.reconnect` is never reached here). That
    /// step finds the fan already in manual and is refused `.notAutomatic` with nothing written: it
    /// is the client's engagement, not a failure, so § 5 stands down as at the re-fetches.
    ///
    /// **Mutation:** M9. Run: red on the failed re-engage line and the stand-down line's level. Red
    /// at `b07477b`, before `reengageRefused(fanAt:heldUnder:error:)` existed.
    @Test("A re-engagement before the re-assert's first step stands it down, with no fault")
    func aReengagementBeforeTheFirstStepStandsTheReassertDown() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .reconnect)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere(beforeEngageStep: 1) { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000, engaging: true)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: Self.failedReengage).isEmpty,
            "a failed re-engage was reported for a fan its own lease had re-engaged")
        #expect(machine.safetyLog.levels(containing: Self.leftAtItsFirstStep) == [.notice])
        #expect(await machine.commandedRPMs == [2_000])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(await machine.didRestore(fan: 0) == false, "§ 5 handed back its own lease's fan")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **J, the refusal that stays a fault.** As I, but the fan comes off automatic control with
    /// no registration since the stamp: an engagement that has not registered yet. The step is
    /// refused `.notAutomatic` as in I, and nothing has given the fan to an engagement § 5 knows
    /// of, so it is the `.fault` it always was.
    ///
    /// **Mutation:** M10. Run: red on the failed re-engage line and the stand-down line.
    @Test("A first step refused with no registration since the stamp is still a fault")
    func aFirstStepRefusedWithNoRegistrationIsStillAFault() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .reconnect)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        await sensing.interfere(beforeEngageStep: 1) { [machine] in
            do {
                _ = try await machine.plane.ticketedStep(of: permit)
            } catch {
                Issue.record("the unregistered engagement failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(machine.safetyLog.levels(containing: Self.failedReengage) == [.fault])
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEngagement).isEmpty)
    }

    /// **O, the refusal after a write.** J's other half: here a registration *has* landed since
    /// the stamp — a same-lease re-apply that registers and commands without engaging, before
    /// § 5's first engagement step — and the firmware answers § 5's mode write `0x89` once it is
    /// issued. The driver hands the fan back and throws `firmwareRefusedControl`, not
    /// `.notAutomatic`: a step wrote, so it is the `.fault` it always was, and not the stand-down
    /// the registration would otherwise earn.
    ///
    /// **Mutation:** X2. Run: red on the failed re-engage line's level and the stand-down line.
    @Test("A first step refused after its mode write is still a fault, registration or not")
    func aFirstStepRefusedAfterItsModeWriteIsStillAFault() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], unlock: .answers(code: 0x89))
        let sensing = InterferingFanStateSensing(plane, during: .reconnect)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere(beforeEngageStep: 1) { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            await plane.keyWrites.contains(.mode(fan: 0, value: 1)),
            "§ 5's mode write was never issued, so nothing was written to undo")
        #expect(machine.safetyLog.levels(containing: Self.failedReengage) == [.fault])
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEngagement).isEmpty)
    }

    /// **P, the release before the first step.** I's interleaving with the fan released rather
    /// than registered again: its release notice lands after § 5's envelope re-fetch and before
    /// its first engagement step, and another engagement takes the fan off automatic control
    /// meanwhile. The step is refused `.notAutomatic` with nothing written, and the record is
    /// gone, so § 5 says the fan was released, at `.notice`: neither a failed re-engage nor the
    /// stand-down, whose line claims a same-lease registration that never happened.
    ///
    /// **Mutations:** X3, red on the released line and the stand-down line. M9, red on the
    /// released line and the failed re-engage line.
    @Test("A fan released before the re-assert's first step is reported released, not failed")
    func aFanReleasedBeforeTheFirstStepIsReportedReleased() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .reconnect)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        await sensing.interfere(beforeEngageStep: 1) { [machine] in
            await machine.watchdog.manualControlReleased(fanAt: 0)
            do {
                _ = try await machine.plane.ticketedStep(of: permit)
            } catch {
                Issue.record("the other engagement failed: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.levels(containing: "was released during its first step") == [.notice])
        #expect(
            machine.safetyLog.lines(containing: Self.failedReengage).isEmpty,
            "a failed re-engage was reported for a released fan")
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEngagement).isEmpty)
    }

    /// **F, the re-fetch after the mode write.** C, one suspension later and on the mode half: the
    /// system took fan 0, and a target reported with no registration lands while § 5's own mode
    /// write is in flight, the re-assert's longest suspension. § 5 re-engages and re-asserts, but
    /// the record's target as it stands after that write, not the one its envelope re-fetch saw.
    ///
    /// **Mutation:** M11. Run: red on the commanded targets and the firmware's target.
    @Test("A target reported during the re-assert's mode write is the one re-asserted")
    func aTargetReportedDuringTheModeWriteIsTheOneReasserted() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(
                machine, under: lease, permit: permit, rpm: 2_000, registering: false)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_000, 2_000], "the stale target was re-asserted")
        #expect(try await Self.firmwareTarget(machine) == 2_000)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
    }

    /// **K, the budget at the mode write.** E, one suspension later: the system took fan 0, the
    /// firmware discards every target write, and a re-apply registers under the same lease while
    /// § 5's first re-assert's mode write is in flight. That engagement's writes are that round's,
    /// so the attempt stays spent here too: the next re-assert is the second, and the terminal
    /// action comes on the cycle it would have.
    ///
    /// **Mutation:** M12. Run: red on the first attempt's re-assert line and the terminal
    /// action's cycle.
    @Test("A re-assert left to a re-apply during its mode write keeps its attempt spent")
    func aReassertLeftToAReapplyDuringItsModeWriteKeepsItsAttemptSpent() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], stages: [.nominal(targetWrites: .reverted)])
        let sensing = InterferingFanStateSensing(plane, during: .engageWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000)
        }

        for _ in 0..<ReclamationLimits.reassertAttemptBudget {
            await machine.watchdog.cycle()
        }
        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(machine.safetyLog.lines(containing: Self.leftBeforeCommanding).count == 1)
        #expect(
            machine.safetyLog.lines(containing: "RPM, attempt 1 of").isEmpty,
            "the attempt the re-apply stood in for was given back and spent again")
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)

        await machine.watchdog.cycle()

        #expect(
            await machine.restorer.causes.contains(.systemReclaimed),
            "the budget was not spent on the cycle it should have been")
    }

    /// **L, the report still to come.** A's re-apply, with its report not yet sent: the client
    /// has registered and put 2,000 on the wire while § 5 reads the envelope, and the record
    /// still holds 2,400. The registration alone must stand § 5 down, or its re-assert writes
    /// the stale 2,400 over the client's 2,000.
    ///
    /// **Mutation:** M8. Run: red on the commanded targets, the firmware's target and the
    /// stand-down line.
    @Test("A registration whose report is still to come is not overwritten")
    func aRegistrationWhoseReportIsStillToComeIsNotOverwritten() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000, reporting: false)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            await machine.commandedRPMs == [2_000],
            "the re-assert wrote the stale target over the client's")
        #expect(try await Self.firmwareTarget(machine) == 2_000)
        #expect(machine.safetyLog.lines(containing: Self.leftAtTheEnvelopeRead).count == 1)
    }

    /// **N, the stamp and the read's sample.** H, one suspension earlier: the client re-engages
    /// the fan under the same lease and commands 2,000 once the plane has sampled § 5's
    /// control-state read and before that read returns. § 5 resumes with a reading that predates
    /// the re-engagement and judges the mode reclaimed; the re-assert must still stand down,
    /// because the stamp is taken before the read and not after it.
    ///
    /// **Mutation:** M13. Run: red on the failed re-engage line and the stand-down line.
    @Test("A re-engagement after the control-state read's sample stands the re-assert down")
    func aReengagementAfterTheReadsSampleStandsTheReassertDown() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .controlStateSampled)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try await Self.lease(machine)
        let permit = try Self.permit(machine)
        await sensing.interfere { [machine] in
            await Self.reapply(machine, under: lease, permit: permit, rpm: 2_000, engaging: true)
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.lines(containing: Self.failedReengage).isEmpty,
            "a failed re-engage was reported for a fan its own lease had re-engaged")
        #expect(await machine.commandedRPMs == [2_000])
        #expect(machine.safetyLog.lines(containing: Self.leftAtTheEnvelopeRead).count == 1)
    }
}
