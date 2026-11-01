import FanKit
import Testing

@testable import AeolusHelper

/// `GovernedFanWriter.hold(_:of:)`: how level 6 writes a `.fixed(rpm:)` setting, whole, in one
/// write of the clamped goal (ADR 0014's A6 and A6 PR-2 amendments).
///
/// The ramp memory that `command(towards:of:since:)` steps from is what makes this matter. It is
/// per fan and lives as long as the writer, so a fixed setting written as one governed step from a
/// remembered target is not the setting: 3,564 RPM remembered, 5,777 asked for, and one second's
/// step writes 3,764 while the reply says applied. That `apply` resets the memory at every
/// engagement and hand-back is `LeaseApplierRampTests`'.
@Suite("The governed writer's whole write", .timeLimit(.minutes(1)))
struct GovernedFanWriterHoldTests {

    private func fan(_ index: Int = 0) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    /// **A held target is written whole, whatever was written before.** 3,564 is remembered from an
    /// earlier write, and holding 5,777 writes 5,777, once.
    ///
    /// **Mutation:** make `hold` return `try await command(towards: goal, of: fan, since:
    /// .seconds(1))`. Run: red, 3,764 written.
    @Test("A held target is one write of the goal, not a step towards it")
    func aHeldTargetIsWrittenWhole() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        let writer = GovernedFanWriter(plane: plane)
        _ = try await writer.command(towards: 3_564, of: try fan(), since: .seconds(1))

        let held = try await writer.hold(5_777, of: try fan())

        #expect(held.rpm == 5_777, "a fixed setting was written as a governed step")
        #expect(
            await plane.attempts == [
                .commandTarget(fan: 0, rpm: 3_564), .commandTarget(fan: 0, rpm: 5_777),
            ])
        #expect(await writer.lastCommanded(ofFan: 0) == 5_777)
    }

    /// § 2 binds a held target as it binds every write: above the declared maximum is the
    /// maximum, and zero is never a stop. Structural rather than mutable here, since a target can
    /// only be minted through `CommandableFan.target(for:)`; the test is what says the whole write
    /// goes through it. Zero lands on the 50 % point since #670, which is above § 2's floor.
    @Test("A held target is clamped into the envelope, and never 0 RPM")
    func aHeldTargetIsClamped() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        let writer = GovernedFanWriter(plane: plane)

        #expect(try await writer.hold(99_999, of: try fan()).rpm == 5_777)
        let floor = try await writer.hold(0, of: try fan()).rpm
        #expect(floor > 0)
        #expect(floor > max(1_350, FanSafetyLimits.minimumManualRPM))
        #expect(floor == 3_563.5, "(1,350 + 5,777) / 2, the 50 % point")
    }

    /// (b) of #670: a held target below the fan's 50 % point is written at that point, and what is
    /// written is what `hold` returns and remembers, so § 5 records it and the snapshot reports it
    /// (`CLAUDE.md` rule 6). The app's presets pass unchanged: 50 % is 3,564 on these bounds,
    /// above the point's 3,563.5, and 75 % and 100 % are higher.
    ///
    /// **Mutation:** in `hold`, write `fan.target(for: goal)`. Run: red, 2,000 written.
    /// **Mutation:** in `CommandableFan.clientTarget(for:)`, return `clamped` unconditionally.
    /// Run: red, 2,000 written.
    @Test("A held target below the 50 % point is written at it, and the presets pass unchanged")
    func aHeldTargetBelowTheFloorIsRaised() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal])
        let writer = GovernedFanWriter(plane: plane)
        let envelope = try fan().envelope

        let raised = try await writer.hold(2_000, of: try fan())
        #expect(raised.rpm == 3_563.5)
        #expect(await writer.lastCommanded(ofFan: 0) == 3_563.5)

        for percent in [50.0, 75, 100] {
            let preset = envelope.target(forPercent: percent).rpm
            #expect(try await writer.hold(preset, of: try fan()).rpm == preset, "\(percent) %")
        }
        #expect(
            await plane.attempts == [
                .commandTarget(fan: 0, rpm: 3_563.5), .commandTarget(fan: 0, rpm: 3_564),
                .commandTarget(fan: 0, rpm: 4_670), .commandTarget(fan: 0, rpm: 5_777),
            ])
    }

    /// What the plane put on the wire is what `hold` returns and remembers, never the goal: the
    /// report `apply` sends § 5 is built from this.
    ///
    /// **Mutation:** in `hold`, return `CommandedTarget(fanIndex: fan.index, rpm: goal)`. Run:
    /// red, 2,000 returned where the plane wrote 2,001.
    @Test("A held target returns what the plane wrote, not what was asked")
    func aHeldTargetReturnsThePlanesAnswer() async throws {
        let scripted = ScriptedControlPlane(fans: [0: .nominal])
        let plane = InterferingFanStateSensing(scripted, during: .commandWrite)
        await plane.misreport(commandedRPM: 2_001)
        let writer = GovernedFanWriter(plane: plane)

        let held = try await writer.hold(2_000, of: try fan())

        #expect(held == CommandedTarget(fanIndex: 0, rpm: 2_001))
        #expect(await writer.lastCommanded(ofFan: 0) == 2_001)
    }

    /// A refused hold did not land, so the memory keeps the last target that did.
    ///
    /// **Mutation:** in `hold`, assign `lastCommandedRPM[fan.index] = goal` before the write. Run:
    /// red, 5,000 remembered.
    @Test("A refused hold leaves the remembered target where it was")
    func aRefusedHoldRemembersNothing() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [
                .nominal(),
                ScriptedControlPlane.Stage(writes: .refused(reason: "firmware said no")),
            ])
        let writer = GovernedFanWriter(plane: plane)
        _ = try await writer.hold(4_000, of: try fan())
        await plane.advance()

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await writer.hold(5_000, of: try fan())
        }
        #expect(await writer.lastCommanded(ofFan: 0) == 4_000)
    }
}
