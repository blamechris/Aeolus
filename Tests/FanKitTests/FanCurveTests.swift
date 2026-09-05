import Foundation
import Testing

@testable import FanKit

/// #106: `min`/`max` propagate NaN, and every comparison against NaN is false. A NaN
/// `hysteresisCelsius` does not raise the falling-temperature margin — it removes it,
/// silently, exactly the way an unguarded `ThermalCeiling.effective(requested:default:)`
/// removed a thermal ceiling in #101. The consequence to test is whether the mechanism
/// still fires, never the stored value in isolation — asserting the value is what let the
/// `ThermalCeiling` defect survive under test.
@Suite("FanCurve.hysteresisCelsius refuses non-finite and negative values")
struct FanCurveHysteresisTests {

    private func curve(hysteresisCelsius: Double) -> FanCurve {
        FanCurve(
            points: [
                FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
                FanCurve.Point(temperatureCelsius: 80, rpm: 5000),
            ],
            source: SensorGroup(sensorKeys: ["TC0P"]),
            hysteresisCelsius: hysteresisCelsius
        )
    }

    @Test("A finite, non-negative hysteresis is carried exactly")
    func finiteHysteresisIsCarriedExactly() {
        #expect(curve(hysteresisCelsius: 4.5).hysteresisCelsius == 4.5)
        #expect(curve(hysteresisCelsius: 0).hysteresisCelsius == 0)
    }

    /// The defect from #106, restated for this field: `min`/`max` propagate NaN and every
    /// comparison against it is false, so a NaN margin does not widen or narrow the
    /// falling-temperature check — it makes every such check false, and hysteresis stops
    /// applying at all. Delete the `isFinite` guard in `effectiveHysteresisCelsius(
    /// requested:)` and this goes red.
    @Test(
        "A non-finite or negative hysteresis falls back to the documented default, never zero",
        arguments: [Double.nan, .infinity, -.infinity, -1, -0.01])
    func nonFiniteOrNegativeHysteresisFallsBackToDefault(_ badValue: Double) {
        let built = curve(hysteresisCelsius: badValue)

        #expect(built.hysteresisCelsius.isFinite)
        #expect(built.hysteresisCelsius >= 0)
        #expect(built.hysteresisCelsius == FanCurve.defaultHysteresisCelsius)
        // Never silently zero: the fallback is a real margin, not the disabled mechanism
        // a NaN would otherwise produce.
        #expect(built.hysteresisCelsius > 0)
    }

    /// JSON is the only route a curve reaches the helper (`CLAUDE.md` rule 7), so the
    /// guard must hold across a decode, not only in code that calls the memberwise
    /// initialiser directly.
    @Test(
        "A non-finite hysteresis decoded from JSON is refused the same way",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteHysteresisIsRefusedOnDecode(_ badValue: Double) throws {
        // Built in Swift, not parsed from a literal JSON string: JSON itself cannot spell
        // NaN or infinity, so the only way a decoder sees one is a payload built the way
        // this test builds it — exactly the shape `AeolusXPCValidation` has to defend
        // against from a hostile or buggy peer.
        struct RawCurve: Encodable {
            let points: [FanCurve.Point]
            let source: SensorGroup
            let hysteresisCelsius: Double
            let maximumRampRPMPerSecond: Double
        }
        let raw = RawCurve(
            points: [FanCurve.Point(temperatureCelsius: 40, rpm: 1500)],
            source: SensorGroup(sensorKeys: ["TC0P"]),
            hysteresisCelsius: badValue,
            maximumRampRPMPerSecond: 100
        )
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let data = try encoder.encode(raw)

        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoded = try decoder.decode(FanCurve.self, from: data)

        #expect(decoded.hysteresisCelsius.isFinite)
        #expect(decoded.hysteresisCelsius == FanCurve.defaultHysteresisCelsius)
    }

    /// The default parameter and the documented fallback must actually agree — otherwise
    /// "falls back to the documented default" is a claim nothing enforces.
    @Test("The memberwise default and the fallback default are the same constant")
    func defaultParameterMatchesFallbackDefault() {
        let curve = FanCurve(
            points: [FanCurve.Point(temperatureCelsius: 40, rpm: 1500)],
            source: SensorGroup(sensorKeys: ["TC0P"])
        )
        #expect(curve.hysteresisCelsius == FanCurve.defaultHysteresisCelsius)
    }
}
