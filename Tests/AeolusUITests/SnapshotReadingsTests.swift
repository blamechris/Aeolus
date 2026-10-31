import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `SnapshotReadings` on its own: one snapshot, as the rows the app draws (#478's review,
/// item 11). The fixture is built to tell apart the mistakes a translation can make — fans out
/// of order, the two bounds swapped, a reason left unclean, a non-finite value shown as one, a
/// label dropped, a key with a control character in it drawn as it is.
@Suite("SnapshotReadings — one snapshot as the app's rows")
struct SnapshotReadingsTests {

    static let decoration = CatalogDecoration(
        key: "TC0P", label: "CPU Proximity", category: .cpu, confidence: .verified)

    /// Two fans in **reverse** order, each with its own minimum and maximum; fan 0's actual is
    /// unavailable with a bidi override in the reason, fan 1's is a non-finite value carried
    /// as a measurement. Three sensors: one labelled, one non-finite, one whose key would draw
    /// a right-to-left override.
    static let snapshot = SystemSnapshot(
        fans: [
            FanState(
                index: 1, actualRPM: .measuredFinite(.nan), minimumRPM: .measured(1200),
                maximumRPM: .measured(6000), targetRPM: nil, mode: .automatic,
                isReclaimedBySystem: false,
                manualControlAvailability: .unavailable(.writePathNotBuilt)),
            FanState(
                index: 0, actualRPM: .unavailable(reason: "x\u{202E}y\nz"),
                minimumRPM: .measured(1350), maximumRPM: .measured(5777), targetRPM: nil,
                mode: .automatic, isReclaimedBySystem: false,
                manualControlAvailability: .unavailable(.writePathNotBuilt)),
        ],
        sensors: [
            SensorSample(
                key: "Tp09", label: nil, labelConfidence: nil, value: .nan, unit: .celsius),
            SensorSample(key: "TC0P", label: nil, labelConfidence: nil, value: 48, unit: .celsius),
            SensorSample(
                key: "T\u{202E}q1", label: nil, labelConfidence: nil, value: 40, unit: .celsius),
        ],
        activeLease: nil, isThermalEmergencyActive: true, capturedAt: Date())

    static let fans = SnapshotReadings.fans(in: snapshot)
    static let sensors = SnapshotReadings.sensors(
        in: snapshot, labelSource: FakeSensorLabelSource(decorationsByKey: ["TC0P": decoration]))

    /// **Mutation (O4):** drop the sort. Run: red here.
    @Test("Fans come out in index order whatever order the snapshot lists them in")
    func fansAreInIndexOrder() {
        #expect(Self.fans.map(\.index) == [0, 1])
        #expect(Self.fans.map(\.displayName) == ["Fan 0", "Fan 1"])
    }

    /// **Mutation (O2):** swap the minimum and maximum keys and readings. Run: red here.
    @Test("Each bound keeps its own key and its own reading")
    func boundsKeepTheirOwnKeys() {
        #expect(Self.fans[0].minimum == .value(key: "F0Mn", 1350))
        #expect(Self.fans[0].maximum == .value(key: "F0Mx", 5777))
        #expect(Self.fans[1].minimum == .value(key: "F1Mn", 1200))
        #expect(Self.fans[1].maximum == .value(key: "F1Mx", 6000))
    }

    /// **Mutation (O3, M-H2):** drop `HelperAuthoredText.sanitised` from `keyed`. Run: red here.
    @Test("A fan's unavailable reason is the helper's text, cleaned")
    func aFanReasonIsCleaned() {
        #expect(Self.fans[0].actual == .unavailable(key: "F0Ac", reason: "xyz"))
    }

    /// **Mutation (O32):** drop `value.isFinite` from `keyed`. Run: red here.
    @Test("A non-finite fan reading is unavailable, never a value")
    func aNonFiniteFanReadingIsUnavailable() {
        #expect(Self.fans[1].actual.key == "F1Ac")
        #expect(!Self.fans[1].actual.isAvailable)
    }

    /// Fan 1's state is compared by index: it carries a NaN measurement, and NaN equals nothing,
    /// itself included.
    @Test("Each fan carries the helper's state and the snapshot's emergency flag")
    func eachFanCarriesItsReport() {
        #expect(Self.fans[0].control == .reported(Self.snapshot.fans[1], thermalEmergency: true))
        guard case .reported(let state, let thermalEmergency) = Self.fans[1].control else {
            Issue.record("fan 1 is not reported")
            return
        }
        #expect(state.index == 1)
        #expect(thermalEmergency)
    }

    /// **Mutation (O29):** `decoration: nil`. Run: red here.
    @Test("A sensor carries the app's own label for its key")
    func aSensorCarriesItsLabel() {
        let labelled = Self.sensors.first { $0.key == "TC0P" }
        #expect(labelled?.decoration == Self.decoration)
        #expect(labelled?.sample == .value(key: "TC0P", 48))
    }

    /// **Mutation (O31):** `sample: true ? .value(…) : …` — a non-finite sensor value shown as
    /// one. Run: red here.
    @Test("A non-finite sensor value is unavailable, never a value")
    func aNonFiniteSensorValueIsUnavailable() {
        let sensor = Self.sensors.first { $0.key == "Tp09" }
        #expect(sensor?.sample.isAvailable == false)
    }

    /// A key of 100 graphemes, each `a` and four combining acute accents: 100 characters, within
    /// the character cap, and 900 bytes, past the byte cap. It must be refused, not drawn.
    ///
    /// **Mutation (VK1):** drop `text.utf8.count <= maxUTF8Bytes` from
    /// `isDisplayableVerbatim`. Run: red at both expectations.
    @Test("A key within the character cap but past the byte cap is refused")
    func aDenseKeyIsRefused() {
        let dense = String(repeating: "a" + String(repeating: "\u{0301}", count: 4), count: 100)
        #expect(dense.count == 100)
        #expect(dense.utf8.count == 900)
        let snapshot = SystemSnapshot(
            fans: [],
            sensors: [
                SensorSample(key: dense, label: nil, labelConfidence: nil, value: 1, unit: .celsius)
            ],
            activeLease: nil, isThermalEmergencyActive: false, capturedAt: Date())

        #expect(!HelperAuthoredText.isDisplayableVerbatim(dense))
        #expect(SnapshotReadings.sensors(in: snapshot, labelSource: NoSensorLabels()).isEmpty)
    }

    /// **Mutation (K1):** drop the `isDisplayableVerbatim` filter. Run: red here.
    @Test("A sensor whose key cannot be shown verbatim is left out, and the rest are sorted")
    func aKeyThatCannotBeShownIsLeftOut() {
        #expect(Self.sensors.map(\.key) == ["TC0P", "Tp09"])
    }
}
