import FanKit
import Testing

@testable import AeolusHelper

/// The control loop's write path — actor level 6, and the only holder of a `RampGovernor`.
///
/// It had **no tests at all** when it shipped: nothing in `Sources/` or `Tests/`
/// instantiated it, so deleting the ramp entirely (`let stepped = goal`) left all 866 tests
/// green. That was found by an adversarial review rather than by reading, and it is the
/// same defect class the rest of this suite exists to prevent — a mechanism whose behaviour
/// is asserted only in its own doc comment.
///
/// Nothing calls it yet in production either; actor level 6 arrives with the write path in
/// E3/E4. That is a reason to test it now, not later: the type is generic over
/// `FanControlPlane` and `ScriptedControlPlane` already exists, so the cost is small and
/// E3 inherits a contract rather than a claim.
@Suite("The governed (control-loop) fan writer")
struct GovernedFanWriterTests {

    private func machine() -> ScriptedControlPlane {
        ScriptedControlPlane(fans: [0: .nominal, 1: .nominal])
    }

    private func fan(_ index: Int) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    /// A fan coming off automatic control is not mid-movement, so there is no previous
    /// target to ramp from and the first write goes straight to the clamped goal.
    @Test("The first write to a fan is not rate-limited")
    func theFirstWriteGoesStraightToTheGoal() async throws {
        let plane = machine()
        let writer = GovernedFanWriter(plane: plane)

        let commanded = try await writer.command(
            towards: 5_000, of: try fan(0), since: .seconds(1))

        #expect(commanded.rpm == 5_000)
        #expect(await plane.attempts == [.commandTarget(fan: 0, rpm: 5_000)])
    }

    /// The one that matters: **every subsequent write is capped.** Replace `stepped` with
    /// `goal` in `command(towards:of:since:)` and this goes red. Above the 50 % point, 3,563.5 on
    /// these bounds, so the floor #670 adds moves none of it.
    @Test("Every write after the first is capped at the ramp rate")
    func subsequentWritesAreRateLimited() async throws {
        let plane = machine()
        let writer = GovernedFanWriter(plane: plane)
        _ = try await writer.command(towards: 4_000, of: try fan(0), since: .seconds(1))

        let stepped = try await writer.command(
            towards: 5_777, of: try fan(0), since: .seconds(1))

        #expect(stepped.rpm == 4_200, "4000 + 200 RPM/s × 1 s")
        #expect(await writer.lastCommanded(ofFan: 0) == 4_200)
    }

    /// The § 8 arithmetic, at the writer rather than at the pure governor: a control loop
    /// takes twelve one-second writes to climb from this machine's 50 % point to its maximum,
    /// and took 23 to cross the whole span before #670 put the floor at that point. This is the
    /// cost ADR 0007 refuses to impose on § 3 — see
    /// `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite` for the other end.
    @Test("A governed ramp from the 50 % point takes 12 writes, one per second")
    func aFullScaleGovernedRampIsAStaircase() async throws {
        let plane = machine()
        let writer = GovernedFanWriter(plane: plane)
        _ = try await writer.command(towards: 1_350, of: try fan(0), since: .seconds(1))
        #expect(await writer.lastCommanded(ofFan: 0) == 3_563.5, "the floor is the 50 % point")

        var writes = 1
        while try await writer.lastCommanded(ofFan: 0) != 5_777, writes < 1_000 {
            _ = try await writer.command(towards: 5_777, of: try fan(0), since: .seconds(1))
            writes += 1
        }

        #expect(writes == 13, "one write to arrive at the 50 % point, then 12 to climb")
        #expect(await plane.attempts.count == 13)
    }

    /// (b) of #670 binds the control loop's step as it binds a fixed setting: a goal below the
    /// 50 % point, first write or ramped, is written at that point.
    ///
    /// **Mutation:** in `command(towards:of:since:)`, write `fan.target(for: stepped)`. Run: red,
    /// 1,350 written first and 3,400 written below the point.
    @Test("A governed step below the 50 % point is written at it")
    func aGovernedStepIsRaisedToTheFloor() async throws {
        let plane = machine()
        let writer = GovernedFanWriter(plane: plane)

        let first = try await writer.command(towards: 1_350, of: try fan(0), since: .seconds(1))
        _ = try await writer.command(towards: 3_800, of: try fan(1), since: .seconds(1))
        let ramped = try await writer.command(towards: 0, of: try fan(1), since: .seconds(1))

        #expect(first.rpm == 3_563.5)
        #expect(ramped.rpm == 3_600, "3,800 less one second's 200 RPM, above the point")
        let below = try await writer.command(towards: 0, of: try fan(1), since: .seconds(1))
        #expect(below.rpm == 3_563.5, "3,400 is below the point, so the point is written")
    }

    /// Ramp state is per fan. Sharing one counter across fans would let a step for fan 1 be
    /// computed from fan 0's last target — the cross-fan defect `commandTarget(_:)` removed
    /// its `ofFan:` parameter to make unrepresentable.
    /// Each fan needs a **second** write for this to mean anything: the first write to a fan
    /// bypasses the governor, so a version of this test that only made first writes passed
    /// even with the state keyed to a constant index. Found by mutation.
    @Test("Ramp state is remembered per fan, not globally")
    func rampStateIsPerFan() async throws {
        let writer = GovernedFanWriter(plane: machine())
        _ = try await writer.command(towards: 4_000, of: try fan(0), since: .seconds(1))
        _ = try await writer.command(towards: 5_000, of: try fan(1), since: .seconds(1))

        let zero = try await writer.command(
            towards: 5_777, of: try fan(0), since: .seconds(1))
        let one = try await writer.command(
            towards: 5_777, of: try fan(1), since: .seconds(1))

        #expect(zero.rpm == 4_200, "fan 0 ramps from its own 4000, not from fan 1's 5000")
        #expect(one.rpm == 5_200, "fan 1 ramps from its own 5000")
        #expect(await writer.lastCommanded(ofFan: 0) == 4_200)
        #expect(await writer.lastCommanded(ofFan: 1) == 5_200)
    }

    /// A fan back on Apple's thermal management has no target to ramp from. Keeping one
    /// would make the next engagement ramp from a speed nothing is holding.
    @Test("Returning a fan to automatic forgets its ramp state")
    func returningToAutomaticForgetsTheRamp() async throws {
        let writer = GovernedFanWriter(plane: machine())
        _ = try await writer.command(towards: 1_400, of: try fan(0), since: .seconds(1))

        await writer.fanReturnedToAutomatic(index: 0)

        #expect(await writer.lastCommanded(ofFan: 0) == nil)
        let afterwards = try await writer.command(
            towards: 5_777, of: try fan(0), since: .seconds(1))
        #expect(afterwards.rpm == 5_777, "the next write is a first write again")
    }

    /// A write the firmware refused did not land, so the next ramp must start from the last
    /// step that **did**. Remembering a refused target would ramp from a speed the fan never
    /// held.
    @Test("A refused write leaves the remembered target where it was")
    func aRefusedWriteDoesNotMoveTheRampOrigin() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [
                .nominal(),
                ScriptedControlPlane.Stage(writes: .refused(reason: "firmware said no")),
            ])
        let writer = GovernedFanWriter(plane: plane)
        _ = try await writer.command(towards: 4_000, of: try fan(0), since: .seconds(1))
        await plane.advance()

        await #expect(throws: FanControlPlaneError.self) {
            _ = try await writer.command(towards: 5_777, of: try fan(0), since: .seconds(1))
        }

        #expect(await writer.lastCommanded(ofFan: 0) == 4_000)
    }

    /// § 2 still binds a governed write. The governor produces a *goal*, never a target: a
    /// nonsense number from a curve cannot become a nonsense write.
    @Test("A governed step is still clamped into the fan's envelope")
    func aGovernedStepIsStillClamped() async throws {
        let plane = machine()
        let writer = GovernedFanWriter(plane: plane)

        let commanded = try await writer.command(
            towards: 99_999, of: try fan(0), since: .seconds(1))

        #expect(commanded.rpm == 5_777, "clamped to the declared firmware maximum")
    }

    /// `CLAUDE.md` rule 3, on the one path that could plausibly reach a stop: a curve asking
    /// for zero, ramping downward, must still never command it.
    @Test("A governed ramp toward zero never commands a stop")
    func aGovernedRampNeverReachesZero() async throws {
        let writer = GovernedFanWriter(plane: machine())
        _ = try await writer.command(towards: 1_350, of: try fan(0), since: .seconds(1))

        for _ in 0..<50 {
            let step = try await writer.command(
                towards: 0, of: try fan(0), since: .seconds(1))
            #expect(step.rpm >= 3_563.5, "the 50 % point is the floor (#670), and it is not 0")
        }
    }
}
