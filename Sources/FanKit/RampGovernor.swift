import Foundation

/// `docs/SAFETY.md` § 8's ramp limiter: the thing that turns the cap on a *number* into a
/// cap on *movement*.
///
/// ## Why this type exists, and why here
///
/// [#101](https://github.com/blamechris/Aeolus/issues/101) shipped
/// `FanSafetyLimits.effectiveRampRPMPerSecond(requested:)`, which stops a curve from
/// *holding* a rate above the compiled cap. Nothing consumed it:
/// [#121](https://github.com/blamechris/Aeolus/issues/121) recorded that § 8 bounded a
/// value and shaped no output, that three places named three different owners for the
/// governor, and — the part that matters here — that
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s precedence ruling *"ramp
/// limiting never delays a safety-actor write"* was **a rule about a mechanism that did not
/// exist to break it**. A rule that cannot fail is this repository's most-repeated defect.
///
/// #125 resolves #121 as its own first option — the governor is an E5 mechanism, built in
/// the change that states the precedence ruling, so that the exclusion is testable by
/// mutation rather than asserted. Hysteresis, § 8's other half, stays with
/// [#17](https://github.com/blamechris/Aeolus/issues/17): it is a property of evaluating a
/// curve, and there is no curve evaluator yet.
///
/// It lives in `FanKit` beside the clamp it consumes because it is pure arithmetic over
/// two numbers and a duration — no IOKit, no firmware, no clock of its own — which is
/// exactly `FanKit`'s charter, and because [#12](https://github.com/blamechris/Aeolus/issues/12)
/// (E8a) is told to *reuse* this mechanism rather than reimplement it. A governor inside
/// `AeolusHelper` would be unreachable from there.
///
/// ## What it governs, and what it must never govern
///
/// It shapes **the control loop's output only** — actor level 6 in ADR 0007's precedence
/// order. It must never sit between a safety actor and the firmware. The arithmetic is the
/// argument, and `AeolusHelper`'s `SafetyActorWriter` is where the exclusion is made
/// structural:
///
/// ```
/// Mac16,5 declares F0Mn = 1350 and F0Mx = 5777.
/// A full-scale emergency ramp is 5777 − 1350 = 4427 RPM.
/// At the 200 RPM/s cap that is 22.135 seconds to reach maximum,
/// with a CPU package above 95 °C for every one of them.
/// ```
///
/// `secondsToTraverse(from:toward:)` computes that number rather than restating it, so a
/// test can cite the arithmetic instead of a reader re-deriving it — see
/// `RampGovernorTests.aFullScaleRampTakesTwentyTwoSeconds` and
/// `ThermalEmergencyTests.theEmergencyReachesMaximumInOneWrite`.
///
/// ## Failing open is the correct direction for this mechanism, and only for this one
///
/// Every guard below resolves toward **moving faster**, up to and including going straight
/// to the goal. That is the opposite of how § 3's ceiling resolves an uncertain input, and
/// the asymmetry is deliberate: a ramp limiter is a *comfort* mechanism whose failure to
/// limit is merely audible, while its firing when it should not have would delay a fan
/// getting where a curve asked it to go. Nothing here is a safety limit, and treating it as
/// one — by stalling on an input it cannot make sense of — would invert § 8's own standing
/// relative to § 3.
///
/// The number this produces is a *goal for the next write*, never a write. It still passes
/// through `FanControlEnvelope.target(for:)` before anything reaches the firmware, so
/// § 2's bounds and the 0-RPM floor bind it exactly as they bind any other target.
public struct RampGovernor: Sendable, Hashable {

    /// The rate this governor actually applies, in RPM per second.
    ///
    /// Always finite, always strictly positive, and never above
    /// `FanSafetyLimits.maximumRampRPMPerSecond` — the initialiser runs the downward-only
    /// clamp rather than trusting what it was handed. `FanCurve` already clamps the same
    /// field on decode, and this is deliberately the second application of it rather than
    /// the only one: the curve's clamp binds a payload crossing the privilege boundary,
    /// and this one binds every other way a rate could reach a governor, including a
    /// literal written inside the helper. `CLAUDE.md` rule 7 asks for the check on the side
    /// that acts.
    public let ratePerSecond: Double

    /// - Parameter requestedRatePerSecond: What a configuration asked for. Zero, negative,
    ///   or NaN falls back to the compiled cap; anything above it is clamped down to it.
    public init(
        requestedRatePerSecond: Double = FanSafetyLimits.maximumRampRPMPerSecond
    ) {
        ratePerSecond = FanSafetyLimits.effectiveRampRPMPerSecond(
            requested: requestedRatePerSecond)
    }

    /// The next target on the way to `goal`, given how long since the last one.
    ///
    /// - Parameters:
    ///   - current: The target last commanded — **not** the fan's measured speed.
    ///     `F<n>Ac` legitimately lags `F<n>Tg` while the fan's own controller slews, so
    ///     governing against a measurement would re-govern movement that has already been
    ///     asked for. See `CommandedTarget` in `AeolusHelper`, which exists to carry this
    ///     number.
    ///   - goal: Where the control loop wants the fan.
    ///   - elapsed: Time since `current` was commanded.
    /// - Returns: `goal` when the budget covers the whole distance, otherwise `current`
    ///   moved toward `goal` by exactly the budget.
    public func step(from current: Double, toward goal: Double, over elapsed: Duration) -> Double {
        // An unusable pair of endpoints means this governor does not know where the fan is
        // being asked to go from. It hands the goal straight through rather than inventing
        // a step from a NaN — see the type's note on failing open.
        guard current.isFinite, goal.isFinite else { return goal }

        let budget = ratePerSecond * Self.seconds(elapsed)
        // A non-positive or non-finite budget is "no time has passed": hold. NaN takes this
        // branch too, because every comparison with NaN is false — the same property
        // `effectiveRampRPMPerSecond` relies on, spelled the same way so the two read alike.
        guard budget > 0 else { return current }

        let distance = goal - current
        guard abs(distance) > budget else { return goal }
        return current + (distance < 0 ? -budget : budget)
    }

    /// How long this governor would take to move a target from `current` to `goal`.
    ///
    /// The one place ADR 0007's 22-second arithmetic is computed. It takes the endpoints as
    /// parameters rather than reading `Mac16,5`'s envelope, so the number a test cites comes
    /// from that test's own fixture and moves when the fixture does.
    ///
    /// - Returns: Seconds, never negative. Zero for a non-finite endpoint, by the same
    ///   fail-open rule as `step(from:toward:over:)`.
    public func secondsToTraverse(from current: Double, toward goal: Double) -> Double {
        guard current.isFinite, goal.isFinite else { return 0 }
        return abs(goal - current) / ratePerSecond
    }

    /// `Duration` to seconds, without going through `TimeInterval` arithmetic that would
    /// round a sub-second cadence to nothing.
    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
