import FanKit
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
        #expect(entry.category == nil)
        #expect(entry.confidence == nil)
        #expect(entry.value == 42.5)
        #expect(entry.error == nil)
        #expect(entry.unit == .celsius)
    }

    @Test("A catalog match decorates the key without ever hiding it")
    func catalogMatchDecoratesWithoutHidingKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])
        let catalog = FakeSensorCatalogLookup(
            labels: [
                "Tp09": SensorCatalogLabel(
                    text: "CPU Efficiency Cluster", category: .cpu, confidence: .community)
            ]
        )

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == "CPU Efficiency Cluster")
        #expect(entry.category == .cpu)
        #expect(entry.confidence == .community)
    }

    @Test("--raw-keys suppresses the label even when the catalog has a match, but never the key")
    func rawKeysSuppressesLabelNotKey() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])
        let catalog = FakeSensorCatalogLookup(
            labels: [
                "Tp09": SensorCatalogLabel(
                    text: "CPU Efficiency Cluster", category: .cpu, confidence: .verified)
            ]
        )

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: true)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == nil)
        #expect(entry.category == nil)
        #expect(entry.confidence == nil)
    }

    @Test("fetch decorates through the real CatalogSensorLookup, end to end, not just a fake")
    func fetchDecoratesThroughRealCatalogSensorLookup() async throws {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["Mac16,5"]),
                    label: "CPU Efficiency Cluster", category: .cpu, confidence: .verified)
            ])
        let hardware = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")
        let lookup = CatalogSensorLookup(catalog: catalog, hardware: hardware)
        let provider = FakeSensorProvider(
            allReadings: [
                .fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius),
                .fake(key: "F0Ac", value: 1712, kind: .rpm),
            ])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: lookup, rawKeys: false)

        let labelled = try #require(result.entries.first { $0.key == "Tp09" })
        #expect(labelled.label == "CPU Efficiency Cluster")
        #expect(labelled.category == .cpu)
        #expect(labelled.confidence == .verified)

        // A key the catalog never mentions still renders fully, unlabelled.
        let unmatched = try #require(result.entries.first { $0.key == "F0Ac" })
        #expect(unmatched.label == nil)
        #expect(unmatched.category == nil)
        #expect(unmatched.confidence == nil)
        #expect(unmatched.value == 1712)
    }

    @Test("A catalog entry scoped to a different model never decorates this machine's reading")
    func fetchHonoursHardwareMismatchThroughRealCatalogSensorLookup() async throws {
        let catalog = SensorCatalog(
            schemaVersion: 1,
            entries: [
                CatalogEntry(
                    key: "Tp09", match: CatalogMatch(modelIdentifier: ["MacBookAir10,1"]),
                    label: "CPU cluster (M1 Air)", category: .cpu, confidence: .verified)
            ])
        let thisMachine = HardwareIdentity(modelIdentifier: "Mac16,5", chipFamily: "M4 Max")
        let lookup = CatalogSensorLookup(catalog: catalog, hardware: thisMachine)
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42.5, kind: .temperatureCelsius)])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: lookup, rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.key == "Tp09")
        #expect(entry.label == nil)
        #expect(entry.category == nil)
        #expect(entry.confidence == nil)
        #expect(entry.value == 42.5)
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

    @Test(
        "A non-finite reading is sanitised into null + an error, never crashes either renderer",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteReadingIsSanitised(_ nonFiniteValue: Double) async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: nonFiniteValue, kind: .temperatureCelsius)])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.value == nil)
        #expect(entry.error != nil)

        let table = SensorsCommand.renderTable(result)
        #expect(table.contains("unavailable"))
        let json = try SensorsCommand.renderJSON(result)
        #expect(json.contains("\"error\""))
    }

    @Test(
        "A large-but-finite reading renders successfully, not as a sanitised failure",
        arguments: [Double(UInt64.max), Double(Float.greatestFiniteMagnitude)]
    )
    func largeFiniteReadingRendersSuccessfully(_ hugeValue: Double) async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "B0RM", value: hugeValue, kind: .unknown)])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        let entry = try #require(result.entries.first)
        #expect(entry.value == hugeValue)
        #expect(entry.error == nil)

        _ = SensorsCommand.renderTable(result)
        _ = try SensorsCommand.renderJSON(result)
    }

    @Test("keysDeclared and keysSkipped surface what readAll() silently dropped")
    func keysDeclaredAndSkippedSurfaceDrops() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 1, kind: .temperatureCelsius)],
            keyedResults: ["#KEY": .success(.fake(key: "#KEY", value: 3385))])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        #expect(result.keysDeclared == 3385)
        let json = try SensorsCommand.renderJSON(result)
        #expect(json.contains("\"keysDeclared\" : 3385"))
        #expect(json.contains("\"keysSkipped\" : 3384"))
    }

    @Test("keysDeclared is nil, not a crash, when #KEY itself cannot be read")
    func keysDeclaredIsNilWhenUnavailable() async throws {
        // No "#KEY" stub: FakeSensorProvider.read(keys:) reports .unknownKey for it —
        // see declaredKeyCount(provider:)'s best-effort, silent-on-failure contract.
        let provider = FakeSensorProvider(allReadings: [])

        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: NoSensorCatalog(), rawKeys: false)

        #expect(result.keysDeclared == nil)
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
                    key: "F0Ac", label: nil, category: nil, confidence: nil, value: 1712,
                    error: nil, unit: .rpm),
                SensorsCommand.Entry(
                    key: "Tp09", label: "CPU Efficiency Cluster", category: .cpu,
                    confidence: .community, value: 42.5, error: nil, unit: .celsius),
            ],
            keysDeclared: 3385)

        let json = try SensorsCommand.renderJSON(result)

        let expected = """
            {
              "capturedAt" : "2023-11-14T22:13:20Z",
              "keysDeclared" : 3385,
              "keysSkipped" : 3383,
              "provider" : "smc",
              "sensorCount" : 2,
              "sensors" : [
                {
                  "category" : null,
                  "error" : null,
                  "key" : "F0Ac",
                  "label" : null,
                  "labelConfidence" : null,
                  "unit" : "rpm",
                  "value" : 1712
                },
                {
                  "category" : "cpu",
                  "error" : null,
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

    @Test("keysDeclared/keysSkipped are omitted, not a crash, when unavailable")
    func keysDeclaredOmittedWhenUnavailable() throws {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc", capturedAt: Self.fixedDate, entries: [], keysDeclared: nil)

        let json = try SensorsCommand.renderJSON(result)

        #expect(!json.contains("keysDeclared"))
        #expect(!json.contains("keysSkipped"))
    }

    @Test("An unlabelled sensor still renders a full table row, not a degraded one")
    func unlabelledSensorRendersFullTableRow() {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc",
            capturedAt: Self.fixedDate,
            entries: [
                SensorsCommand.Entry(
                    key: "Tp09", label: nil, category: nil, confidence: nil, value: 42.5,
                    error: nil, unit: .celsius)
            ],
            keysDeclared: nil)

        let table = SensorsCommand.renderTable(result)

        #expect(table.contains("Tp09"))
        #expect(table.contains("42.5"))
        #expect(table.contains("celsius"))
    }

    @Test("An empty machine (no sensors) still renders a clear message")
    func emptyResultRendersMessage() {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc", capturedAt: Self.fixedDate, entries: [], keysDeclared: nil)
        #expect(SensorsCommand.renderTable(result) == "No sensors found.")
    }

    /// Pins the table's column *positions*, not just their presence: a `.contains`
    /// check alone would still pass if `category`/`confidence` were ever swapped in the
    /// row builder, since both are plain strings in one `[String]` row. Splitting on
    /// whitespace and comparing by column index (safe here — no cell value has a space)
    /// catches a confidence value rendered under CATEGORY, or vice versa.
    @Test("The labelled row's CATEGORY and CONFIDENCE cells land under their own headers")
    func categoryAndConfidenceCellsAlignWithTheirHeaders() throws {
        let result = SensorsCommand.Result(
            providerIdentifier: "smc",
            capturedAt: Self.fixedDate,
            entries: [
                SensorsCommand.Entry(
                    key: "Tp09", label: "CPUCluster", category: .cpu, confidence: .verified,
                    value: 42.5, error: nil, unit: .celsius)
            ],
            keysDeclared: nil)

        let table = SensorsCommand.renderTable(result)
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)

        let headerColumns = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        let dataColumns = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        #expect(headerColumns.count == dataColumns.count)

        let categoryIndex = try #require(headerColumns.firstIndex(of: "CATEGORY"))
        let confidenceIndex = try #require(headerColumns.firstIndex(of: "CONFIDENCE"))
        #expect(categoryIndex != confidenceIndex)

        #expect(dataColumns[categoryIndex] == "cpu")
        #expect(dataColumns[confidenceIndex] == "verified")
    }
}

@Suite("fanctl sensors — command wiring")
struct SensorsCommandWiringTests {

    @Test("--json selects the JSON renderer, not just that renderJSON is independently correct")
    func jsonFlagSelectsJSONRenderer() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 1, kind: .temperatureCelsius)])
        let command = try Fanctl.Sensors.parse(["--json"])

        var captured = ""
        try await command.run(provider: provider, catalog: NoSensorCatalog()) { captured = $0 }

        #expect(captured.hasPrefix("{"))
        #expect(captured.contains("\"sensors\""))
    }

    @Test("Without --json, sensors renders a table, not JSON")
    func withoutJSONFlagRendersTable() async throws {
        let provider = FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 1, kind: .temperatureCelsius)])
        let command = try Fanctl.Sensors.parse([])

        var captured = ""
        try await command.run(provider: provider, catalog: NoSensorCatalog()) { captured = $0 }

        #expect(!captured.hasPrefix("{"))
        #expect(captured.contains("Tp09"))
    }
}
