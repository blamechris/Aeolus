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

        public static func < (lhs: Point, rhs: Point) -> Bool {
            lhs.temperatureCelsius < rhs.temperatureCelsius
        }
    }

    /// Curve points, kept sorted by temperature.
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

    public init(
        points: [Point],
        source: SensorGroup,
        hysteresisCelsius: Double = FanCurve.defaultHysteresisCelsius,
        maximumRampRPMPerSecond: Double = FanSafetyLimits.maximumRampRPMPerSecond
    ) {
        self.points = points.sorted()
        self.source = source
        self.hysteresisCelsius = FanCurve.effectiveHysteresisCelsius(
            requested: hysteresisCelsius)
        self.maximumRampRPMPerSecond = FanSafetyLimits.effectiveRampRPMPerSecond(
            requested: maximumRampRPMPerSecond)
    }

    /// The hysteresis margin actually used, given what a configuration asked for.
    ///
    /// Mirrors `FanSafetyLimits.effectiveRampRPMPerSecond(requested:)`: a request that is
    /// not a usable margin at all — negative, `-.infinity`, or NaN — falls back to
    /// `defaultHysteresisCelsius` rather than being honoured. `requested >= 0` is false
    /// for NaN as well, since every comparison with NaN is false, so one condition
    /// covers all three cases without a separate finiteness check beside it.
    /// `+.infinity` is refused too — an unbounded margin never releases, which disables
    /// the mechanism exactly as completely as NaN does, just at the other end.
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

    /// Decoding applies the same clamp and the same sort as the memberwise initialiser.
    ///
    /// A synthesised `init(from:)` assigns the stored properties directly, which would
    /// have made the guarantees on `points` and `maximumRampRPMPerSecond` true of curves
    /// built in Swift and false of curves that arrived as JSON — and JSON is the only way
    /// one ever reaches the helper. A rule that holds everywhere except across the
    /// privilege boundary is not a rule.
    ///
    /// Every field stays required. `FanCurve`'s Swift-side defaults are a convenience for
    /// constructing one in code; a payload that omits a field is a client that did not say
    /// what it wanted, and the helper should not decide that for it — the same reasoning
    /// `AeolusXPCValidation.decodeLeaseRequest(from:)` records for `LeaseRequest`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            points: try container.decode([Point].self, forKey: .points),
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
