import Foundation
import Testing

@testable import FanKit

/// `docs/SAFETY.md` § 8's ramp cap, governed by § 3's downward-only rule because it is
/// client data that crosses the privilege boundary inside a settings payload.
@Suite("Ramp rate limiting")
struct RampLimitTests {

    private let cap = FanSafetyLimits.maximumRampRPMPerSecond

    @Test("A configuration may ask the fans to move more gently")
    func allowsLowering() {
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: 50) == 50)
    }

    @Test("A configuration may not ask the fans to move more abruptly")
    func rejectsRaising() {
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: 5000) == cap)
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: .infinity) == cap)
    }

    /// `min(.nan, cap)` is NaN, and a NaN rate limit is a comparison nothing satisfies.
    @Test("A rate that is not a rate falls back to the compiled cap")
    func nonRatesFallBackToTheCap() {
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: .nan) == cap)
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: 0) == cap)
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: -1) == cap)
        #expect(FanSafetyLimits.effectiveRampRPMPerSecond(requested: -.infinity) == cap)
    }

    @Test("A curve built in Swift cannot hold a rate above the cap")
    func curveClampsOnConstruction() {
        let curve = FanCurve(
            points: [FanCurve.Point(temperatureCelsius: 40, rpm: 1500)],
            source: SensorGroup(sensorKeys: ["TC0P"]),
            maximumRampRPMPerSecond: 100_000
        )
        #expect(curve.maximumRampRPMPerSecond == cap)
    }

    /// The one that matters: JSON is the only way a curve ever reaches the helper, so a
    /// clamp that holds for Swift-built curves and not for decoded ones is not a clamp.
    /// Delete the custom `init(from:)` and this goes red while the test above stays green.
    @Test("A curve decoded from a payload cannot hold a rate above the cap")
    func curveClampsOnDecode() throws {
        let json = """
            {"points":[{"temperatureCelsius":40,"rpm":1500}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100000}
            """
        let curve = try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
        #expect(curve.maximumRampRPMPerSecond == cap)
    }

    /// A settings payload carries a curve inside a `FanSetting`, which is the shape that
    /// actually crosses the boundary.
    @Test("A curve nested in a fan setting is clamped on decode too")
    func nestedCurveClampsOnDecode() throws {
        let json = """
            [{"fanIndex":0,"control":{"curve":{"_0":{\
            "points":[{"temperatureCelsius":40,"rpm":1500}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100000}}}}]
            """
        let settings = try JSONDecoder().decode([FanSetting].self, from: Data(json.utf8))
        guard case .curve(let curve) = settings.first?.control else {
            Issue.record("the decoded setting did not carry a curve")
            return
        }
        #expect(curve.maximumRampRPMPerSecond == cap)
    }

    /// The custom initialiser must not quietly relax the wire contract while it is
    /// clamping: every field stays required, exactly as the synthesised one required them.
    @Test("A curve payload missing a field still does not decode")
    func curvePayloadMissingAFieldDoesNotDecode() {
        let json = """
            {"points":[],"source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
        }
    }

    /// The custom initialiser must agree with the *synthesised encoder* it now sits beside,
    /// which means the explicit `CodingKeys` must still be the keys encoding uses. A
    /// mismatch would leave the hand-written payloads above passing while a real curve
    /// failed to survive its own round trip.
    @Test("A curve survives its own encode and decode")
    func curveRoundTrips() throws {
        let curve = FanCurve(
            points: [
                FanCurve.Point(temperatureCelsius: 80, rpm: 4000),
                FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
            ],
            source: SensorGroup(sensorKeys: ["TC0P", "TG0P"], aggregation: .maximum),
            hysteresisCelsius: 3,
            maximumRampRPMPerSecond: 120
        )

        let decoded = try JSONDecoder().decode(
            FanCurve.self, from: try JSONEncoder().encode(curve))
        #expect(decoded == curve)
        #expect(decoded.maximumRampRPMPerSecond == 120)
        #expect(decoded.points.map(\.temperatureCelsius) == [40, 80])
    }

    /// `points` is documented as kept sorted, and the synthesised decoder did not keep it.
    @Test("A decoded curve keeps its points sorted by temperature")
    func decodedCurveSortsItsPoints() throws {
        let json = """
            {"points":[{"temperatureCelsius":80,"rpm":4000},\
            {"temperatureCelsius":40,"rpm":1500}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":150}
            """
        let curve = try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
        #expect(curve.points.map(\.temperatureCelsius) == [40, 80])
        #expect(curve.maximumRampRPMPerSecond == 150)
    }
}

@Suite("Thermal ceilings")
struct ThermalCeilingTests {

    @Test("A configuration may lower a ceiling")
    func allowsLowering() {
        let effective = ThermalCeiling.effective(requested: 85, default: ThermalCeiling.cpuCelsius)
        #expect(effective == 85)
    }

    /// The whole point of a limit no user can defeat is that no user can defeat it.
    @Test("A configuration may not raise a ceiling")
    func rejectsRaising() {
        let effective = ThermalCeiling.effective(requested: 105, default: ThermalCeiling.cpuCelsius)
        #expect(effective == ThermalCeiling.cpuCelsius)
    }

    /// `min(.nan, ceiling)` is NaN, and a NaN ceiling *disables* the override rather than
    /// tightening it: `temperature > ceiling` is false at every temperature. That is a
    /// configuration turning a safety mechanism off, which `docs/SAFETY.md` says cannot
    /// exist. Delete the finiteness guard and the second half of this test goes red.
    @Test("A non-finite ceiling cannot disable the override")
    func nonFiniteCeilingFallsBackToTheDefault() {
        let effective = ThermalCeiling.effective(
            requested: .nan, default: ThermalCeiling.cpuCelsius)

        #expect(effective == ThermalCeiling.cpuCelsius)
        // The consequence, stated rather than implied: a machine at 120 °C must be over
        // whatever ceiling this returned.
        #expect(120 > effective)
    }

    @Test("An infinite ceiling cannot raise the compiled default")
    func infiniteCeilingFallsBackToTheDefault() {
        #expect(
            ThermalCeiling.effective(requested: .infinity, default: ThermalCeiling.cpuCelsius)
                == ThermalCeiling.cpuCelsius)
    }
}
