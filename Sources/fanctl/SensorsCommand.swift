import FanKit
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
        /// `#KEY`'s own declared value, read independently of `readAll()` — see
        /// `declaredKeyCount(provider:)`. `nil` if that read itself did not succeed;
        /// this is diagnostic context for a hardware report, never something `fetch`'s
        /// success depends on.
        let keysDeclared: Int?
    }

    /// One decorated reading. Mirrors `AeolusXPC.SensorSample`'s field shape (`key`,
    /// `label`, `labelConfidence`, `value`, `unit`) deliberately, so this JSON does not
    /// have to change meaning once a helper-backed path exists — even though this
    /// command reads straight from `SensorProvider` and never touches XPC itself. `key`
    /// is always present; `label`/`category`/`confidence` are `nil` together, never one
    /// without the others — an unlabelled sensor is a normal result, not a degraded one.
    /// `category` is not part of `AeolusXPC.SensorSample` today, but is carried here
    /// because a raw catalog match always has one — see `SensorCatalogLabel`. `value` is
    /// `nil` exactly when `error` is non-`nil`, same contract as
    /// `ListCommand.KeyedValue` — see `sanitize(_:)`.
    struct Entry: Equatable {
        let key: String
        let label: String?
        let category: SensorCategoryLabel?
        let confidence: SensorLabelConfidence?
        let value: Double?
        let error: String?
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
                let (value, error) = sanitize(reading.value)
                return Entry(
                    key: reading.key,
                    label: match?.text,
                    category: match?.category,
                    confidence: match?.confidence,
                    value: value,
                    error: error,
                    unit: SensorUnit(kind: reading.kind)
                )
            }

        let keysDeclared = await declaredKeyCount(provider: provider)

        return Result(
            providerIdentifier: provider.identifier, capturedAt: now(), entries: entries,
            keysDeclared: keysDeclared)
    }

    /// Guards a reading's value before it can reach either renderer — see
    /// `ListCommand.sanitized(key:value:)`, the identical guard for `list`, for why:
    /// `SMCValue.scalar()` applies no finiteness check on the way out of `SMCCore`, and
    /// a non-finite `Double` reaching `FanctlJSON` would make `JSONEncoder`'s default
    /// `nonConformingFloatEncodingStrategy` throw, voiding the *entire* `--json` output
    /// — thousands of good readings lost to one bad key.
    private static func sanitize(_ value: Double) -> (Double?, String?) {
        guard value.isFinite else {
            let reason =
                "decoded to a non-finite value (\(Formatting.number(value))) "
                + "— likely a byte-order fault; see docs/SMC-RESEARCH.md"
            return (nil, reason)
        }
        return (value, nil)
    }

    /// `#KEY`'s own declared value, as a dedicated subset read rather than assumed
    /// present among `readings` — `readAll()` includes `#KEY` as an ordinary walked
    /// entry when it happens to decode (and it usually does; `Result.keysDeclared`
    /// matched `entries.count`'s companion `#KEY` entry on `Mac16,5` when this was
    /// checked), but that is incidental to enumeration, not guaranteed by it: on a
    /// connection whose SMC interface generation is undetectable, `#KEY`'s *value*
    /// (a `ui32`) can fail to decode via the generic per-key walk even though
    /// `keyCount()`'s own dedicated fallback still produced a usable count for the
    /// walk's bound. Reading it here directly sidesteps that gap.
    ///
    /// Best-effort and silent on failure: this is diagnostic context (`keysDeclared` /
    /// `keysSkipped` in the JSON) for a hardware report, not something `fetch`'s
    /// success should ever depend on.
    private static func declaredKeyCount(provider: some SensorProvider) async -> Int? {
        guard let outcomes = try? await provider.read(keys: ["#KEY"]),
            let outcome = outcomes.first,
            case .success(let reading) = outcome.result,
            reading.value.isFinite
        else {
            return nil
        }
        return Int(exactly: reading.value.rounded())
    }
}

// MARK: - Rendering

extension SensorsCommand {
    // Sibling of JSONOutput, not nested inside it — see ListCommand's identical note.
    struct SensorJSON: Codable {
        let key: String
        let label: String?
        let category: String?
        let labelConfidence: String?
        let value: Double?
        let error: String?
        let unit: String

        // Hand-written for the same reason as ListCommand.KeyedValueJSON: the
        // synthesised conformance omits "label"/"category"/"labelConfidence"/"value"/
        // "error" entirely when nil (encodeIfPresent), which would make every entry's
        // key set depend on whether it happened to be labelled or decoded cleanly. With
        // thousands of entries in a full `sensors --json` dump, a uniform shape —
        // `null` standing in for "no catalog match" or "did not decode" — matters more
        // here than almost anywhere else in this CLI. CodingKeys itself lives as a
        // sibling below, not nested here — see ListCommand's identical note.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: SensorCodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(label, forKey: .label)
            try container.encode(category, forKey: .category)
            try container.encode(labelConfidence, forKey: .labelConfidence)
            try container.encode(value, forKey: .value)
            try container.encode(error, forKey: .error)
            try container.encode(unit, forKey: .unit)
        }
    }

    private enum SensorCodingKeys: String, CodingKey {
        case key, label, category, labelConfidence, value, error, unit
    }

    struct JSONOutput: Codable {
        let provider: String
        let capturedAt: Date
        // "Keys that decoded to a usable numeric scalar" — not the same as "keys this
        // machine declares". SMCSensorProvider.readAll() silently skips any key that
        // fails index lookup, READ_KEYINFO, READ_BYTES, or scalar decoding at any
        // stage (see that method's documentation), so sensorCount is routinely lower
        // than keysDeclared. On Mac16,5 at the time this was written: #KEY declares
        // 3385, sensorCount was 2929 — 456 keys silently dropped, which keysSkipped
        // below makes explicit instead of leaving a maintainer to notice the gap
        // between two numbers in two different places.
        let sensorCount: Int
        let keysDeclared: Int?
        let keysSkipped: Int?
        let sensors: [SensorJSON]
    }

    static func renderJSON(_ result: Result) throws -> String {
        let output = JSONOutput(
            provider: result.providerIdentifier,
            capturedAt: result.capturedAt,
            sensorCount: result.entries.count,
            keysDeclared: result.keysDeclared,
            keysSkipped: result.keysDeclared.map { $0 - result.entries.count },
            sensors: result.entries.map { entry in
                SensorJSON(
                    key: entry.key,
                    label: entry.label,
                    category: entry.category?.rawValue,
                    labelConfidence: entry.confidence?.rawValue,
                    value: entry.value,
                    error: entry.error,
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

        let headers = ["KEY", "LABEL", "CATEGORY", "CONFIDENCE", "VALUE", "UNIT"]
        let rows = result.entries.map { entry in
            [
                entry.key,
                entry.label ?? "-",
                entry.category?.rawValue ?? "-",
                entry.confidence?.rawValue ?? "-",
                rendered(entry),
                entry.unit.rawValue,
            ]
        }
        return Table.render(headers: headers, rows: rows)
    }

    private static func rendered(_ entry: Entry) -> String {
        guard let value = entry.value else {
            return "unavailable (\(entry.error ?? "unknown error"))"
        }
        return Formatting.number(value)
    }
}

// MARK: - Command wiring

extension Fanctl.Sensors {
    /// Loads the real, hardware-scoped catalog (`CatalogSensorLookup`) in place of
    /// `NoSensorCatalog` — the seam #56 wires in. Any catalog-load warning is written to
    /// stderr here, at the real-environment entry point, rather than threaded through
    /// `run(provider:catalog:output:)`'s injectable signature below: that function stays a
    /// pure function of whatever `SensorCatalogLookup` a caller supplies, and
    /// `NoSensorCatalog`/`FakeSensorCatalogLookup` (used throughout `fanctlTests`) have no
    /// warnings to report in the first place.
    func run() async throws {
        let catalog = CatalogSensorLookup.loadDefault()
        reportCatalogWarnings(catalog.warnings)
        try await run(provider: SMCSensorProvider(), catalog: catalog)
    }

    /// Provider-, catalog-, and output-injectable so `fanctlTests` can exercise this
    /// without hardware, without a real catalog, and without touching the real process
    /// stdout — see `Tests/fanctlTests`. `output` is what actually connects the
    /// `--json` flag to `renderJSON` rather than `renderTable`; a test that only calls
    /// the two render functions directly never proves that wiring.
    func run(
        provider: some SensorProvider,
        catalog: some SensorCatalogLookup,
        output: (String) -> Void = { print($0) }
    ) async throws {
        let result = try await SensorsCommand.fetch(
            provider: provider, catalog: catalog, rawKeys: rawKeys)
        if json {
            output(try SensorsCommand.renderJSON(result))
        } else {
            output(SensorsCommand.renderTable(result))
        }
    }
}

/// Writes each catalog-load warning to stderr, one per line. A warning here is diagnostic
/// context for whoever is running `fanctl sensors` — a stale override, a broken build —
/// never a reason `SensorsCommand.fetch` returns fewer entries: see
/// `CatalogSensorLookup.warnings`'s documentation.
private func reportCatalogWarnings(_ warnings: [CatalogLoadWarning]) {
    for warning in warnings {
        FileHandle.standardError.write(
            Data("fanctl: warning: \(warning.readableDescription)\n".utf8))
    }
}
