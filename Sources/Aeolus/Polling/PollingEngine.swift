import Foundation
import SMCCore

/// One full fan-plus-sensor poll cycle, as a plain async function independent of
/// `PollingViewModel`'s `@MainActor`/`ObservableObject` machinery — the same split
/// `fanctl`'s `WatchCommand.run(provider:options:clock:output:)` keeps between the loop
/// logic and its `Fanctl.Watch` command wiring, so this can be exercised in tests with a
/// fake `SensorProvider` and no `MainActor` involved at all.
enum PollingEngine {
    /// One tick's result. `discovery` is carried back out (never mutated in place) so the
    /// caller can hold it and pass it into the next call — see `poll(provider:labelSource:
    /// discovery:now:)`'s parameter documentation for why this stays a value handed back
    /// and forth rather than an `inout` threaded across `await` points.
    struct Snapshot: Sendable, Equatable {
        let fans: [FanPollingReading]
        let sensors: [SensorPollingReading]
        let discovery: [DiscoveredSensor]
        let capturedAt: Date
    }

    /// - Parameters:
    ///   - provider: Where fan and sensor readings come from.
    ///   - labelSource: Optional catalog decoration for sensors — see
    ///     `SensorLabelSource`'s documentation.
    ///   - discovery: The sensor key set discovered by a previous call, or `[]` before the
    ///     first successful discovery. Passed back unchanged in `Snapshot.discovery` when
    ///     non-empty, so a caller threads it straight into the next call without needing to
    ///     re-derive it — see `SensorPoller`'s documentation for why sensor discovery must
    ///     happen exactly once and then be reused, never repeated on every tick. Fans need
    ///     no equivalent caching: `FanPoller.poll(provider:)` rereads `FNum` itself every
    ///     call, cheaply, because unlike arbitrary sensor keys a fan's three keys follow
    ///     directly from its index by a fixed naming convention.
    ///   - now: Injectable so tests can assert on `Snapshot.capturedAt` against a fixed
    ///     value, matching `ListCommand.fetch(provider:now:)`'s identical parameter.
    /// - Returns: This tick's fans, sensors, resolved discovery, and capture time.
    /// - Throws: `PollingError.noSMC` if `provider.isAvailable` is `false`;
    ///   `PollingError.readFailed`/`.implausibleFanCount` if sensor discovery, the fan
    ///   poll, or the sensor refresh fails outright — see `FanPoller`/`SensorPoller` for
    ///   what does and does not throw versus reporting a per-key `KeyedReading
    ///   .unavailable` instead.
    static func poll(
        provider: some SensorProvider,
        labelSource: some SensorLabelSource,
        discovery: [DiscoveredSensor],
        now: @autoclosure () -> Date = Date()
    ) async throws -> Snapshot {
        // No separate `provider.isAvailable` guard here: `FanPoller.poll(provider:)`
        // — via `SMCFanEnumeration.enumerate(provider:)` — already checks it and throws
        // `PollingError.noSMC` before issuing a single read, and it runs first, ahead of
        // `SensorPoller.discover(provider:)`'s `readAll()`. A second, independent check
        // at this level would call `isAvailable` twice per tick for no behavioural gain
        // on real hardware — and on a provider whose availability can change between
        // calls (a real failure mode this loop must survive), a second call could
        // observe a *different* answer than the first within the same tick.
        //
        // Fans are sampled here, ahead of discovery's readAll() below, but `capturedAt`
        // (bottom of this function) is stamped after both complete — so on the one tick
        // that runs discovery (empty `discovery` in, below), the fan values this method
        // returns trail their own `capturedAt` by the cold readAll() cost rather than by
        // the cheap fan-read cost. Every later tick reuses `resolvedDiscovery` and this
        // gap collapses to the fan read alone.
        let fans = try await FanPoller.poll(provider: provider)

        let resolvedDiscovery: [DiscoveredSensor]
        if discovery.isEmpty {
            // Empty is treated as "not yet discovered," including the (practically
            // unreachable, since every real Mac's SMC exposes hundreds of keys) case of a
            // machine that genuinely has none: re-attempting costs one readAll() per tick
            // in that edge case rather than a permanently empty sensor list from one
            // transient failure. See SensorPoller's documentation for why this call is
            // the only readAll() in the whole refresh path.
            resolvedDiscovery = try await SensorPoller.discover(provider: provider)
        } else {
            resolvedDiscovery = discovery
        }

        let sensors = try await SensorPoller.refresh(
            discovered: resolvedDiscovery, provider: provider, labelSource: labelSource)

        return Snapshot(
            fans: fans, sensors: sensors, discovery: resolvedDiscovery, capturedAt: now())
    }
}
