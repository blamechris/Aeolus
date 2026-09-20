import Foundation
import Testing

@testable import FanKit

/// #106: `min`/`max` propagate NaN, and every comparison against NaN is false. A NaN
/// `hysteresisCelsius` does not raise the falling-temperature margin — it removes it,
/// silently, exactly the way an unguarded `ThermalCeiling.effective(requested:default:)`
/// removed a thermal ceiling in #101.
///
/// The full standard #106 sets — assert the *consequence* (does the mechanism still
/// fire?), never the stored value in isolation — is what caught the `ThermalCeiling`
/// defect in #101, where a curve *evaluating* against the margin already existed. This
/// suite cannot apply it yet: hysteresis *evaluation* is E8b
/// ([#17](https://github.com/blamechris/Aeolus/issues/17)) and does not exist in this
/// codebase, so there is no "does the fan still hold" behaviour here to assert against.
/// What follows guards the stored value's shape — finite, non-negative, falling back to a
/// real margin rather than a disabled one — so that once E8b's evaluation lands, this
/// field cannot have been the thing quietly holding a NaN or infinity the whole time.
/// Re-visit this suite when #17 lands and add the consequence assertion then.
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

/// #190: the second `FanCurve` field with a non-finite hole — `Point`, not
/// `hysteresisCelsius` — closed with the opposite fallback. There is no default *curve* to
/// fall back to the way there is a default hysteresis, so the built-in-code initialiser
/// empties the whole curve rather than substituting anything, and the decode-side
/// initialiser refuses outright. See `FanCurve.points` and `init(points:source:
/// hysteresisCelsius:maximumRampRPMPerSecond:)` for the reasoning.
@Suite("FanCurve.points refuses any non-finite point, all or nothing")
struct FanCurvePointFinitenessTests {

    private let source = SensorGroup(sensorKeys: ["TC0P"])

    /// The defect this closes: NaN is never `<` anything, so a `sorted()` fed one does not
    /// raise, it silently produces an incoherent order. Delete the
    /// `points.allSatisfy(\.isFinite)` guard in the memberwise initialiser and this goes
    /// red, because the very same input would then decode to a non-empty, wrongly-ordered
    /// curve instead of an empty one.
    @Test("A curve containing one NaN temperature is emptied, not silently re-sorted")
    func nanTemperaturePointEmptiesTheCurve() {
        let points = [
            FanCurve.Point(temperatureCelsius: 80, rpm: 4000),
            FanCurve.Point(temperatureCelsius: .nan, rpm: 2000),
            FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
        ]

        let curve = FanCurve(points: points, source: source)
        #expect(curve.points.isEmpty)
    }

    /// The control for the test above: the same finite points, minus the bad one, sort
    /// correctly — so a passing suite is distinguishing "the guard fired" from "sorting
    /// itself is broken", not accidentally passing both by emptying every curve.
    @Test("The same finite points, without the bad one, still sort by temperature")
    func sameFinitePointsWithoutTheBadOneSort() {
        let points = [
            FanCurve.Point(temperatureCelsius: 80, rpm: 4000),
            FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
        ]

        let curve = FanCurve(points: points, source: source)
        #expect(curve.points.map(\.temperatureCelsius) == [40, 80])
    }

    /// NaN is not orderable, but an infinity *is* — `sorted()` would place it without
    /// complaint at whichever end it belongs. A guard that only checked `isNaN` would leave
    /// this half of the defect open; `isFinite` closes both from one condition.
    @Test(
        "An infinite temperature is refused the same as NaN",
        arguments: [Double.infinity, -.infinity])
    func infiniteTemperatureEmptiesTheCurve(_ badTemperature: Double) {
        let points = [
            FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
            FanCurve.Point(temperatureCelsius: badTemperature, rpm: 2000),
        ]

        #expect(FanCurve(points: points, source: source).points.isEmpty)
    }

    @Test(
        "A non-finite rpm empties the curve the same as a non-finite temperature",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteRPMEmptiesTheCurve(_ badRPM: Double) {
        let points = [
            FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
            FanCurve.Point(temperatureCelsius: 80, rpm: badRPM),
        ]

        #expect(FanCurve(points: points, source: source).points.isEmpty)
    }
}

/// `FanCurve.init(from:)`'s half of #190: the decode boundary refuses a non-finite point
/// rather than reproducing the in-process empty-curve fallback, so a client that sent one
/// is told so instead of receiving a curve that quietly commands nothing.
@Suite("FanCurve.init(from:) refuses a non-finite point rather than emptying it")
struct FanCurveDecodeFinitenessTests {

    /// `.convertFromString` is what makes a non-finite `Double` reachable through JSON at
    /// all. `AeolusXPCCoding.decoder()` uses the default `nonConformingFloatDecodingStrategy`
    /// (`.throw`), under which `JSONDecoder` refuses a `NaN`/`Infinity` token before
    /// `FanCurve.init(from:)` is ever entered — so a test against that decoder could not
    /// reach this guard at all, and would prove nothing about it either way. This
    /// configuration is what a *future* decoder would need to look like for the guard to
    /// matter, which is exactly the shape `FanCurveHysteresisTests` already uses for the
    /// same reason.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    /// Delete the `points.allSatisfy(\.isFinite)` guard in `init(from:)` and this decodes
    /// to an empty curve instead of throwing.
    @Test("A curve payload with a non-finite temperature throws rather than decoding empty")
    func nonFiniteTemperatureThrows() {
        let json = """
            {"points":[{"temperatureCelsius":"NaN","rpm":1500}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}
            """
        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanCurve.self, from: Data(json.utf8))
        }
    }

    @Test("A curve payload with a non-finite rpm throws rather than decoding empty")
    func nonFiniteRPMThrows() {
        let json = """
            {"points":[{"temperatureCelsius":40,"rpm":"Infinity"}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}
            """
        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanCurve.self, from: Data(json.utf8))
        }
    }

    /// The guard has to be selective, not "decoding is broken under this decoder
    /// configuration" — a well-formed curve still has to decode under the same decoder, or
    /// the two tests above would pass just as happily with `init(from:)` throwing on
    /// everything.
    @Test("A well-formed curve still decodes under the same decoder")
    func wellFormedCurveStillDecodes() throws {
        let json = """
            {"points":[{"temperatureCelsius":80,"rpm":4000},\
            {"temperatureCelsius":40,"rpm":1500}],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}
            """
        let curve = try self.decoder().decode(FanCurve.self, from: Data(json.utf8))
        #expect(curve.points.map(\.temperatureCelsius) == [40, 80])
    }
}
