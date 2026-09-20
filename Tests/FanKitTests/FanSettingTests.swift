import Foundation
import Testing

@testable import FanKit

/// #190: the same non-finite-threshold sweep applied to `FanSetting.Control.fixed(rpm:)`.
/// A `.fixed(rpm:)` that is not a number cannot be honoured, so a setting built in code
/// normalises it to `.automatic` — the honest, control-free answer, per CLAUDE.md rule 6 —
/// while a setting arriving over the wire is refused outright, the same two-tier shape
/// `FanCurve` uses for its own points.
@Suite("FanSetting.Control.fixed(rpm:) refuses non-finite speeds")
struct FanSettingFixedRPMTests {

    /// Consequence, not stored value: asserted on the *case*, not merely that `rpm`
    /// changed, because a fallback that clamped to some other RPM would also pass an
    /// assertion on `rpm` alone while still claiming a control this project cannot honour.
    /// Delete `normalizedControl(_:)`'s call in `FanSetting.init(fanIndex:control:)` and
    /// this goes red: the stored control stays `.fixed` with a NaN or infinite payload.
    @Test(
        "A non-finite fixed speed built in code becomes automatic, not a claimed target",
        arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteFixedRPMBecomesAutomatic(_ badRPM: Double) {
        let setting = FanSetting(fanIndex: 0, control: .fixed(rpm: badRPM))

        guard case .automatic = setting.control else {
            Issue.record("expected .automatic, got \(setting.control)")
            return
        }
    }

    @Test("A finite fixed speed built in code is carried exactly")
    func finiteFixedRPMIsCarriedExactly() {
        let setting = FanSetting(fanIndex: 0, control: .fixed(rpm: 3000))

        guard case .fixed(let rpm) = setting.control else {
            Issue.record("expected .fixed, got \(setting.control)")
            return
        }
        #expect(rpm == 3000)
    }

    /// The route a non-finite speed could otherwise reach the helper by: JSON built the
    /// way a hostile or buggy client's payload would be, decoded with the same
    /// `.convertFromString` configuration `FanCurveDecodeFinitenessTests` uses for the
    /// identical reason — `AeolusXPCCoding.decoder()`'s default strategy cannot carry a
    /// literal NaN or infinity at all, so this is the decoder a future configuration would
    /// need to look like for the guard below to matter.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    /// Delete the `Control.isHonourable` check in `FanSetting.init(from:)` and this decodes
    /// to a `.fixed` carrying the bad speed instead of throwing.
    ///
    /// **Parameterised over all three non-finite tokens, and that is not padding.** A review
    /// found the surviving mutation this closes: with the predicate written out twice, one
    /// copy could be narrowed from `!rpm.isFinite` to `rpm.isNaN` and the suite stayed green,
    /// because this test covered only `"NaN"`. An infinity then fell through to the
    /// memberwise initialiser and was silently normalised to `.automatic` — the boundary
    /// repairing what it is written to refuse. `Control.isHonourable` is now the single
    /// predicate, so there is one site to narrow; this covers the other half of it.
    @Test(
        "A non-finite fixed speed decoded from JSON throws rather than being normalised",
        arguments: ["NaN", "Infinity", "-Infinity"])
    func nonFiniteFixedRPMDecodedThrows(_ token: String) {
        let json = """
            {"fanIndex":0,"control":{"fixed":{"rpm":"\(token)"}}}
            """
        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanSetting.self, from: Data(json.utf8))
        }
    }

    /// The other arm of `Control.isHonourable`: a curve with no points commands nothing, so
    /// a `.curve` holding one is refused on the wire and normalised in code rather than
    /// being carried as a setting that names a curve and has none.
    @Test("A curve with no points is refused on the wire")
    func emptyCurveDecodedThrows() {
        let json = """
            {"fanIndex":0,"control":{"curve":{"_0":{"points":[],\
            "source":{"sensorKeys":["TC0P"],"aggregation":"maximum"},\
            "hysteresisCelsius":2,"maximumRampRPMPerSecond":100}}}}
            """
        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanSetting.self, from: Data(json.utf8))
        }
    }

    /// And the consequence the empty-curve arm exists for: a curve built in code from points
    /// that were all non-finite is emptied by `FanCurve`, and the setting carrying it then
    /// reads `.automatic` rather than "drive this fan from a curve" with no curve to drive
    /// it from. Delete the `.curve` arm of `Control.isHonourable` and this goes red.
    @Test("A setting built from an all-bad curve reads as automatic, not as an empty curve")
    func settingFromAnEmptiedCurveBecomesAutomatic() {
        let curve = FanCurve(
            points: [FanCurve.Point(temperatureCelsius: .nan, rpm: 2000)],
            source: SensorGroup(sensorKeys: ["TC0P"]))
        #expect(curve.points.isEmpty, "the fixture did not reach the state under test")

        let setting = FanSetting(fanIndex: 0, control: .curve(curve))

        guard case .automatic = setting.control else {
            Issue.record("expected .automatic, got \(setting.control)")
            return
        }
    }

    /// Every field stays required, the `FanCurve` analogue of which
    /// `DownwardOnlyLimitTests.curvePayloadMissingAFieldDoesNotDecode` already pins. A new
    /// custom `init(from:)` is exactly where a later edit slips a `decodeIfPresent` in and
    /// relaxes the wire contract with nothing red.
    @Test("A settings payload missing a field does not decode", arguments: ["fanIndex", "control"])
    func settingPayloadMissingAFieldDoesNotDecode(_ omitted: String) throws {
        let fields = [
            "fanIndex": "2",
            "control": #"{"fixed":{"rpm":3000}}"#,
        ].filter { $0.key != omitted }
        let json = "{" + fields.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"

        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanSetting.self, from: Data(json.utf8))
        }
    }

    /// The guard has to be selective: a well-formed `.fixed` still has to decode under the
    /// same decoder, or the test above would pass just as happily with `init(from:)`
    /// throwing on every `.fixed` control regardless of its value.
    ///
    /// `fanIndex` is deliberately **not** 0: asserting it against the value `Int()` would
    /// produce anyway cannot tell a decoded index from a dropped one.
    @Test("A well-formed fixed speed still decodes under the same decoder")
    func wellFormedFixedRPMStillDecodes() throws {
        let json = """
            {"fanIndex":2,"control":{"fixed":{"rpm":3000}}}
            """
        let setting = try self.decoder().decode(FanSetting.self, from: Data(json.utf8))

        guard case .fixed(let rpm) = setting.control else {
            Issue.record("expected .fixed, got \(setting.control)")
            return
        }
        #expect(rpm == 3000)
        #expect(setting.fanIndex == 2)
    }
}
