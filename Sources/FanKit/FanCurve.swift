import Foundation

/// An N-point fan curve mapping a driving temperature to a target speed.
///
/// Macs Fan Control gives you two points. The curve engine is where we go past parity —
/// but the extra expressiveness is exactly why hysteresis and ramp limiting are part of
/// the model rather than optional extras. A curve with a steep segment near a threshold
/// will oscillate audibly without them.
///
/// - Note: Evaluation, hysteresis, and ramp limiting are E8b. The shape is fixed here so
///   the profile schema and the XPC DTOs can be written against it.
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
    public let hysteresisCelsius: Double
    /// Maximum change in target speed per second. Protects both the user's ears and the
    /// fan bearings.
    public let maximumRampRPMPerSecond: Double

    public init(
        points: [Point],
        source: SensorGroup,
        hysteresisCelsius: Double = 2.0,
        maximumRampRPMPerSecond: Double = 200
    ) {
        self.points = points.sorted()
        self.source = source
        self.hysteresisCelsius = hysteresisCelsius
        self.maximumRampRPMPerSecond = maximumRampRPMPerSecond
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
