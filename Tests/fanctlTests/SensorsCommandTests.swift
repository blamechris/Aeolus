import Foundation
import Testing

@testable import SMCCore
@testable import fanctl

@Suite("fanctl sensors — fetch")
struct SensorsCommandFetchTests {

    @Test("No SMC on this machine surfaces a clear error, not a bare throw")
    func noSMCThrowsClearError() async {
        let provider = FakeSensorProvider(isAvailable: false)
        await #expect(throws: FanctlError.noSMC) {
            try await SensorsCommand.fetch(
                provider: provider, catalog: NoSensorCatalog(), rawKeys: false)
        }
    }

    @Test("An unlabelled sensor renders fully and normally, with no catalog wired in")
    func unlabelledSensorRendersFully() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == nil)
        #expect(entry.confidence == nil)
        #expect(entry.value == 42.5)
        #expect(entry.unit == .celsius)
    }

    @Test("A catalog match decorates the key without ever hiding it")
    func catalogMatchDecoratesWithoutHidingKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])
        let catalog = FakeSensorCatalogLookup(
            labels: [
                "Tp09": SensorCatalogLabel(text: "CPU Efficiency Cluster", confidence: .community)
            ]
        )

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == "CPU Efficiency Cluster")
        #expect(entry.confidence == .community)
    }

    @Test("--raw-keys suppresses the label even when the catalog has a match, but never the key")
    func rawKeysSuppressesLabelNotKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])
        let catalog = FakeSensorCatalogLookup(
            labels: [
                "Tp09": SensorCatalogLabel(text: "CPU Efficiency Cluster", confidence: .verified)
            ]
        )

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: true)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == nil)
        #expect(entry.confidence == nil)
    }

    @Test("Entries are sorted by key for stable, skimmable output")
    func entriesAreSortedByKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [
                .fake(key: "Tp09", value: 1, kind: .temperatureCelsius),
                .fake(key: "F0Ac", value: 2, kind: .rpm),
                .fake(key: "PC0C", value: 3, kind: .watts),
            ])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        #expect(result.entries.map(\.key) == ["F0Ac", "PC0C", "Tp09"])
    }

    @Test("An enumeration failure is reported as a clear, actionable error")
    func enumerationFailureIsClear() async {
        let provider = FakeSensorProvider(
            allError: FakeProviderError(description: "firmware fault"))

        await #expect(throws: FanctlError.self) {
            try await SensorsCommand.fetch(
                provider: provider, catalog: NoSensorCatalog(), rawKeys: false)
        }
    }
}

@Suite("SensorUnit — mirrors AeolusXPC.SensorSample.Unit's raw values")
struct SensorUnitTests {

    @Test("Every SensorReading.Kind maps to its matching unit name")
    func kindMapsToMatchingUnitName() {
        #expect(SensorUnit(kind: .temperatureCelsius) == .celsius)
        #expect(SensorUnit(kind: .rpm) == .rpm)
        #expect(SensorUnit(kind: .watts) == .watts)
        #expect(SensorUnit(kind: .volts) == .volts)
        #expect(SensorUnit(kind: .amps) == .amps)
        #expect(SensorUnit(kind: .percent) == .percent)
        #expect(SensorUnit(kind: .unknown) == .unknown)
    }
}

@Suite("fanctl sensors — rendering")
struct SensorsCommandRenderTests {

    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("JSON output is stable, pretty-printed, sorted, and self-describing")
    func jsonOutputIsStable() throws {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc",
            capturedAt: Self.fixedDate,
            entries: [
                SensorsCommand.Entry(
                    key: "F0Ac", label: nil, confidence: nil, value: 1712, unit: .rpm),
                SensorsCommand.Entry(
                    key: "Tp09", label: "CPU Efficiency Cluster", confidence: .community,
                    value: 42.5, unit: .celsius),
            ])

        let json = try SensorsCommand.renderJSON(result)

        let expected = """
            {
              "capturedAt" : "2023-11-14T22:13:20Z",
              "provider" : "smc",
              "sensorCount" : 2,
              "sensors" : [
                {
                  "key" : "F0Ac",
                  "label" : null,
                  "labelConfidence" : null,
                  "unit" : "rpm",
                  "value" : 1712
                },
                {
                  "key" : "Tp09",
                  "label" : "CPU Efficiency Cluster",
                  "labelConfidence" : "community",
                  "unit" : "celsius",
                  "value" : 42.5
                }
              ]
            }
            """
        #expect(json == expected)
    }

    @Test("An unlabelled sensor still renders a full table row, not a degraded one")
    func unlabelledSensorRendersFullTableRow() {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc",
            capturedAt: Self.fixedDate,
            entries: [
                SensorsCommand.Entry(
                    key: "Tp09", label: nil, confidence: nil, value: 42.5, unit: .celsius)
            ])

        let table = SensorsCommand.renderTable(result)

        #expect(table.contains("Tp09"))
        #expect(table.contains("42.5"))
        #expect(table.contains("celsius"))
    }

    @Test("An empty machine (no sensors) still renders a clear message")
    func emptyResultRendersMessage() {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc", capturedAt: Self.fixedDate, entries: [])
        #expect(SensorsCommand.renderTable(result) == "No sensors found.")
    }
}
