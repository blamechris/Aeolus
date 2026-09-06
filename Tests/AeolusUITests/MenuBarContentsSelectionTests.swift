import FanKit
import SMCCore
import Testing

@testable import AeolusUI

@Suite("MenuBarContentsSelection — Preferences' full toggle universe and pure add/remove")
struct MenuBarContentsSelectionTests {

    private static func fan(index: Int) -> FanPollingReading {
        FanPollingReading(
            index: index,
            displayName: "Fan \(index)",
            actual: .value(key: "F\(index)Ac", 1712),
            minimum: .value(key: "F\(index)Mn", 1200),
            maximum: .value(key: "F\(index)Mx", 5312))
    }

    private static func sensor(key: String) -> SensorPollingReading {
        SensorPollingReading(key: key, kind: .temperatureCelsius, sample: .value(key: key, 42))
    }

    // MARK: - candidates(fans:sensors:)

    @Test("Every fan and every non-fan sensor becomes a candidate, unfiltered by kind or label")
    func candidatesIncludeEveryFanAndSensor() {
        let candidates = MenuBarContentsSelection.candidates(
            fans: [Self.fan(index: 0)], sensors: [Self.sensor(key: "Tp09")])

        #expect(candidates.contains(MenuBarReadout(key: "F0Ac", source: .fan)))
        #expect(candidates.contains(MenuBarReadout(key: "Tp09", source: .sensor)))
        #expect(candidates.count == 2)
    }

    @Test("A fan's own min/max/actual keys are never duplicated as .sensor candidates")
    func fanKeysAreExcludedFromSensorCandidates() {
        let candidates = MenuBarContentsSelection.candidates(
            fans: [Self.fan(index: 0)],
            sensors: [Self.sensor(key: "F0Ac"), Self.sensor(key: "F0Mn"), Self.sensor(key: "Tp09")])

        let sensorCandidates = candidates.filter { $0.source == .sensor }
        #expect(sensorCandidates.map(\.key) == ["Tp09"])
    }

    @Test("No caps: every sensor becomes a candidate, unlike MenuBarReadoutSelection's default")
    func everySensorIsACandidateRegardlessOfCount() {
        let sensors = (0..<10).map { Self.sensor(key: "Th\($0)H") }
        let candidates = MenuBarContentsSelection.candidates(fans: [], sensors: sensors)

        #expect(candidates.count == 10)
    }

    // MARK: - isIncluded(_:in:defaultSelection:)

    @Test("nil selection falls back to the default selection")
    func nilSelectionFallsBackToDefault() {
        let readout = MenuBarReadout(key: "Tp09", source: .sensor)
        #expect(
            MenuBarContentsSelection.isIncluded(readout, in: nil, defaultSelection: [readout]))
        #expect(
            !MenuBarContentsSelection.isIncluded(readout, in: nil, defaultSelection: []))
    }

    @Test(
        "An explicit selection, including an explicit empty one, is never overridden by the default"
    )
    func explicitSelectionIsNeverOverridden() {
        let readout = MenuBarReadout(key: "Tp09", source: .sensor)
        #expect(
            !MenuBarContentsSelection.isIncluded(readout, in: [], defaultSelection: [readout]))
        #expect(
            MenuBarContentsSelection.isIncluded(readout, in: [readout], defaultSelection: []))
    }

    // MARK: - toggling(_:in:defaultSelection:)

    @Test("Toggling an absent readout in, from nil, starts from the default and adds it")
    func togglingInFromNilStartsFromDefault() {
        let existing = MenuBarReadout(key: "F0Ac", source: .fan)
        let added = MenuBarReadout(key: "Tp09", source: .sensor)

        let result = MenuBarContentsSelection.toggling(
            added, in: nil, defaultSelection: [existing])

        #expect(Set(result) == Set([existing, added]))
    }

    @Test("Toggling a present readout out removes exactly that one")
    func togglingOutRemovesExactlyThatOne() {
        let keep = MenuBarReadout(key: "F0Ac", source: .fan)
        let remove = MenuBarReadout(key: "Tp09", source: .sensor)

        let result = MenuBarContentsSelection.toggling(
            remove, in: [keep, remove], defaultSelection: [])

        #expect(result == [keep])
    }

    @Test("Toggling the last readout out of an explicit selection produces an explicit empty array")
    func togglingTheLastReadoutOutProducesExplicitEmpty() {
        let only = MenuBarReadout(key: "Tp09", source: .sensor)

        let result = MenuBarContentsSelection.toggling(
            only, in: [only], defaultSelection: [only])

        #expect(result.isEmpty)
    }

    @Test("The same key under two different sources toggles independently")
    func sameKeyDifferentSourceTogglesIndependently() {
        let fanReadout = MenuBarReadout(key: "F0Ac", source: .fan)
        let sensorReadout = MenuBarReadout(key: "F0Ac", source: .sensor)

        let result = MenuBarContentsSelection.toggling(
            sensorReadout, in: [fanReadout], defaultSelection: [])

        #expect(Set(result) == Set([fanReadout, sensorReadout]))
    }
}
