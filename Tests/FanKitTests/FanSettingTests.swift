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

    /// Delete the finiteness check in `FanSetting.init(from:)` and this decodes to a
    /// `.fixed(rpm: .nan)` (silently normalised nowhere, since a synthesised path was
    /// bypassed) instead of throwing.
    @Test("A non-finite fixed speed decoded from JSON throws rather than being normalised")
    func nonFiniteFixedRPMDecodedThrows() {
        let json = """
            {"fanIndex":0,"control":{"fixed":{"rpm":"NaN"}}}
            """
        #expect(throws: DecodingError.self) {
            try self.decoder().decode(FanSetting.self, from: Data(json.utf8))
        }
    }

    /// The guard has to be selective: a well-formed `.fixed` still has to decode under the
    /// same decoder, or the test above would pass just as happily with `init(from:)`
    /// throwing on every `.fixed` control regardless of its value.
    @Test("A well-formed fixed speed still decodes under the same decoder")
    func wellFormedFixedRPMStillDecodes() throws {
        let json = """
            {"fanIndex":0,"control":{"fixed":{"rpm":3000}}}
            """
        let setting = try self.decoder().decode(FanSetting.self, from: Data(json.utf8))

        guard case .fixed(let rpm) = setting.control else {
            Issue.record("expected .fixed, got \(setting.control)")
            return
        }
        #expect(rpm == 3000)
        #expect(setting.fanIndex == 0)
    }
}
