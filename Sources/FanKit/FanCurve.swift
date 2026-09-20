import Foundation

/// An N-point fan curve mapping a driving temperature to a target speed.
///
/// Macs Fan Control gives you two points. The curve engine is where we go past parity —
/// but the extra expressiveness is exactly why hysteresis and ramp limiting are part of
/// the model rather than optional extras. A curve with a steep segment near a threshold
/// will oscillate audibly without them.
///
/// - Note: Evaluation and hysteresis are E8b
///   ([#17](https://github.com/blamechris/Aeolus/issues/17)). The shape is fixed here so the
///   profile schema and the XPC DTOs can be written against it.
/// - Note: **Ramp limiting is not E8b.** This line said it was until #125, which is one of
///   the three disagreeing owners [#121](https://github.com/blamechris/Aeolus/issues/121)
///   was filed against. The governor is `RampGovernor`, an E5 mechanism, built in the change
///   that states ADR 0007's ruling that § 8 never delays a safety-actor write — because a
///   precedence rule about a mechanism that does not exist cannot be tested. This field is
///   the rate it is constructed from; E8a
///   ([#12](https://github.com/blamechris/Aeolus/issues/12)) reuses that governor rather than
///   reimplementing one.
public struct FanCurve: Sendable, Hashable, Codable {
    public struct Point: Sendable, Hashable, Codable, Comparable {
        public let temperatureCelsius: Double
        public let rpm: Double

        public init(temperatureCelsius: Double, rpm: Double) {
            self.temperatureCelsius = temperatureCelsius
            self.rpm = rpm
        }

        /// Finiteness only. Deliberately not a plausibility range on `rpm` — `FanKit` has
        /// no fan identity, so it has no bounds to judge a speed against (see
        /// `FanTargetRPM`'s own admission of that gap), and the clamp into a real fan's
        /// envelope is `FanControlEnvelope.target(for:)`'s job, applied once a curve's
        /// output actually reaches a write. A range check here would be a second,
        /// unreachable clamp: nothing this type does can tell a plausible RPM for one fan
        /// from an implausible one for another, so a guard drawn here could only ever be
        /// wrong for some machine. NaN and the infinities, in contrast, are wrong for
        /// every fan on every machine, which is what makes finiteness the one condition
        /// that earns its place — a guard no test can kill is worse than no guard.
        var isFinite: Bool {
            temperatureCelsius.isFinite && rpm.isFinite
        }

        public static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.temperatureCelsius < rhs.temperatureCelsius
        }
    }

    /// Curve points, kept sorted by temperature.
    ///
    /// **Always entirely finite, and always in the order above.** Both initialisers
    /// guarantee it: a payload or a caller that supplied even one non-finite point yields
    /// `[]`, never a curve missing just the bad point. See `init(points:source:
    /// hysteresisCelsius:maximumRampRPMPerSecond:)` for why dropping the offending point
    /// was rejected in favour of dropping the whole curve. The payoff is that nothing past
    /// construction has to check: E8b's evaluator can never be handed a NaN point, and
    /// `Point.<(_:_:)` can never be asked to order one — which matters because NaN is never
    /// `<` anything, so a `sorted()` fed one does not raise, it silently produces an
    /// incoherent order. That was the defect; this is what closes it.
    public let points: [Point]
    /// The sensors driving this curve, aggregated by `aggregation`.
    public let source: SensorGroup
    /// Degrees of hysteresis applied when the temperature is falling, so a reading
    /// hovering on a point boundary cannot cause the fan to hunt.
    ///
    /// **Never NaN, infinite, or negative, whatever a configuration asked for.** `min`/
    /// `max` propagate NaN, and every comparison against NaN is false — so a NaN here
    /// would not raise or lower the falling-temperature margin, it would silently remove
    /// it, exactly the way an unguarded `ThermalCeiling.effective(requested:default:)`
    /// removed a thermal ceiling in #101. Both initialisers route the requested value
    /// through `effectiveHysteresisCelsius(requested:)`, which falls back to
    /// `defaultHysteresisCelsius` rather than admitting anything that would disable the
    /// mechanism this field bounds.
    public let hysteresisCelsius: Double
    /// Maximum change in target speed per second. Protects both the user's ears and the
    /// fan bearings.
    ///
    /// **Never above `FanSafetyLimits.maximumRampRPMPerSecond`, whatever was asked for.**
    /// This field is client data that crosses the privilege boundary inside a settings
    /// payload, so `docs/SAFETY.md` § 3's downward-only rule governs it exactly as it
    /// governs a thermal ceiling: a configuration may ask the fans to move more gently
    /// than the compiled cap, never more abruptly. Both initialisers clamp, so the stored
    /// value cannot hold an out-of-range rate no matter how the curve was built —
    /// including a hostile JSON payload decoded helper-side, which is where the clamp has
    /// to bite (`CLAUDE.md` rule 7).
    public let maximumRampRPMPerSecond: Double

    /// The margin used when a configuration does not ask for one, and the value
    /// `effectiveHysteresisCelsius(requested:)` falls back to when what was asked for
    /// cannot be honoured.
    public static let defaultHysteresisCelsius: Double = 2.0

    /// - Parameter points: The curve's points. If even one is non-finite, the stored
    ///   curve holds none of them — see the reasoning below, and the invariant on `points`
    ///   above.
    public init(
        points: [Point],
        source: SensorGroup,
        hysteresisCelsius: Double = FanCurve.defaultHysteresisCelsius,
        maximumRampRPMPerSecond: Double = FanSafetyLimits.maximumRampRPMPerSecond
    ) {
        // All-or-nothing, not "drop the bad point and keep the rest". Dropping one point
        // would yield a *different working curve* and apply it without a word to anyone —
        // exactly the "silently substituted" failure #190 exists to close, just moved one
        // level down from a whole setting to a single point within one. An empty curve
        // commands nothing at all, which is legible and, more importantly, safe: with no
        // points to evaluate against, this fan is left on Apple's own thermal management,
        // the same designed-safe fallback state `docs/SAFETY.md` reaches for everywhere
        // else a mechanism cannot be trusted — CLAUDE.md rule 2's lease expiry restores
        // exactly this, and `FanSetting`'s own non-finite `.fixed(rpm:)` falls back to
        // `.automatic` for the identical reason. A curve that silently kept going with one
        // point quietly discarded is a curve nobody asked for.
        self.points = points.allSatisfy(\.isFinite) ? points.sorted() : []
        self.source = source
        self.hysteresisCelsius = FanCurve.effectiveHysteresisCelsius(
            requested: hysteresisCelsius)
        self.maximumRampRPMPerSecond = FanSafetyLimits.effectiveRampRPMPerSecond(
            requested: maximumRampRPMPerSecond)
    }

    /// The hysteresis margin actually used, given what a configuration asked for.
    ///
    /// Mirrors the shape of `FanSafetyLimits.effectiveRampRPMPerSecond(requested:)` — a
    /// request that cannot be honoured falls back to a documented default rather than
    /// being carried — but **diverges from it on zero**, deliberately: an explicit `0`
    /// here is a legitimate "no hysteresis" request and is honoured, where
    /// `effectiveRampRPMPerSecond` rejects `0` because a ramp rate of zero would mean the
    /// fan can never move at all. There is no equivalent floor for a margin — zero
    /// hysteresis just means the curve reacts to every crossing immediately, which is a
    /// real (if noisier) configuration, not a disabled mechanism.
    ///
    /// `requested >= 0` is false for NaN as well as for negative numbers, since every
    /// comparison with NaN is false — so that one condition rejects both without a
    /// separate finiteness check for the negative case. It does **not** reject
    /// `+.infinity`, though, which is why `requested.isFinite` is checked alongside it:
    /// an unbounded margin never releases, disabling the mechanism exactly as completely
    /// as NaN does, just from the other end.
    public static func effectiveHysteresisCelsius(requested: Double) -> Double {
        guard requested.isFinite, requested >= 0 else { return defaultHysteresisCelsius }
        return requested
    }
}

extension FanCurve {

    /// Explicit rather than synthesised, so `init(from:)` below has keys to decode
    /// against. The wire shape is unchanged: the same four fields, all of them required.
    private enum CodingKeys: String, CodingKey {
        case points
        case source
        case hysteresisCelsius
        case maximumRampRPMPerSecond
    }

    /// Decoding applies the same clamp and the same sort as the memberwise initialiser —
    /// and, for `points`, **refuses rather than repairs**.
    ///
    /// A synthesised `init(from:)` assigns the stored properties directly, which would
    /// have made the guarantees on `points` and `maximumRampRPMPerSecond` true of curves
    /// built in Swift and false of curves that arrived as JSON — and JSON is the only way
    /// one ever reaches the helper. A rule that holds everywhere except across the
    /// privilege boundary is not a rule.
    ///
    /// `hysteresisCelsius` and `maximumRampRPMPerSecond` still route through the
    /// memberwise initialiser's fallback-to-default clamp once decoded, because a request
    /// for those is meaningfully answerable — "as gentle a ramp as the compiled cap allows"
    /// is a coherent thing to substitute for a bad request. `points` is different: there is
    /// no default curve to substitute, and silently emptying a badly-formed one, the way
    /// the memberwise initialiser does for a caller in this process, would hide exactly
    /// what a *client* needs told. So the boundary here does what
    /// `FanControlEnvelope.target(for:)`'s doc comment calls "the last line before
    /// firmware, not the only one", in the opposite order: this **is** the outer line, the
    /// one a client can be answered from, and it throws so the client hears what was wrong
    /// with its payload rather than receiving a curve that quietly does nothing. The
    /// memberwise initialiser's empty-on-bad-input behaviour is the inner line, the one
    /// that cannot be forgotten, for every other route a `FanCurve` gets built — a test
    /// fixture, a future call site, anything that isn't this decoder.
    ///
    /// Because `AeolusXPCValidation.decodeFanSettings(from:)` wraps any `DecodingError`
    /// into `AeolusXPCFault.malformedPayload`, this refusal already reaches an XPC client
    /// with no protocol bump and no change to `AeolusXPC` — the throw here is enough; do
    /// not add a parallel finiteness check there.
    ///
    /// The debug description is deliberately value-free, the same discipline
    /// `FanBoundsImplausibility.description` documents for itself: a root daemon must not
    /// echo a client's bytes into its own log, and a value-free message is what lets this
    /// be compared in a test without that test also pinning Foundation's own wording.
    ///
    /// Every field stays required. `FanCurve`'s Swift-side defaults are a convenience for
    /// constructing one in code; a payload that omits a field is a client that did not say
    /// what it wanted, and the helper should not decide that for it — the same reasoning
    /// `AeolusXPCValidation.decodeLeaseRequest(from:)` records for `LeaseRequest`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([Point].self, forKey: .points)
        guard points.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(
                forKey: .points, in: container,
                debugDescription: "a curve point is not finite")
        }
        self.init(
            points: points,
            source: try container.decode(SensorGroup.self, forKey: .source),
            hysteresisCelsius: try container.decode(Double.self, forKey: .hysteresisCelsius),
            maximumRampRPMPerSecond: try container.decode(
                Double.self, forKey: .maximumRampRPMPerSecond)
        )
    }
}

/// A set of sensors combined into one driving temperature.
///
/// The reason this exists: driving a fan from the CPU die sensor alone is how you cool
/// the CPU and cook the SSD. `max()` over a group is almost always the right default.
public struct SensorGroup: Sendable, Hashable, Codable {
    public enum Aggregation: String, Sendable, Hashable, Codable {
        case maximum
        case average
    }

    /// Raw SMC keys, not friendly labels. Labels change; keys do not.
    public let sensorKeys: [String]
    public let aggregation: Aggregation

    public init(sensorKeys: [String], aggregation: Aggregation = .maximum) {
        self.sensorKeys = sensorKeys
        self.aggregation = aggregation
    }
}
