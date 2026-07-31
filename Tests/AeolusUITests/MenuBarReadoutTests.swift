import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

@Suite("MenuBarReadout — resolution, identity, and persistence shape")
struct MenuBarReadoutTests {

    private static func fan(
        index: Int = 0, actualValue: Double = 1712, mode: FanControlMode = .automatic,
        isReclaimedBySystem: Bool = false
    ) -> FanPollingReading {
        FanPollingReading(
            index: index,
            displayName: "Fan \(index)",
            actual: .value(key: "F\(index)Ac", actualValue),
            minimum: .value(key: "F\(index)Mn", 1200),
            maximum: .value(key: "F\(index)Mx", 5312),
            mode: mode,
            isReclaimedBySystem: isReclaimedBySystem)
    }

    private static func sensor(
        key: String = "Tp09", kind: SensorReading.Kind = .unknown, value: Double = 44.2,
        decoration: CatalogDecoration? = nil
    ) -> SensorPollingReading {
        SensorPollingReading(
            key: key, kind: kind, sample: .value(key: key, value), decoration: decoration)
    }

    // MARK: - Resolution

    @Test("A .fan readout resolves to that fan's actual RPM, labelled with its display name")
    func fanReadoutResolvesToActualRPM() {
        let readout = MenuBarReadout(key: "F0Ac", source: .fan)
        let resolved = readout.resolve(fans: [Self.fan()], sensors: [])

        #expect(resolved.key == "F0Ac")
        #expect(resolved.label == "Fan 0")
        #expect(resolved.kind == .rpm)
        #expect(resolved.reading.value == 1712)
        #expect(resolved.fanControlState?.mode == .automatic)
        #expect(resolved.fanControlState?.isReclaimedBySystem == false)
    }

    @Test("A .fan readout carries reclamation and mode honestly when a fan reports them")
    func fanReadoutCarriesReclamationHonestly() {
        let readout = MenuBarReadout(key: "F0Ac", source: .fan)
        let reclaimedFan = Self.fan(mode: .manualFixed, isReclaimedBySystem: true)
        let resolved = readout.resolve(fans: [reclaimedFan], sensors: [])

        #expect(resolved.fanControlState?.mode == .manualFixed)
        #expect(resolved.fanControlState?.isReclaimedBySystem == true)
    }

    @Test("A .sensor readout resolves to that sensor's sample, with its catalog label if any")
    func sensorReadoutResolvesToSample() {
        let decoration = CatalogDecoration(
            key: "Tp09", label: "CPU Proximity", category: .cpu, confidence: .verified)
        let readout = MenuBarReadout(key: "Tp09", source: .sensor)
        let resolved = readout.resolve(
            fans: [], sensors: [Self.sensor(decoration: decoration)])

        #expect(resolved.key == "Tp09")
        #expect(resolved.label == "CPU Proximity")
        #expect(resolved.reading.value == 44.2)
        #expect(resolved.fanControlState == nil)
    }

    @Test("An unlabelled sensor resolves fully, with a nil label rather than a degraded result")
    func unlabelledSensorResolvesFully() {
        let readout = MenuBarReadout(key: "Tp09", source: .sensor)
        let resolved = readout.resolve(fans: [], sensors: [Self.sensor()])

        #expect(resolved.label == nil)
        #expect(resolved.reading.value == 44.2)
    }

    @Test("A .fan readout naming a key no longer reported resolves unavailable, never dropped")
    func missingFanResolvesUnavailableNeverDropped() {
        let readout = MenuBarReadout(key: "F1Ac", source: .fan)
        let resolved = readout.resolve(fans: [Self.fan(index: 0)], sensors: [])

        #expect(resolved.key == "F1Ac")
        #expect(resolved.reading.value == nil)
        guard case .unavailable = resolved.reading.availability else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("A .sensor readout naming a key no longer reported resolves unavailable, never dropped")
    func missingSensorResolvesUnavailableNeverDropped() {
        let readout = MenuBarReadout(key: "Th1H", source: .sensor)
        let resolved = readout.resolve(fans: [], sensors: [Self.sensor(key: "Tp09")])

        #expect(resolved.key == "Th1H")
        #expect(resolved.reading.value == nil)
    }

    // MARK: - Identity

    @Test("The same raw key as both a fan and a sensor source produces two distinct ids")
    func sameKeyDifferentSourceHasDistinctIdentity() {
        let fanReadout = MenuBarReadout(key: "F0Ac", source: .fan)
        let sensorReadout = MenuBarReadout(key: "F0Ac", source: .sensor)

        #expect(fanReadout.id != sensorReadout.id)
        #expect(fanReadout != sensorReadout)
    }

    // MARK: - Persistence shape

    @Test("MenuBarReadout round-trips through JSON — the shape #64 persists")
    func roundTripsThroughJSON() throws {
        let original = [
            MenuBarReadout(key: "F0Ac", source: .fan),
            MenuBarReadout(key: "Tp09", source: .sensor),
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([MenuBarReadout].self, from: data)

        #expect(decoded == original)
    }
}
