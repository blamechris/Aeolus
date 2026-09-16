import FanKit
import SMCCore
import Testing

@testable import AeolusUI

@Suite("MenuBarReadoutSelection — the default readout set computed from a live poll")
struct MenuBarReadoutSelectionTests {

    private static func fan(index: Int) -> FanPollingReading {
        FanPollingReading(
            index: index,
            displayName: "Fan \(index)",
            actual: .value(key: "F\(index)Ac", 1712),
            minimum: .value(key: "F\(index)Mn", 1200),
            maximum: .value(key: "F\(index)Mx", 5312))
    }

    /// `kind` defaults to `.temperatureCelsius`, not `.unknown`: most of these tests are
    /// about ordinary sensor candidates, and a real `kind` is what lets a candidate reach
    /// the unlabelled fallback at all after this type's kind filter — see
    /// `MenuBarReadoutSelection`'s "labelled is trusted" documentation. Tests that
    /// specifically exercise the `#KEY`/`AC-B`-shaped exclusion pass `kind: .unknown`
    /// explicitly at the call site, so the intent is never implicit.
    private static func sensor(
        key: String, kind: SensorReading.Kind = .temperatureCelsius,
        decoration: CatalogDecoration? = nil
    ) -> SensorPollingReading {
        SensorPollingReading(
            key: key, kind: kind, sample: .value(key: key, 42), decoration: decoration)
    }

    @Test("Every fan gets its own .fan-sourced default readout")
    func everyFanGetsADefaultReadout() {
        let selection = MenuBarReadoutSelection.defaultSelection(
            fans: [Self.fan(index: 0), Self.fan(index: 1)], sensors: [])

        let fanReadouts = selection.filter { $0.source == .fan }
        #expect(fanReadouts.map(\.key) == ["F0Ac", "F1Ac"])
    }

    @Test("With no labelled sensors, the default falls back to discovery order")
    func fallsBackToDiscoveryOrderWhenNothingIsLabelled() {
        let sensors = [
            Self.sensor(key: "Tp09"), Self.sensor(key: "Th1H"), Self.sensor(key: "Th2H"),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        let sensorReadouts = selection.filter { $0.source == .sensor }
        #expect(sensorReadouts.count == MenuBarReadoutSelection.maximumDefaultSensors)
        #expect(sensorReadouts.map(\.key) == ["Tp09", "Th1H"])
    }

    @Test("Labelled sensors are preferred over unlabelled ones, even out of discovery order")
    func labelledSensorsArePreferred() {
        let decoration = CatalogDecoration(
            key: "Th2H", label: "GPU Proximity", category: .gpu, confidence: .community)
        let sensors = [
            Self.sensor(key: "Tp09"), Self.sensor(key: "Th1H"),
            Self.sensor(key: "Th2H", decoration: decoration),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        let sensorKeys = selection.filter { $0.source == .sensor }.map(\.key)
        #expect(sensorKeys == ["Th2H"])
    }

    @Test("A fan's own keys are never also picked as .sensor readouts by default")
    func fanKeysAreExcludedFromSensorDefaults() {
        // SensorPoller.discover(provider:) enumerates every key readAll() reports,
        // including fan keys — see MenuBarReadout's own documentation for why the same
        // raw key can appear in both lists. The default must not double up on the same
        // physical fan under two different sources. F0Ac is given a real (.rpm) kind
        // here, same as SMCSensorProvider.kind(for:) would actually classify it — this
        // test isolates the fan-key exclusion from the separate kind-filter behaviour
        // covered elsewhere in this suite.
        let sensors = [Self.sensor(key: "F0Ac", kind: .rpm), Self.sensor(key: "Tp09")]
        let selection = MenuBarReadoutSelection.defaultSelection(
            fans: [Self.fan(index: 0)], sensors: sensors)

        let sensorKeys = selection.filter { $0.source == .sensor }.map(\.key)
        #expect(!sensorKeys.contains("F0Ac"))
        #expect(sensorKeys == ["Tp09"])
    }

    @Test("No fans and no sensors produces an empty, not a crashing, selection")
    func emptyInputProducesEmptySelection() {
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: [])
        #expect(selection.isEmpty)
    }

    @Test("The default never exceeds maximumDefaultSensors non-fan readouts")
    func neverExceedsMaximumDefaultSensors() {
        let sensors = (0..<10).map { Self.sensor(key: "Th\($0)H") }
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        #expect(
            selection.filter { $0.source == .sensor }.count
                == MenuBarReadoutSelection.maximumDefaultSensors)
    }

    // MARK: - The #KEY / AC-B regression

    @Test("An unlabelled, kind-.unknown candidate is never chosen as a default")
    func unknownKindCandidatesAreExcludedFromTheUnlabelledFallback() {
        // The exact bug this guards: on real hardware with no catalog source wired in,
        // the first two non-fan keys SensorPoller.discover(provider:) reports are #KEY
        // (the SMC's own declared key count, 3385 on this project's development
        // hardware) and AC-B (an internal sentinel, -1) — neither a measurement, both
        // classified .unknown by SMCSensorProvider.kind(for:) because nothing about
        // their names matches the fan-key convention that kind classification trusts.
        let sensors = [
            Self.sensor(key: "#KEY", kind: .unknown),
            Self.sensor(key: "AC-B", kind: .unknown),
            Self.sensor(key: "Tp09", kind: .temperatureCelsius),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        let sensorKeys = selection.filter { $0.source == .sensor }.map(\.key)
        #expect(!sensorKeys.contains("#KEY"))
        #expect(!sensorKeys.contains("AC-B"))
        #expect(sensorKeys == ["Tp09"])
    }

    @Test("Only kind-.unknown, unlabelled candidates produces an empty sensor default")
    func onlyUnknownKindCandidatesProducesAnEmptySensorDefault() {
        let sensors = [
            Self.sensor(key: "#KEY", kind: .unknown),
            Self.sensor(key: "AC-B", kind: .unknown),
            Self.sensor(key: "AC-C", kind: .unknown),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(
            fans: [Self.fan(index: 0)], sensors: sensors)

        // Still one .fan readout — only the sensor half of the default is empty.
        #expect(selection.filter { $0.source == .fan }.count == 1)
        #expect(selection.filter { $0.source == .sensor }.isEmpty)
    }

    @Test("A catalog-labelled candidate is chosen even if its own kind is .unknown")
    func labelledUnknownKindCandidateIsStillChosen() {
        // Trusting the catalog regardless of kind is deliberate for an ordinary
        // unclassified sensor: a human curated this entry via E6, so it is not held to
        // the same "prove it" bar as an unlabelled key. This is deliberately not F0Md —
        // see controlPlaneKeysAreNeverDefaultedEvenWhenLabelled below for why a
        // fan-control-shaped key is excluded regardless of label.
        let decoration = CatalogDecoration(
            key: "Th9J", label: "Battery Proximity", category: .battery, confidence: .verified)
        let sensors = [Self.sensor(key: "Th9J", kind: .unknown, decoration: decoration)]
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        #expect(selection.filter { $0.source == .sensor }.map(\.key) == ["Th9J"])
    }

    // MARK: - The #249 regression: F0Md / F0Tg

    @Test(
        "F0Md and F0Tg are never defaulted even when catalog-labelled — the real machine's shape"
    )
    func controlPlaneKeysAreNeverDefaultedEvenWhenLabelled() {
        // The exact shape #249 found on real hardware: both F0Md and F0Tg are
        // catalog-labelled (a human curated them via E6, and the labels are correct —
        // "Fan 0 Mode" and "Fan 0 Target Speed" are accurate descriptions), yet neither
        // is a live measurement fit to default to. F0Md's kind is .unknown under
        // SMCSensorProvider.kind(for:); F0Tg's is .rpm (its suffix matches the fan-key
        // convention) — the fix cannot be "trust kind" alone, because F0Tg's kind
        // already looks exactly like a real RPM sensor's.
        let modeDecoration = CatalogDecoration(
            key: "F0Md", label: "Fan 0 Mode", category: .fan, confidence: .verified)
        let targetDecoration = CatalogDecoration(
            key: "F0Tg", label: "Fan 0 Target Speed", category: .fan, confidence: .verified)
        let sensors = [
            Self.sensor(key: "F0Md", kind: .unknown, decoration: modeDecoration),
            Self.sensor(key: "F0Tg", kind: .rpm, decoration: targetDecoration),
            Self.sensor(key: "Tp09"),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(
            fans: [Self.fan(index: 0)], sensors: sensors)

        let sensorKeys = selection.filter { $0.source == .sensor }.map(\.key)
        #expect(!sensorKeys.contains("F0Md"))
        #expect(!sensorKeys.contains("F0Tg"))
        #expect(sensorKeys == ["Tp09"])
        // The fan itself is still defaulted as usual — only the sensor-shaped
        // control-plane keys are excluded.
        #expect(selection.filter { $0.source == .fan }.map(\.key) == ["F0Ac"])
    }

    @Test("A second fan's F1Md/F1Tg are excluded the same way as fan 0's")
    func controlPlaneExclusionGeneralisesPastFanZero() {
        let sensors = [
            Self.sensor(
                key: "F1Md",
                decoration: CatalogDecoration(
                    key: "F1Md", label: "Fan 1 Mode", category: .fan, confidence: .verified)),
            Self.sensor(
                key: "F1Tg", kind: .rpm,
                decoration: CatalogDecoration(
                    key: "F1Tg", label: "Fan 1 Target Speed", category: .fan,
                    confidence: .verified)),
        ]
        let selection = MenuBarReadoutSelection.defaultSelection(fans: [], sensors: sensors)

        #expect(selection.filter { $0.source == .sensor }.isEmpty)
    }
}
