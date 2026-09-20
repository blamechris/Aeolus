import AeolusXPC
import FanKit
import Foundation
import Testing

/// #190's finiteness guards on `FanCurve` and `FanSetting.Control` must not disturb the
/// ordinary case: a well-formed setting carrying a curve still has to survive the exact
/// coders both sides of the privilege boundary use, `AeolusXPCCoding.encoder()` and
/// `.decoder()`, unchanged.
@Suite("A FanSetting carrying a valid curve round-trips through AeolusXPCCoding")
struct FanSettingCurveRoundTripTests {

    @Test("A well-formed curve setting survives encode and decode unchanged")
    func wellFormedCurveSettingRoundTrips() throws {
        let curve = FanCurve(
            points: [
                FanCurve.Point(temperatureCelsius: 40, rpm: 1500),
                FanCurve.Point(temperatureCelsius: 80, rpm: 4000),
            ],
            source: SensorGroup(sensorKeys: ["TC0P"]),
            hysteresisCelsius: 3,
            maximumRampRPMPerSecond: 120
        )
        let setting = FanSetting(fanIndex: 2, control: .curve(curve))

        let data = try AeolusXPCCoding.encoder().encode(setting)
        let decoded = try AeolusXPCCoding.decoder().decode(FanSetting.self, from: data)

        #expect(decoded == setting)
    }
}
