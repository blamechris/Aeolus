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

    private static func sensor(
        key: String, decoration: CatalogDecoration? = nil
    ) -> SensorPollingReading {
        SensorPollingReading(
            key: key, kind: .unknown, sample: .value(key: key, 42), decoration: decoration)
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
        // physical fan under two different sources.
        let sensors = [Self.sensor(key: "F0Ac"), Self.sensor(key: "Tp09")]
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
}
