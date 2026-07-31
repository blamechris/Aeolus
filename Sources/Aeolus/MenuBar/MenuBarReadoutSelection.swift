import SMCCore

/// Computes a sensible default set of `MenuBarReadout`s from what a poll actually found on
/// this machine.
///
/// ## Why this is not a hardcoded key list
///
/// `SensorProvider.readAll()`'s own documentation is explicit that sensor discovery is
/// dynamic and an unrecognised Mac must still show every sensor it has. A fixed default
/// like `["TC0P"]` would be an Intel-only guess that resolves to unavailable on every
/// Apple Silicon machine and vice versa — exactly the kind of unverified hardware
/// assumption `CLAUDE.md` forbids. This selection is derived from whatever
/// `PollingEngine.poll` actually reported on the tick it was computed from: every fan
/// (there are rarely more than a handful, and a fan's own current speed is unambiguously
/// worth surfacing without a picker), plus up to `maximumDefaultSensors` non-fan sensors,
/// preferring catalog-labelled ones — three words of menu bar space are more useful with a
/// name than without.
///
/// ## A labelled sensor is trusted; an unlabelled one must prove it is a measurement
///
/// When nothing is labelled, the fallback is **not** "first N in discovery order." Measured
/// directly on this project's development hardware: with no catalog source wired in, the
/// first two non-fan keys `SensorPoller.discover(provider:)` reports are `#KEY` (3385 —
/// the SMC's own declared key count) and `AC-B` (-1 — an internal sentinel), neither of
/// which is a sensor at all. `SMCSensorProvider.kind(for:)` is deliberately conservative —
/// it classifies only the fan-key naming convention, so every SMC key that is not a
/// catalog-labelled sensor and not a fan reading defaults to `.unknown` — but that
/// conservatism is exactly what makes `kind` a safe, honest filter here: a key this
/// project cannot vouch for as a real physical measurement is never shown as one by
/// default. On hardware with no matching catalog entries at all (a normal, fully-supported
/// state per E6's design), this fallback is legitimately empty rather than showing
/// whatever the enumeration order happens to put first.
///
/// This is exactly the seam `#64`'s real selector plugs into: once a user has made a
/// choice, `MenuBarViewModel` is constructed with that `[MenuBarReadout]` directly and
/// this type is never consulted again for that session.
enum MenuBarReadoutSelection {
    /// How many non-fan sensors the default selection includes. Small on purpose — this
    /// renders directly in the menu bar, not in a scrollable list.
    static let maximumDefaultSensors = 2

    /// - Parameters:
    ///   - fans: `PollingViewModel.fans` at the moment a default is needed.
    ///   - sensors: `PollingViewModel.sensors` at the same moment.
    /// - Returns: One `.fan` readout per fan, plus up to `maximumDefaultSensors` `.sensor`
    ///   readouts. Can legitimately be just the fan readouts — see this type's own
    ///   documentation on why an unlabelled, kind-`.unknown` key is never defaulted to
    ///   rather than shown empty.
    static func defaultSelection(
        fans: [FanPollingReading], sensors: [SensorPollingReading]
    ) -> [MenuBarReadout] {
        var readouts = fans.map { MenuBarReadout(key: $0.actual.key, source: .fan) }

        // Fan keys already have a .fan-sourced readout above; excluding them here avoids
        // defaulting to the same physical fan twice under two different `source`s (see
        // MenuBarReadout's documentation on why the same key can appear in both lists).
        let fanKeys = Set(fans.flatMap { [$0.actual.key, $0.minimum.key, $0.maximum.key] })
        let candidates = sensors.filter { !fanKeys.contains($0.key) }
        let labelled = candidates.filter { $0.decoration != nil }
        // Trust a catalog label regardless of `kind` — a human curated it via E6. Absent
        // one, only a key whose `kind` this project can actually vouch for as a physical
        // measurement is eligible; see this type's "labelled is trusted" documentation
        // for the #KEY/AC-B finding this specifically guards against.
        let unlabelledFallback = candidates.filter { $0.decoration == nil && $0.kind != .unknown }
        let chosen = (labelled.isEmpty ? unlabelledFallback : labelled)
            .prefix(maximumDefaultSensors)
        readouts.append(contentsOf: chosen.map { MenuBarReadout(key: $0.key, source: .sensor) })

        return readouts
    }
}
