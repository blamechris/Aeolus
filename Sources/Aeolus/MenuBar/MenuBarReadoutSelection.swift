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
/// ## A curated label makes a key nameable, not defaultable (`#249`)
///
/// `#249` found `F0Md` (Fan 0 Mode) and `F0Tg` (Fan 0 Target Speed) in the default menu
/// bar strip, rendered as bare numbers indistinguishable from the live RPM readings next
/// to them — one of them a mode flag showing `0`, which rule 3 ("never allow 0 RPM")
/// makes the single worst value this app can display by accident. Both keys are
/// catalog-labelled on this project's development hardware, so the "labelled is trusted"
/// rule above put them straight through: a human curated the label via E6, so the label
/// itself is correct, but E6 answers "what does this key mean", never "is this a live
/// measurement fit to default to." `F0Tg` compounds this: `SMCSensorProvider.kind(for:)`
/// classifies its suffix `Tg` as `.rpm` (it decodes and formats like a speed), so the
/// unlabelled fallback's `kind != .unknown` filter would not even catch it without a
/// label — kind here answers "what unit does this decode as", not "is it a snapshot of
/// reality or a value someone/something requested." `isFanControlPlaneKey(_:)` excludes
/// both, and every key matching their `F<digit>Md`/`F<digit>Tg` shape, from candidacy
/// entirely — before the labelled/unlabelled split runs, and regardless of which side of
/// it a key would otherwise land on. A curated label still makes these keys *nameable*:
/// `MenuBarContentsPreferencesView`'s picker is free to offer them, since a user who
/// picks `F0Tg` deliberately, with its label right there, is a different case from this
/// type guessing it for them.
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
        // Excludes F0Md/F0Tg (and any fan's) before either branch below ever sees them —
        // see this type's "#249" documentation for why a catalog label cannot rescue a
        // control-plane key here the way it rescues a merely-unclassified one.
        let candidates = sensors.filter { !fanKeys.contains($0.key) && !isFanControlPlaneKey($0.key) }
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

    /// True for any key shaped like a fan's mode or target-speed control (`F<digit>Md`,
    /// `F<digit>Tg`) — the `#249` cases, generalised past fan index `0` since a second
    /// fan's `F1Md`/`F1Tg` are exactly as unfit to default to.
    ///
    /// Deliberately narrower than `SMCSensorProvider.kind(for:)`'s fan-suffix convention:
    /// that function also matches `Ac`/`Mn`/`Mx`, which this type already excludes
    /// separately via `fanKeys` (they belong to a fan this poll actually reported, and
    /// are already surfaced as that fan's `.fan`-sourced readout). `Md`/`Tg` are the only
    /// two suffixes that can reach this filter *unexcluded* — a fan's `F<n>Ac` is always
    /// in `fanKeys` when that fan exists at all, but nothing in `[FanPollingReading]`
    /// carries `Md`/`Tg`, so they arrive here as ordinary, possibly catalog-labelled,
    /// sensor candidates unless this check removes them.
    private static func isFanControlPlaneKey(_ key: String) -> Bool {
        let characters = Array(key)
        guard characters.count == 4, characters[0] == "F", characters[1].isASCII,
            characters[1].isNumber
        else { return false }
        switch String(characters[2...]) {
        case "Md", "Tg": return true
        default: return false
        }
    }
}
