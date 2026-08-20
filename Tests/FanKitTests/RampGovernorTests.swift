import Foundation
import Testing

@testable import FanKit

/// `docs/SAFETY.md` § 8's ramp limiter — the half of § 8 that shapes an output, as opposed
/// to the half `DownwardOnlyLimitTests` covers, which only bounds a number a curve may
/// hold.
///
/// The arithmetic here is what [ADR 0007](../../docs/ADR/0007-safety-composition.md) cites
/// when it refuses to let § 8 throttle § 3, so it is asserted rather than quoted.
@Suite("The ramp governor")
struct RampGovernorTests {

    /// `Mac16,5`'s measured envelope, and the only place these two figures appear in this
    /// suite. `docs/SMC-RESEARCH.md` records them; `ScriptedControlPlane.FanCondition.nominal`
    /// carries the same pair on the helper side.
    private static let declaredMinimumRPM = 1_350.0
    private static let declaredMaximumRPM = 5_777.0

    // MARK: - The number ADR 0007 rests on

    /// **The 22 seconds.**
    ///
    /// This is the whole of ADR 0007's conflict 4 as one assertion: a full-scale emergency
    /// ramp on this machine, at § 8's cap, with a CPU package above 95 °C for every second
    /// of it. `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite` is the other end
    /// of the argument — that the emergency does not pay it.
    ///
    /// Computed from the envelope rather than written down, so changing the fixture changes
    /// the number instead of making this test wrong quietly.
    @Test("A full-scale ramp on Mac16,5 takes 22 seconds at the 200 RPM/s cap")
    func aFullScaleRampTakesTwentyTwoSeconds() {
        let span = Self.declaredMaximumRPM - Self.declaredMinimumRPM
        #expect(span == 4_427)

        let seconds = RampGovernor().secondsToTraverse(
            from: Self.declaredMinimumRPM, toward: Self.declaredMaximumRPM)

        #expect(abs(seconds - 22.135) < 0.001)
        #expect(seconds > 22)
    }

    /// The same fact from the other direction: stepping one second at a time really does
    /// take 23 writes to arrive. This is the shape a governed emergency would produce, and
    /// it is what turns `theEmergencyReachesMaximumInOneWrite` red when that mutation is
    /// applied.
    @Test("Stepping a full-scale ramp one second at a time takes 23 writes")
    func aFullScaleRampIsAStaircase() {
        let governor = RampGovernor()
        var current = Self.declaredMinimumRPM
        var writes = 0

        while current < Self.declaredMaximumRPM, writes < 1_000 {
            current = governor.step(
                from: current, toward: Self.declaredMaximumRPM, over: .seconds(1))
            writes += 1
        }

        #expect(writes == 23)
        #expect(current == Self.declaredMaximumRPM)
    }

    // MARK: - Stepping

    @Test("A step is capped at the rate times the elapsed time")
    func aStepIsCapped() {
        let governor = RampGovernor()

        #expect(governor.step(from: 1_350, toward: 5_777, over: .seconds(1)) == 1_550)
        #expect(governor.step(from: 1_350, toward: 5_777, over: .seconds(2)) == 1_750)
        #expect(governor.step(from: 1_350, toward: 5_777, over: .milliseconds(500)) == 1_450)
    }

    @Test("A step that would overshoot lands exactly on the goal")
    func aStepDoesNotOvershoot() {
        let governor = RampGovernor()

        #expect(governor.step(from: 1_350, toward: 1_400, over: .seconds(1)) == 1_400)
        #expect(governor.step(from: 1_350, toward: 5_777, over: .seconds(60)) == 5_777)
    }

    @Test("Ramping down is capped in the same way")
    func rampingDownIsCappedToo() {
        let governor = RampGovernor()

        #expect(governor.step(from: 5_777, toward: 1_350, over: .seconds(1)) == 5_577)
        #expect(governor.step(from: 5_777, toward: 5_700, over: .seconds(1)) == 5_700)
    }

    @Test("No elapsed time is no movement")
    func noTimeIsNoMovement() {
        let governor = RampGovernor()

        #expect(governor.step(from: 1_350, toward: 5_777, over: .zero) == 1_350)
        #expect(governor.step(from: 1_350, toward: 5_777, over: .seconds(-5)) == 1_350)
    }

    // MARK: - The downward-only rule, applied on the side that acts

    /// `FanCurve` already clamps this field on decode. This is the second application, and
    /// `CLAUDE.md` rule 7 is why: the curve's clamp binds a payload crossing the privilege
    /// boundary, and this one binds every other way a rate can reach a governor.
    @Test("A configuration cannot make the governor faster than the compiled cap")
    func theCapCannotBeRaised() {
        #expect(RampGovernor(requestedRatePerSecond: 5_000).ratePerSecond == 200)
        #expect(
            RampGovernor(requestedRatePerSecond: .infinity).ratePerSecond
                == FanSafetyLimits.maximumRampRPMPerSecond)
    }

    @Test("A gentler rate is honoured")
    func aGentlerRateIsHonoured() {
        let governor = RampGovernor(requestedRatePerSecond: 50)

        #expect(governor.ratePerSecond == 50)
        #expect(governor.step(from: 1_350, toward: 5_777, over: .seconds(1)) == 1_400)
    }

    /// A request that is not a rate at all falls back to the cap rather than to zero. Zero
    /// would freeze every control-loop target where it stood, which is a comfort mechanism
    /// taking a fan hostage.
    @Test("A rate that is not a rate falls back to the compiled cap")
    func aNonRateFallsBackToTheCap() {
        for requested: Double in [0, -1, -.infinity, .nan] {
            #expect(
                RampGovernor(requestedRatePerSecond: requested).ratePerSecond
                    == FanSafetyLimits.maximumRampRPMPerSecond)
        }
    }

    // MARK: - Failing open

    /// The opposite of how § 3 resolves an unusable number, and deliberately so: a ramp
    /// limiter that stalled on a NaN would be a comfort mechanism delaying a fan, which is
    /// § 8's standing relative to § 3 inverted. See the type's own note.
    @Test("An unusable endpoint hands the goal straight through")
    func anUnusableEndpointFailsOpen() {
        let governor = RampGovernor()

        #expect(governor.step(from: .nan, toward: 5_777, over: .seconds(1)) == 5_777)
        #expect(governor.step(from: .infinity, toward: 5_777, over: .seconds(1)) == 5_777)
        #expect(governor.secondsToTraverse(from: .nan, toward: 5_777) == 0)
    }

    /// The result is a *goal*, never a write. § 2 still binds it, so a governor handing back
    /// a nonsense number cannot become a nonsense target.
    @Test("A stepped goal still passes through the envelope clamp")
    func aSteppedGoalIsStillClamped() throws {
        let envelope = try FanControlEnvelope.validating(
            declaredMinimumRPM: Self.declaredMinimumRPM,
            declaredMaximumRPM: Self.declaredMaximumRPM
        ).get()
        let governor = RampGovernor()

        let stepped = governor.step(from: .nan, toward: 99_999, over: .seconds(1))
        #expect(stepped == 99_999)
        #expect(envelope.target(for: stepped).rpm == Self.declaredMaximumRPM)
    }
}
