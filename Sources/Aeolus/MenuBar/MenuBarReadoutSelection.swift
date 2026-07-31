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
/// name than without — and falling back to discovery order when none are labelled.
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
    ///   readouts. Never empty just because nothing is labelled yet — an unlabelled sensor
    ///   is a normal, fully-functional result throughout this codebase, not a reason to
    ///   show nothing.
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
        let chosen = (labelled.isEmpty ? candidates : labelled).prefix(maximumDefaultSensors)
        readouts.append(contentsOf: chosen.map { MenuBarReadout(key: $0.key, source: .sensor) })

        return readouts
    }
}
