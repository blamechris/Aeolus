import SMCCore

/// A sensor key discovered by `SensorPoller.discover(provider:)`, before any value has
/// been attached to it. `kind` is fixed at discovery time — see `SensorPollingReading`'s
/// documentation for why it is not re-derived on every refresh.
struct DiscoveredSensor: Sendable, Hashable {
    let key: String
    let kind: SensorReading.Kind
}

/// Discovers, once, every sensor key a machine exposes, then refreshes them repeatedly
/// via targeted `SensorProvider.read(keys:)` subset reads.
///
/// ## `readAll()` belongs only to discovery
///
/// Measured on this project's development hardware: a warm `~40`-key subset read is
/// ~12 ms; a warm `readAll()` is ~0.6 s; a cold one is ~4.5 s. A live 1 Hz UI cannot pay
/// `readAll()`'s cost on every tick — this is exactly why #32 (subset reads plus a cached
/// key table) was a prerequisite for this epic. But sensor keys, unlike fan keys, follow
/// no predictable naming convention `FanPoller` can enumerate without ever touching
/// hardware — discovering *which* keys exist genuinely requires one full enumeration.
/// `discover(provider:)` is that enumeration, and the only place in this poller that ever
/// calls it: `refresh(discovered:provider:labelSource:)` — the function every timer tick
/// after the first calls — only ever issues a subset read.
enum SensorPoller {
    /// Enumerates every sensor this machine currently exposes. Callers should call this
    /// once (at startup, or on an explicit user-triggered re-discovery) and hold the
    /// result for `refresh(discovered:provider:labelSource:)` to reread thereafter — never
    /// on every tick.
    static func discover(provider: some SensorProvider) async throws -> [DiscoveredSensor] {
        let readings: [SensorReading]
        do {
            readings = try await provider.readAll()
        } catch {
            throw PollingError.readFailed(
                context: "enumerate sensors", reason: String(describing: error))
        }

        var seen: Set<String> = []
        seen.reserveCapacity(readings.count)
        var discovered: [DiscoveredSensor] = []
        discovered.reserveCapacity(readings.count)
        for reading in readings where seen.insert(reading.key).inserted {
            discovered.append(DiscoveredSensor(key: reading.key, kind: reading.kind))
        }
        return discovered.sorted { $0.key < $1.key }
    }

    /// Rereads every key in `discovered` via one targeted subset read. Never calls
    /// `readAll()` — see this type's documentation.
    ///
    /// A key that fails this tick (transient read failure, or a key that genuinely
    /// disappeared) is represented as `.unavailable` on its `SensorPollingReading`, never
    /// dropped from the list and never fabricated as `0` — the same contract
    /// `FanPoller.poll(provider:)` gives per-fan values.
    static func refresh(
        discovered: [DiscoveredSensor],
        provider: some SensorProvider,
        labelSource: some SensorLabelSource
    ) async throws -> [SensorPollingReading] {
        guard !discovered.isEmpty else { return [] }

        let keys = discovered.map(\.key)
        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: keys)
        } catch {
            throw PollingError.readFailed(
                context: "refresh sensors", reason: String(describing: error))
        }

        var outcomesByKey: [String: SensorReadOutcome] = [:]
        outcomesByKey.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            outcomesByKey[outcome.key] = outcome
        }

        return discovered.map { sensor in
            let sample: KeyedReading
            if let outcome = outcomesByKey[sensor.key] {
                sample = KeyedReading(key: sensor.key, outcome: outcome.result)
            } else {
                sample = .unavailable(key: sensor.key, reason: "no outcome returned")
            }
            return SensorPollingReading(
                key: sensor.key,
                kind: sensor.kind,
                sample: sample,
                decoration: labelSource.decoration(for: sensor.key)
            )
        }
    }
}
