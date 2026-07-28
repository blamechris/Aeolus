import Foundation
import SMCCore

/// `fanctl sensors` — every sensor this machine exposes, decorated with a catalog label
/// where one is known.
///
/// Reads directly via `SensorProvider`, never over XPC — same rationale as
/// `ListCommand`.
enum SensorsCommand {
    struct Result: Equatable {
        let providerIdentifier: String
        let capturedAt: Date
        let entries: [Entry]
    }

    /// One decorated reading. Mirrors `AeolusXPC.SensorSample`'s field shape (`key`,
    /// `label`, `labelConfidence`, `value`, `unit`) deliberately, so this JSON does not
    /// have to change meaning once a helper-backed path exists — even though this
    /// command reads straight from `SensorProvider` and never touches XPC itself. `key`
    /// is always present; `label`/`confidence` are `nil` together, never one without the
    /// other — an unlabelled sensor is a normal result, not a degraded one.
    struct Entry: Equatable {
        let key: String
        let label: String?
        let confidence: SensorLabelConfidence?
        let value: Double
        let unit: SensorUnit
    }

    /// Enumerates every sensor via `SensorProvider.readAll()`.
    ///
    /// - Important: This is deliberately `readAll()`, not a subset `read(keys:)`.
    ///   `sensors` exists specifically to discover keys nobody has told this project
    ///   about yet — a full enumeration is the only way to do that, and the ~4.5 s cold
    ///   cost `readAll()` documents is acceptable for a one-shot CLI invocation. Do not
    ///   "optimise" this into a subset read: it would lose the ability to find anything
    ///   new. `fanctl watch` (#46 / E10a.2) is the opposite case — it repeatedly refreshes
    ///   a set of keys it already knows and must use `read(keys:)` instead.
    static func fetch(
        provider: some SensorProvider,
        catalog: some SensorCatalogLookup,
        rawKeys: Bool,
        now: @autoclosure () -> Date = Date()
    ) async throws -> Result {
        guard await provider.isAvailable else {
            throw FanctlError.noSMC
        }

        let readings: [SensorReading]
        do {
            readings = try await provider.readAll()
        } catch {
            throw FanctlError.connectionFailed(
                context: "enumerate sensors", reason: String(describing: error))
        }

        let entries =
            readings
            .sorted { $0.key < $1.key }
            .map { reading -> Entry in
                // --raw-keys suppresses the label lookup; it never hides the key itself —
                // `reading.key` is carried onto Entry.key unconditionally below.
                let match = rawKeys ? nil : catalog.label(for: reading.key)
                return Entry(
                    key: reading.key,
                    label: match?.text,
                    confidence: match?.confidence,
                    value: reading.value,
                    unit: SensorUnit(kind: reading.kind)
                )
            }

        return Result(
            providerIdentifier: provider.identifier, capturedAt: now(), entries: entries)
    }
}

// MARK: - Rendering

extension SensorsCommand {
    // Sibling of JSONOutput, not nested inside it — see ListCommand's identical note.
    struct SensorJSON: Codable {
        let key: String
        let label: String?
        let labelConfidence: String?
        let value: Double
        let unit: String

        // Hand-written for the same reason as ListCommand.KeyedValueJSON: the
        // synthesised conformance omits "label"/"labelConfidence" entirely when nil
        // (encodeIfPresent), which would make every entry's key set depend on whether
        // it happened to be labelled. With thousands of entries in a full `sensors
        // --json` dump, a uniform shape — `null` standing in for "no catalog match" —
        // matters more here than almost anywhere else in this CLI. CodingKeys itself
        // lives as a sibling below, not nested here — see ListCommand's identical note.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SensorCodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(label, forKey: .label)
            try container.encode(labelConfidence, forKey: .labelConfidence)
            try container.encode(value, forKey: .value)
            try container.encode(unit, forKey: .unit)
        }
    }

    private enum SensorCodingKeys: String, CodingKey {
        case key, label, labelConfidence, value, unit
    }

    struct JSONOutput: Codable {
        let provider: String
        let capturedAt: Date
        let sensorCount: Int
        let sensors: [SensorJSON]
    }

    static func renderJSON(_ result: Result) throws -> String {
        let output = JSONOutput(
            provider: result.providerIdentifier,
            capturedAt: result.capturedAt,
            sensorCount: result.entries.count,
            sensors: result.entries.map { entry in
                SensorJSON(
                    key: entry.key,
                    label: entry.label,
                    labelConfidence: entry.confidence?.rawValue,
                    value: entry.value,
                    unit: entry.unit.rawValue
                )
            }
        )
        return try FanctlJSON.encode(output)
    }

    static func renderTable(_ result: Result) -> String {
        guard !result.entries.isEmpty else {
            return "No sensors found."
        }

        let headers = ["KEY", "LABEL", "CONFIDENCE", "VALUE", "UNIT"]
        let rows = result.entries.map { entry in
            [
                entry.key,
                entry.label ?? "-",
                entry.confidence?.rawValue ?? "-",
                Formatting.number(entry.value),
                entry.unit.rawValue,
            ]
        }
        return Table.render(headers: headers, rows: rows)
    }
}

// MARK: - Command wiring

extension Fanctl.Sensors {
    func run() async throws {
        try await run(provider: SMCSensorProvider(), catalog: NoSensorCatalog())
    }

    /// Provider- and catalog-injectable so `fanctlTests` can exercise this without
    /// hardware and without a real catalog — see `Tests/fanctlTests`.
    func run(provider: some SensorProvider, catalog: some SensorCatalogLookup) async throws {
        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: rawKeys)
        if json {
            print(try SensorsCommand.renderJSON(result))
        } else {
            print(SensorsCommand.renderTable(result))
        }
    }
}
