import Foundation

/// Formats a `ResolvedMenuBarReadout` for display — the single place `MenuBarLabelView`
/// (the compact strip) and `MenuBarContentView` (the full dropdown) both go through, so a
/// value's identity and unit are never left to the reader to infer. One deliberate
/// exception: the strip suppresses a fan's control-state suffix when it is cleared to
/// automatic or not tracked, to save width, while the dropdown always spells it out —
/// see `isNoteworthyControlState` below for why that asymmetry is safe.
///
/// ## `#249`: the strip must never drop the meaning a value depends on
///
/// Before this type existed, the strip joined bare formatted values with nothing else —
/// `"1340.73 RPM  1470.74 RPM  0  1350 RPM"` on the hardware that found this bug, where
/// the third figure was `F0Md` (a mode flag) and the fourth was `F0Tg` (a setpoint), both
/// rendered identically to the two real live RPM readings beside them. The dropdown was
/// only marginally more honest: it showed label and key, but still rendered the *value*
/// as a bare number with no indication that `0` here means something entirely different
/// from `0 RPM`. `identifiedText(for:temperatureUnit:)` is the fix for both: every strip
/// entry always carries an identifier (its catalog/fan label, or the raw key when there is
/// no label), and every fan-sourced entry carries its control state — so a reader is never
/// left to infer a value's meaning from its position in the list.
///
/// This does not depend on `#249`'s other fix (`MenuBarReadoutSelection` no longer
/// defaulting to `F0Md`/`F0Tg`): a user can still *choose* either key deliberately via
/// `MenuBarContentsPreferencesView` — "nameable, not defaultable." `identifiedText(for:
/// temperatureUnit:)` keeps that choice honest in the strip, where identifier and value
/// are always the one string this type composes. The dropdown renders the two separately
/// (`MenuBarContentView`'s row draws the identifier and `value(for:)`'s result in their
/// own `Text` views); there, a bare `value(for:)` result staying legible depends on the
/// caller placing it beside that identifier — this formatter has no way to enforce that
/// composition on its own.
enum MenuBarReadoutFormatting {
    /// The formatted value alone (temperature-converted per `temperatureUnit`, unit
    /// appended when `readout.kind` implies one) — no label, no key, no control state.
    /// Shared by both display sites so a value never decodes two different ways; callers
    /// needing more context use `identifiedText(for:temperatureUnit:)`.
    static func value(
        for readout: ResolvedMenuBarReadout, temperatureUnit: TemperatureUnit
    )
        -> String
    {
        let displayReading = TemperatureDisplay.convert(
            readout.reading, kind: readout.kind, to: temperatureUnit)
        let unit =
            TemperatureDisplay.unit(for: readout.kind, temperatureUnit: temperatureUnit)
            ?? readout.unit
        return ReadingFormatting.text(for: displayReading, unit: unit)
    }

    /// What a fan-sourced readout's control state should say, reusing `FanRowModel`'s
    /// exact wording — the same module already has one correct answer for "Automatic" /
    /// "Mode not tracked" / "Reclaimed by system"; the menu bar restating it with different
    /// words would be exactly the "renders three different ways" inconsistency `#249`
    /// reported between the main window, the dropdown, and the strip. `nil` for a
    /// `.sensor`-sourced readout, which has no control mode to report.
    static func controlStateSuffix(for readout: ResolvedMenuBarReadout) -> String? {
        guard let control = readout.fanControl else { return nil }
        return FanRowModel.controlStateLabel(for: control)
    }

    /// The strip's compact, self-describing form: `"<identifier> <value>"`, plus
    /// `" (<control state>)"` when `readout` is fan-sourced **and** that state is worth
    /// the strip's limited width — see `isNoteworthyControlState(_:)`. `identifier` is
    /// `readout.label` when the catalog or fan poll supplied one, or `readout.key`
    /// otherwise — never nothing, so a value's meaning is never carried solely by its
    /// position among other readouts. See this type's own documentation for the `#249`
    /// finding this specifically fixes.
    static func identifiedText(
        for readout: ResolvedMenuBarReadout, temperatureUnit: TemperatureUnit
    )
        -> String
    {
        let identifier = readout.label ?? readout.key
        var text = "\(identifier) \(value(for: readout, temperatureUnit: temperatureUnit))"
        if let suffix = controlStateSuffix(for: readout), isNoteworthyControlState(readout) {
            text += " (\(suffix))"
        }
        return text
    }

    /// True when a fan-sourced readout's control state is worth spending the strip's
    /// scarce width on: anything the helper reports other than a fan cleared to automatic.
    ///
    /// Two states are left out, and both for width: "Automatic" (a fan the helper reports
    /// cleared, `FanState.isClearedToAutomatic`), and "Mode not tracked", which every fan on a
    /// `Monitor` build carries and which would otherwise be dead weight on every strip entry.
    /// Leaving a suffix out claims nothing either way — the strip shows an RPM — and the
    /// dropdown (`MenuBarContentView`) calls `controlStateSuffix(for:)` directly and always
    /// spells the state out. This does not narrow rule 6's visibility guarantee: a reported
    /// reclamation alone makes this `true` whatever the mode reads, so a fan the system has
    /// taken back is never silently omitted from the strip on the strength of this
    /// suppression.
    private static func isNoteworthyControlState(_ readout: ResolvedMenuBarReadout) -> Bool {
        guard case .reported(let state, _) = readout.fanControl else { return false }
        return !state.isClearedToAutomatic || state.isReclaimedBySystem
    }

    /// Every readout's `identifiedText(for:temperatureUnit:)`, in order, joined for the
    /// strip. Empty input produces an empty string — callers (`MenuBarLabelView`) decide
    /// what to show in place of no readouts, since that depends on `PollingPhase`, which
    /// this pure formatter has no opinion about.
    static func stripText(
        for readouts: [ResolvedMenuBarReadout], temperatureUnit: TemperatureUnit
    ) -> String {
        readouts.map { identifiedText(for: $0, temperatureUnit: temperatureUnit) }
            .joined(separator: "  ")
    }
}
