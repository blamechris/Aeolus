import Foundation
import SMCCore

/// `fanctl list` — fans with their current, minimum, and maximum RPM.
///
/// Reads directly via `SensorProvider`, never over XPC: this is what makes "works with no
/// helper installed and no privileges" literally true for a client with no signing
/// requirement to satisfy, not just an aspiration.
///
/// ## There is no fan descriptor struct
///
/// Apple Silicon has no `{fds` — enumeration is `FNum` plus `F<n>Ac`/`Mn`/`Mx` per index,
/// read as a targeted subset (`SensorProvider.read(keys:)`), never `readAll()`: `list`
/// already knows exactly which keys it wants, so paying `readAll()`'s full-enumeration
/// cost here would only slow the common case down for no benefit. `displayName` below
/// ("Fan 0") is synthesised by this CLI for a human to read — it is never presented as
/// something the firmware reported, and the raw `F<n>Ac`/`Mn`/`Mx` keys are always shown
/// alongside it, in both the table and the JSON.
enum ListCommand {
    /// The largest `FNum` value this project trusts as a real fan count, rather than a
    /// decode fault. No Mac this project has documented evidence of comes close to this;
    /// it exists purely so a corrupted read cannot turn into an unbounded enumeration —
    /// the same defence `SMCConnection.maxPlausibleKeyCount` applies to `#KEY`.
    static let maxPlausibleFanCount = 64

    struct Result: Equatable {
        let fanCount: Int
        let fanCountKey: String
        let fans: [Fan]
        let capturedAt: Date
    }

    struct Fan: Equatable {
        let index: Int
        let displayName: String
        let actual: KeyedValue
        let minimum: KeyedValue
        let maximum: KeyedValue
    }

    /// One SMC reading, always paired with the raw key that produced it — see
    /// `docs/SAFETY.md`'s labelling rule. `value` is `nil` exactly when `error` is
    /// non-`nil`: a failed read is never fabricated as `0` or omitted silently.
    struct KeyedValue: Equatable {
        let key: String
        let value: Double?
        let error: String?

        static func success(key: String, value: Double) -> KeyedValue {
            KeyedValue(key: key, value: value, error: nil)
        }

        static func failure(key: String, reason: String) -> KeyedValue {
            KeyedValue(key: key, value: nil, error: reason)
        }
    }

    /// Fetches every fan's current, minimum, and maximum RPM.
    ///
    /// A missing or unreadable individual key (e.g. a machine that reports `F0Mn` but not
    /// `F0Mx`) is not fatal to the whole command: it is recorded on that fan's
    /// `KeyedValue` as an error and every other value still renders. Only a failure that
    /// makes enumeration itself impossible — no SMC, or `FNum` unreadable — throws.
    static func fetch(
        provider: some SensorProvider,
        now: @autoclosure () -> Date = Date()
    ) async throws -> Result {
        guard await provider.isAvailable else {
            throw FanctlError.noSMC
        }

        let fanCount = try await readFanCount(provider: provider)
        guard fanCount > 0 else {
            return Result(fanCount: 0, fanCountKey: "FNum", fans: [], capturedAt: now())
        }

        var keys: [String] = []
        keys.reserveCapacity(fanCount * 3)
        for index in 0..<fanCount {
            keys.append("F\(index)Ac")
            keys.append("F\(index)Mn")
            keys.append("F\(index)Mx")
        }

        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: keys)
        } catch {
            throw FanctlError.connectionFailed(
                context: "read fan speeds", reason: String(describing: error))
        }

        var outcomesByKey: [String: SensorReadOutcome] = [:]
        outcomesByKey.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            outcomesByKey[outcome.key] = outcome
        }

        let fans = (0..<fanCount).map { index in
            Fan(
                index: index,
                displayName: "Fan \(index)",
                actual: keyedValue("F\(index)Ac", from: outcomesByKey),
                minimum: keyedValue("F\(index)Mn", from: outcomesByKey),
                maximum: keyedValue("F\(index)Mx", from: outcomesByKey)
            )
        }

        return Result(fanCount: fanCount, fanCountKey: "FNum", fans: fans, capturedAt: now())
    }

    private static func readFanCount(provider: some SensorProvider) async throws -> Int {
        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: ["FNum"])
        } catch {
            throw FanctlError.connectionFailed(
                context: "read FNum", reason: String(describing: error))
        }

        guard let outcome = outcomes.first else {
            throw FanctlError.connectionFailed(
                context: "read FNum", reason: "no outcome returned")
        }

        let decoded: Double
        switch outcome.result {
        case .success(let reading):
            decoded = reading.value
        case .failure(let failure):
            throw FanctlError.connectionFailed(
                context: "read FNum", reason: failure.readableDescription)
        }

        let fanCount = Int(decoded.rounded())
        guard fanCount >= 0, fanCount <= maxPlausibleFanCount else {
            throw FanctlError.implausibleFanCount(fanCount)
        }
        return fanCount
    }

    private static func keyedValue(
        _ key: String, from outcomes: [String: SensorReadOutcome]
    ) -> KeyedValue {
        guard let outcome = outcomes[key] else {
            return .failure(key: key, reason: "no outcome returned")
        }
        switch outcome.result {
        case .success(let reading):
            return .success(key: key, value: reading.value)
        case .failure(let failure):
            return .failure(key: key, reason: failure.readableDescription)
        }
    }
}

// MARK: - Rendering

extension ListCommand {
    // The JSON DTOs below are siblings of JSONOutput, not nested inside it: SwiftLint
    // caps nesting at one level, and `ListCommand.KeyedValueJSON` reads just as clearly
    // as `ListCommand.JSONOutput.KeyedValueJSON` would have.

    struct KeyedValueJSON: Codable {
        let key: String
        let value: Double?
        let error: String?

        // Written by hand rather than relying on the synthesised conformance: the
        // compiler-generated encode(to:) calls encodeIfPresent for Optional
        // properties, which *omits* the key entirely when nil. That would make
        // "value" and "error" appear or disappear per entry depending on whether this
        // particular read succeeded — every actualRPM/minimumRPM/maximumRPM object
        // should have the same two keys regardless, with `null` standing in for "not
        // present," so a human or a script can rely on the shape without checking
        // which fields happen to exist this time. CodingKeys itself lives as a sibling
        // below, not nested here, to stay within SwiftLint's one-level nesting cap.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: KeyedValueCodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
            try container.encode(error, forKey: .error)
        }
    }

    private enum KeyedValueCodingKeys: String, CodingKey {
        case key, value, error
    }

    struct FanJSON: Codable {
        let index: Int
        let displayName: String
        let actualRPM: KeyedValueJSON
        let minimumRPM: KeyedValueJSON
        let maximumRPM: KeyedValueJSON
    }

    struct FanCountJSON: Codable {
        let key: String
        let value: Int
    }

    struct JSONOutput: Codable {
        let capturedAt: Date
        let fanCount: FanCountJSON
        let fans: [FanJSON]
    }

    static func renderJSON(_ result: Result) throws -> String {
        func keyedValueJSON(_ value: KeyedValue) -> KeyedValueJSON {
            KeyedValueJSON(key: value.key, value: value.value, error: value.error)
        }

        let output = JSONOutput(
            capturedAt: result.capturedAt,
            fanCount: FanCountJSON(key: result.fanCountKey, value: result.fanCount),
            fans: result.fans.map { fan in
                FanJSON(
                    index: fan.index,
                    displayName: fan.displayName,
                    actualRPM: keyedValueJSON(fan.actual),
                    minimumRPM: keyedValueJSON(fan.minimum),
                    maximumRPM: keyedValueJSON(fan.maximum)
                )
            }
        )
        return try FanctlJSON.encode(output)
    }

    static func renderTable(_ result: Result) -> String {
        guard !result.fans.isEmpty else {
            return "No fans detected (\(result.fanCountKey) = \(result.fanCount))."
        }

        let headers = ["FAN", "NAME", "ACTUAL", "MINIMUM", "MAXIMUM", "KEYS"]
        let rows = result.fans.map { fan -> [String] in
            [
                String(fan.index),
                fan.displayName,
                rendered(fan.actual),
                rendered(fan.minimum),
                rendered(fan.maximum),
                "\(fan.actual.key)/\(fan.minimum.key)/\(fan.maximum.key)",
            ]
        }
        return Table.render(headers: headers, rows: rows)
    }

    private static func rendered(_ value: KeyedValue) -> String {
        guard let rpm = value.value else {
            return "unavailable (\(value.error ?? "unknown error"))"
        }
        return "\(Formatting.number(rpm)) RPM"
    }
}

// MARK: - Command wiring

extension Fanctl.List {
    func run() async throws {
        try await run(provider: SMCSensorProvider())
    }

    /// Provider-injectable so `fanctlTests` can exercise this without hardware — see
    /// `Tests/fanctlTests`.
    func run(provider: some SensorProvider) async throws {
        let result = try await ListCommand.fetch(provider: provider)
        if json {
            print(try ListCommand.renderJSON(result))
        } else {
            print(ListCommand.renderTable(result))
        }
    }
}

extension SensorReadFailure {
    /// A human-readable rendering of this failure, for `KeyedValue.error` and table
    /// output. Never parsed or matched on — see `SensorReadFailure`'s own documentation.
    var readableDescription: String {
        switch self {
        case .unknownKey(let key):
            return "\(key) is not present on this machine"
        case .readFailed(let reason):
            return reason
        case .notDecodable(let reason):
            return reason
        }
    }
}
