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
    /// decode fault.
    ///
    /// Reads `SMCCore`'s shared constant rather than restating the number. This and
    /// `AeolusUI`'s `FanPoller.maxPlausibleFanCount` were two independent `64`s with
    /// nothing enforcing that they agreed; both now read one — see
    /// `SMCFanEnumeration.maxPlausibleFanCount` for the defence itself.
    static let maxPlausibleFanCount = SMCFanEnumeration.maxPlausibleFanCount

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

    /// Reads `FNum`, or `0` if this machine does not expose it at all.
    ///
    /// `.unknownKey("FNum")` — the key genuinely absent from this machine's table, not
    /// present-and-zero — is treated the same as `FNum == 0`, not as an error: observed
    /// (per community reports; see `docs/SMC-RESEARCH.md`) on some fanless Macs, whose
    /// firmware does not expose a fan-count key at all. The entire point of `fanctl
    /// list` — and of `.github/ISSUE_TEMPLATE/hardware-report.yml`, which asks for its
    /// `--json` output — is to work on exactly this machine; a fanless Air's owner must
    /// still be able to file that report. `.readFailed`/`.notDecodable` remain errors:
    /// those mean the key exists but something went wrong reading it, which is worth
    /// surfacing rather than silently treating as "no fans."
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
        case .failure(.unknownKey):
            return 0
        case .failure(let failure):
            throw FanctlError.connectionFailed(
                context: "read FNum", reason: failure.readableDescription)
        }

        // Validate the raw Double *before* ever converting it: SMCValue.scalar()
        // applies no finiteness or magnitude guard on the way out of SMCCore (see
        // Formatting.number's documentation), so a byte-order fault could in principle
        // hand back NaN, Inf, or a value nowhere near a real fan count. Int(exactly:)
        // never traps regardless, but checking isFinite and the plausible range first —
        // rather than converting and then checking the result — keeps the validation
        // order honest about what is actually being validated.
        guard decoded.isFinite, decoded >= 0, decoded <= Double(maxPlausibleFanCount),
            let fanCount = Int(exactly: decoded.rounded())
        else {
            throw FanctlError.implausibleFanCount(Formatting.number(decoded))
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
            return sanitized(key: key, value: reading.value)
        case .failure(let failure):
            return .failure(key: key, reason: failure.readableDescription)
        }
    }

    /// Guards a successfully-read value before it can reach either renderer.
    ///
    /// `SMCValue.scalar()` applies no finiteness check on the way out of `SMCCore` —
    /// see `Formatting.number`'s documentation for the untested byte-order branch that
    /// can produce `±.infinity`/`.nan` for an otherwise-successful read. Treated the
    /// same as a failed read here (`nil` value, a specific error) rather than let a
    /// non-finite `Double` reach `FanctlJSON`: `JSONEncoder`'s default
    /// `nonConformingFloatEncodingStrategy` throws on exactly that, which would void
    /// the *entire* `--json` output for one bad key among however many others read
    /// cleanly.
    private static func sanitized(key: String, value: Double) -> KeyedValue {
        guard value.isFinite else {
            return .failure(
                key: key,
                reason:
                    "decoded to a non-finite value (\(Formatting.number(value))) "
                    + "— likely a byte-order fault; see docs/SMC-RESEARCH.md"
            )
        }
        return .success(key: key, value: value)
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

    /// Builds the `--json` DTO without encoding it — split out from `renderJSON` so
    /// `fanctl watch` (`WatchCommand.swift`) can reuse the exact same field-building logic
    /// for its own NDJSON framing rather than duplicating it: `watch` must never be able
    /// to show a different number than `list` for the same key, and the surest way to
    /// guarantee that is for both to build the same `JSONOutput` value from the same
    /// `Result` and differ only in how they encode it.
    static func jsonOutput(_ result: Result) -> JSONOutput {
        func keyedValueJSON(_ value: KeyedValue) -> KeyedValueJSON {
            KeyedValueJSON(key: value.key, value: value.value, error: value.error)
        }

        return JSONOutput(
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
    }

    static func renderJSON(_ result: Result) throws -> String {
        try FanctlJSON.encode(jsonOutput(result))
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

    /// Provider- and output-injectable so `fanctlTests` can exercise this without
    /// hardware and without touching the real process stdout — see `Tests/fanctlTests`.
    /// `output` is what actually connects the `--json` flag to `renderJSON` rather than
    /// `renderTable`; a test that only calls the two render functions directly never
    /// proves that wiring.
    func run(
        provider: some SensorProvider,
        output: (String) -> Void = { print($0) }
    ) async throws {
        let result = try await ListCommand.fetch(provider: provider)
        if json {
            output(try ListCommand.renderJSON(result))
        } else {
            output(ListCommand.renderTable(result))
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
