import SMCCore

/// Enumerates and refreshes every fan via `SMCCore`'s shared `SMCFanEnumeration`.
///
/// ## No `{fds` on Apple Silicon
///
/// There is no fan descriptor struct. Enumeration is `FNum` plus `F<n>Ac`/`Mn`/`Mx` per
/// index — that knowledge now lives once, in `SMCFanEnumeration`, rather than being
/// reimplemented independently here and in `fanctl`'s `ListCommand.swift`. This type's
/// job is presentation only: turning `SMCFanEnumeration`'s raw per-key outcomes into the
/// `FanPollingReading`s this app's views render, with the synthesised `displayName`
/// (`"Fan 0"`) that is this layer's alone to produce.
enum FanPoller {
    /// Fetches every fan's current, minimum, and maximum RPM in one targeted subset read.
    ///
    /// A missing or unreadable individual key (e.g. a machine that reports `F0Mn` but not
    /// `F0Mx`) is not fatal to the whole poll: it is recorded on that fan's `KeyedReading`
    /// as unavailable, and every other value still renders — `SMCFanEnumeration`'s own
    /// contract. Only a failure that makes enumeration itself impossible — no SMC, or
    /// `FNum` unreadable/implausible — throws, reclassified into `PollingError` so this
    /// module's callers keep speaking one error type.
    static func poll(provider: some SensorProvider) async throws -> [FanPollingReading] {
        let enumeration: SMCFanEnumeration
        do {
            enumeration = try await SMCFanEnumeration.enumerate(provider: provider)
        } catch let error as SMCFanEnumerationError {
            throw PollingError(error)
        }

        return enumeration.fans.map { fan in
            FanPollingReading(
                index: fan.index,
                displayName: "Fan \(fan.index)",
                actual: KeyedReading(key: fan.actual.key, outcome: fan.actual.result),
                minimum: KeyedReading(key: fan.minimum.key, outcome: fan.minimum.result),
                maximum: KeyedReading(key: fan.maximum.key, outcome: fan.maximum.result)
            )
        }
    }
}
