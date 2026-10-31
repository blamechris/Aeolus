import FanKit
import Testing

@testable import AeolusHelper

/// D3's engaged-turn target rule (ADR 0014's P1′ amendment, decision 4): the turn that reads back
/// `1` holds `F<n>Tg` at or above the fan's floor before it answers `.engaged`.
///
/// At rest Apple's stopped state leaves the target at `0`, so a fan engaged there would sit in
/// manual at a target of `0` until its command's turn — a stopped fan nothing is managing
/// (`CLAUDE.md` rule 3). Under load Apple's target is already above the floor, and the rule
/// writes nothing. `main` has no write plane, so the rule is pinned here twice: as the pure
/// function both planes decide by, and through `ScriptedControlPlane`'s engaged step and the real
/// `EngagementDriver`, which undoes a turn the rule throws from.
@Suite("The engaged turn holds the target at the fan's floor", .timeLimit(.minutes(1)))
struct EngagedTargetRuleTests {

    /// `Mac16,5`'s fan 0 as declared: a floor of 1350.
    private static func permit(
        declaring condition: ScriptedControlPlane.FanCondition = .stoppedByApple
    ) throws -> CommandableFan {
        try commandableFan(0, declaring: condition)
    }

    private static func rule(
        _ target: FanRPMReadback,
        declaring condition: ScriptedControlPlane.FanCondition = .stoppedByApple
    ) throws -> EngagementRules.EngagedTarget {
        let permit = try Self.permit(declaring: condition)
        return try EngagementRules.engagedTarget(reading: target, of: permit)
    }

    // MARK: - The rule

    /// Below the floor, the rule raises to the permit's own floor: `0`, Apple's stopped target,
    /// and a target one RPM short of it.
    ///
    /// **Mutation:** in `EngagementRules.engagedTarget(reading:of:)`, skip the raise —
    /// `return .holds` for every finite target. Run: red on both arguments, and on
    /// `theFloorIsNeverBelowTheManualMinimum`, `aFanEngagedAtRestIsRaisedToItsFloor` and both
    /// arguments of `aFloorTheFirmwareDoesNotTakeIsUndone`. Nothing outside this file went red:
    /// the raise is new behaviour.
    @Test("A target below the floor is raised to the floor", arguments: [0.0, 1_349])
    func aTargetBelowTheFloorIsRaised(_ rpm: Double) throws {
        let permit = try Self.permit()

        let decided = try Self.rule(.rpm(rpm))

        #expect(decided == .raise(to: permit.target(for: 1_350)))
        guard case .raise(let floor) = decided else { return }
        #expect(floor.rpm == 1_350)
        #expect(floor.fanIndex == 0)
    }

    /// At or above the floor the rule writes nothing, however far above: it never lowers a
    /// target, so fan 0's 3455 RPM, and fan 1's 3731, that P1 recorded under load are left as
    /// Apple set them.
    ///
    /// **Mutation:** in `EngagementRules.engagedTarget(reading:of:)`, raise unconditionally —
    /// `return .raise(to: floor)`. Run: red on every argument, and on
    /// `aFanEngagedUnderLoadIsNotWritten`, with nineteen existing tests whose engagements now
    /// lower a target to the floor.
    @Test(
        "A target at or above the floor is kept, never lowered",
        arguments: [1_350.0, 3_731, 9_000])
    func aTargetAtOrAboveTheFloorIsKept(_ rpm: Double) throws {
        #expect(try Self.rule(.rpm(rpm)) == .holds)
    }

    /// The floor is never below `FanSafetyLimits.minimumManualRPM`, whatever the fan declares: a
    /// fan whose firmware declares a minimum of `0` is raised to 100, not left at `0`.
    @Test("The floor is never below the manual minimum, on a fan that declares 0")
    func theFloorIsNeverBelowTheManualMinimum() throws {
        let decided = try Self.rule(.rpm(0), declaring: .zeroMinimum)

        guard case .raise(let floor) = decided else {
            Issue.record("a fan declaring a minimum of 0 was left at a target of 0: \(decided)")
            return
        }
        #expect(floor.rpm == FanSafetyLimits.minimumManualRPM)
    }

    /// A target the turn could not read, or that decoded to a value that is not finite, has no
    /// floor to be judged against: the rule throws, and the driver undoes.
    ///
    /// **Mutation:** in `EngagementRules.engagedTarget(reading:of:)`, answer `.holds` for
    /// `.unreadable`. Run: red on the first argument, and on `anUnreadableTargetIsUndone`.
    /// **Mutation:** drop the `FanControlPlaneValue.finite` check, comparing the raw value. Run:
    /// red on `NaN`, which compares below nothing and was raised, and on infinity, which was
    /// kept.
    @Test(
        "A target that did not read, or is not finite, throws",
        arguments: [
            FanRPMReadback.unreadable(reason: "F0Tg did not answer"), .rpm(.nan), .rpm(.infinity),
        ])
    func anUnreadableTargetThrows(_ target: FanRPMReadback) throws {
        #expect(throws: FanControlPlaneError.self) {
            try Self.rule(target)
        }
    }

    // MARK: - Through the scripted plane and the driver

    /// The engagement rig over one fan in `condition`, on a stage `stage` scripts.
    private static func rig(
        _ condition: ScriptedControlPlane.FanCondition,
        stage: ScriptedControlPlane.Stage = .nominal()
    ) async throws -> EngagementRig {
        let plane = ScriptedControlPlane(fans: [0: condition], stages: [stage])
        return try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .restoreWrite))
    }

    /// Engaging a fan Apple has stopped: the pre-state admits raw `3`, the mode reads back `1`,
    /// and the same step writes the floor and reads it back before the fan is engaged.
    @Test("A fan engaged at rest is raised to its floor in the engaging step")
    func aFanEngagedAtRestIsRaisedToItsFloor() async throws {
        let rig = try await Self.rig(.stoppedByApple)

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .target(fan: 0, rpm: 1_350)])
        let state = try await rig.plane.readControlState(ofFan: 0)
        #expect(state.mode == .manual)
        #expect(state.target == .rpm(1_350), "the engaged fan was left at a target of 0")
        #expect(rig.plane.ledger.engagedFans == [0])
    }

    /// Engaging while Apple spins the fan: its target is at or above the floor, so the step
    /// writes only the mode, and the target is as Apple left it. `spinningByApple` is P1's
    /// twelve-way load, at exactly the floor; 3455 is its sixteen-way plateau.
    ///
    /// **Mutation:** raise unconditionally, as above. Run: red on both arguments.
    @Test(
        "A fan engaged while Apple spins it keeps Apple's target, and nothing more is written",
        arguments: [
            ScriptedControlPlane.FanCondition.spinningByApple,
            ScriptedControlPlane.FanCondition.automatic(at: 3_455),
        ])
    func aFanEngagedUnderLoadIsNotWritten(
        _ spinning: ScriptedControlPlane.FanCondition
    ) async throws {
        let rig = try await Self.rig(spinning)

        try await rig.driver.engageManualControl(of: rig.fan(0))

        #expect(await rig.plane.keyWrites == [.mode(fan: 0, value: 1)])
        #expect(
            try await rig.plane.readControlState(ofFan: 0).target == .rpm(spinning.targetRPM))
        #expect(rig.plane.ledger.engagedFans == [0])
    }

    /// A floor the firmware refuses, or accepts and does not hold at the read-back, fails the
    /// step with that answer: the fan is never engaged, and the driver undoes the mode write it
    /// made.
    @Test(
        "A floor the firmware refuses or does not hold is undone",
        arguments: [
            (
                ScriptedControlPlane.Stage.nominal(targetWrites: .refused(reason: "0x85")),
                FanControlPlaneError.firmwareRefusedControl(detail: "0x85")
            ),
            (
                ScriptedControlPlane.Stage.nominal().holdingNoTarget(ofFan: 0),
                FanControlPlaneError.targetNotConfirmed(
                    index: 0, commandedRPM: 1_350, readBackRPM: 0)
            ),
        ])
    func aFloorTheFirmwareDoesNotTakeIsUndone(
        _ stage: ScriptedControlPlane.Stage, throwing expected: FanControlPlaneError
    ) async throws {
        let rig = try await Self.rig(.stoppedByApple, stage: stage)

        await #expect(throws: expected) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        let writes = await rig.plane.keyWrites
        #expect(writes.prefix(2) == [.mode(fan: 0, value: 1), .target(fan: 0, rpm: 1_350)])
        #expect(writes.last == .mode(fan: 0, value: 0), "the refused engagement was not undone")
        #expect(rig.plane.ledger.engagedFans.isEmpty)
        #expect(try await rig.plane.firmwareMode(ofFan: 0) == .automatic)
    }

    /// A target that does not decode in the engaged turn is no floor's to judge: the step throws
    /// before any target write, and the driver undoes the mode write.
    @Test("A target the engaged turn cannot read is undone, with no target written")
    func anUnreadableTargetIsUndone() async throws {
        var stopped = ScriptedControlPlane.FanCondition.stoppedByApple
        stopped.targetRPM = .nan
        let rig = try await Self.rig(stopped)

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        guard case .readFailed(let detail)? = error else {
            Issue.record("the step threw \(String(describing: error)), not the target's read")
            return
        }
        #expect(detail.hasPrefix("F0Tg after the engaged read-back"))
        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)],
            "a target was written over a register that did not read, or the step was not undone")
        #expect(rig.plane.ledger.engagedFans.isEmpty)
    }

    /// The raise belongs to the turn that read back `1`, and to no other. A fan Apple has stopped
    /// whose mode write is accepted but reads back `3` is not engaged: the step throws on the
    /// read-back, before any target write, and the driver undoes the mode write. A raise ahead of
    /// the read-back would write `F<n>Tg` to a fan the plane never took.
    ///
    /// **Mutation:** in `ScriptedFirmware.unlockStep`, call `holdTargetAtFloor(of:)` before
    /// `EngagementRules.afterReadBack(rawMode:fanAt:)`. Run: red here on the write log, and nowhere
    /// else in the suite.
    @Test("No target is written unless the read-back confirmed the engagement")
    func noTargetIsWrittenWithoutAConfirmedEngagement() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .stoppedByApple], stages: [.nominal()], unlock: .readsBack(rawMode: 3))
        let rig = try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .restoreWrite))

        await #expect(throws: FanControlPlaneError.engagementNotConfirmed(index: 0, rawMode: 3)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)],
            "a target was written before the read-back confirmed the engagement")
        #expect(rig.plane.ledger.engagedFans.isEmpty)
    }
}
