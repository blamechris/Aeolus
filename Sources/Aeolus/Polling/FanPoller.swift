import SMCCore

/// Enumerates and refreshes every fan via targeted `SensorProvider.read(keys:)` subset
/// reads. Never `readAll()` — see this file's own documentation and `PollingEngine`'s.
///
/// ## No `{fds` on Apple Silicon
///
/// There is no fan descriptor struct. Enumeration is `FNum` plus `F<n>Ac`/`Mn`/`Mx` per
/// index, exactly as `fanctl`'s `ListCommand.swift` established — that file is the
/// reference this reimplements independently for the same reason `SensorLabelSource`
/// reimplements `CatalogSensorLookup`: `AeolusUI` cannot depend on the `fanctl`
/// executable target.
///
/// Fan enumeration never needs `readAll()` at all, discovery included: the fan count
/// comes from one small, well-known key (`FNum`), and every fan's three keys follow
/// directly from that count by a fixed naming convention. Contrast `SensorPoller`, whose
/// keys cannot be predicted this way and genuinely needs a one-time full enumeration to
/// discover them.
enum FanPoller {
    /// The largest `FNum` value this project trusts as a real fan count, rather than a
    /// decode fault. Mirrors `fanctl`'s `ListCommand.maxPlausibleFanCount` — the same
    /// defence `SMCConnection.maxPlausibleKeyCount` applies to `#KEY`, applied here to
    /// `FNum`.
    static let maxPlausibleFanCount = 64

    /// Fetches every fan's current, minimum, and maximum RPM in one targeted subset read.
    ///
    /// A missing or unreadable individual key (e.g. a machine that reports `F0Mn` but not
    /// `F0Mx`) is not fatal to the whole poll: it is recorded on that fan's `KeyedReading`
    /// as unavailable, and every other value still renders. Only a failure that makes
    /// enumeration itself impossible — no SMC, or `FNum` unreadable/implausible — throws.
    static func poll(provider: some SensorProvider) async throws -> [FanPollingReading] {
        let fanCount = try await readFanCount(provider: provider)
        guard fanCount > 0 else { return [] }

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
            throw PollingError.readFailed(
                context: "read fan speeds", reason: String(describing: error))
        }

        var outcomesByKey: [String: SensorReadOutcome] = [:]
        outcomesByKey.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            outcomesByKey[outcome.key] = outcome
        }

        return (0..<fanCount).map { index in
            FanPollingReading(
                index: index,
                displayName: "Fan \(index)",
                actual: keyedReading("F\(index)Ac", from: outcomesByKey),
                minimum: keyedReading("F\(index)Mn", from: outcomesByKey),
                maximum: keyedReading("F\(index)Mx", from: outcomesByKey)
            )
        }
    }

    /// Reads `FNum`, or `0` if this machine does not expose it at all — see `fanctl`'s
    /// `ListCommand.readFanCount(provider:)` for the identical reasoning: a fanless Mac
    /// genuinely has no `FNum`, and that must render as "no fans," not as an error.
    private static func readFanCount(provider: some SensorProvider) async throws -> Int {
        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: ["FNum"])
        } catch {
            throw PollingError.readFailed(context: "read FNum", reason: String(describing: error))
        }

        guard let outcome = outcomes.first else {
            throw PollingError.readFailed(context: "read FNum", reason: "no outcome returned")
        }

        switch outcome.result {
        case .success(let reading):
            // Validated before conversion, not after: SMCValue.scalar() applies no
            // finiteness or magnitude guard on the way out of SMCCore, so a byte-order
            // fault could hand back NaN, Inf, or a value nowhere near a real fan count.
            // Int(exactly:) never traps regardless, but checking isFinite and the
            // plausible range first keeps the validation order honest about what is
            // actually being validated — same defence as ListCommand.readFanCount.
            guard
                reading.value.isFinite, reading.value >= 0,
                reading.value <= Double(maxPlausibleFanCount),
                let fanCount = Int(exactly: reading.value.rounded())
            else {
                throw PollingError.implausibleFanCount(reading.value)
            }
            return fanCount
        case .failure(.unknownKey):
            return 0
        case .failure(let failure):
            throw PollingError.readFailed(
                context: "read FNum", reason: failure.readableDescription)
        }
    }

    private static func keyedReading(
        _ key: String, from outcomes: [String: SensorReadOutcome]
    ) -> KeyedReading {
        guard let outcome = outcomes[key] else {
            return .unavailable(key: key, reason: "no outcome returned")
        }
        return KeyedReading(key: key, outcome: outcome.result)
    }
}
