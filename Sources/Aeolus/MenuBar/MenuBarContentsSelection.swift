/// Everything Preferences' menu-bar-contents toggles need beyond `MenuBarReadoutSelection`
/// (`#63`'s smart *default*): the full universe of toggleable candidates, and pure
/// add/remove logic over a stored selection — kept separate from that type because a
/// picker showing "everything you *could* choose" is a different question from "what
/// should be chosen with nobody asking."
enum MenuBarContentsSelection {
    /// Every fan (as `.fan`) plus every non-fan sensor (as `.sensor`) currently visible in
    /// a poll — the full set a user can toggle on or off, unfiltered by label or `kind`.
    /// `MenuBarReadoutSelection.defaultSelection(fans:sensors:)` narrows a subset of this
    /// same universe down to a sensible *default*; this returns everything so a user can
    /// override that default in either direction.
    static func candidates(
        fans: [FanPollingReading], sensors: [SensorPollingReading]
    ) -> [MenuBarReadout] {
        var readouts = fans.map { MenuBarReadout(key: $0.actual.key, source: .fan) }
        let fanKeys = Set(fans.flatMap { [$0.actual.key, $0.minimum.key, $0.maximum.key] })
        readouts.append(
            contentsOf: sensors.filter { !fanKeys.contains($0.key) }
                .map { MenuBarReadout(key: $0.key, source: .sensor) })
        return readouts
    }

    /// Whether `readout` is currently shown in the menu bar.
    ///
    /// - Parameters:
    ///   - readout: The candidate to check.
    ///   - selection: `Preferences.menuBarReadouts`. `nil` means "no explicit choice
    ///     yet" — see that property's documentation — so `defaultSelection` is consulted
    ///     instead, matching what `MenuBarViewModel` itself would currently be showing.
    ///   - defaultSelection: What to consult when `selection` is `nil`.
    /// - Returns: `true` if `readout` is currently shown in the menu bar.
    static func isIncluded(
        _ readout: MenuBarReadout, in selection: [MenuBarReadout]?,
        defaultSelection: [MenuBarReadout]
    ) -> Bool {
        (selection ?? defaultSelection).contains(readout)
    }

    /// Returns `selection` (or `defaultSelection`, if `selection` is `nil`) with
    /// `readout` added if it was absent, or removed if it was present — the toggle a
    /// Preferences checkbox performs on every click.
    ///
    /// Always returns a concrete array, never `nil`: the moment a user touches a toggle,
    /// "no explicit choice yet" becomes a real, explicit choice — even if, after this
    /// call, that choice happens to equal what the default already was.
    static func toggling(
        _ readout: MenuBarReadout, in selection: [MenuBarReadout]?,
        defaultSelection: [MenuBarReadout]
    ) -> [MenuBarReadout] {
        var effective = selection ?? defaultSelection
        if let index = effective.firstIndex(of: readout) {
            effective.remove(at: index)
        } else {
            effective.append(readout)
        }
        return effective
    }
}
