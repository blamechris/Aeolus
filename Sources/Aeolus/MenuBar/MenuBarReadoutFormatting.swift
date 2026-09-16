import Foundation

/// Formats a `ResolvedMenuBarReadout` for display — the single place `MenuBarLabelView`
/// (the compact strip) and `MenuBarContentView` (the full dropdown) both go through, so
/// the same readout is never described two different ways depending on which one drew it.
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
/// `MenuBarContentsPreferencesView` — "nameable, not defaultable" — and this formatter is
/// what keeps that choice honest wherever it is rendered.
enum MenuBarReadoutFormatting {
    /// The formatted value alone (temperature-converted per `temperatureUnit`, unit
    /// appended when `readout.kind` implies one) — no label, no key, no control state.
    /// Shared by both display sites so a value never decodes two different ways; callers
    /// needing more context use `identifiedText(for:temperatureUnit:)`.
    static func value(for readout: ResolvedMenuBarReadout, temperatureUnit: TemperatureUnit)
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
    /// "Manual — fixed speed" / "Reclaimed by system (was …)"; the menu bar restating it
    /// with different words would be exactly the "renders three different ways"
    /// inconsistency `#249` reported between the main window, the dropdown, and the
    /// strip. `nil` for a `.sensor`-sourced readout, which has no control mode to report.
    static func controlStateSuffix(for readout: ResolvedMenuBarReadout) -> String? {
        guard let state = readout.fanControlState else { return nil }
        return FanRowModel.controlStateLabel(
            mode: state.mode, isReclaimedBySystem: state.isReclaimedBySystem)
    }

    /// The strip's compact, self-describing form: `"<identifier> <value>"`, plus
    /// `" (<control state>)"` when `readout` is fan-sourced. `identifier` is
    /// `readout.label` when the catalog or fan poll supplied one, or `readout.key`
    /// otherwise — never nothing, so a value's meaning is never carried solely by its
    /// position among other readouts. See this type's own documentation for the `#249`
    /// finding this specifically fixes.
    static func identifiedText(for readout: ResolvedMenuBarReadout, temperatureUnit: TemperatureUnit)
        -> String
    {
        let identifier = readout.label ?? readout.key
        var text = "\(identifier) \(value(for: readout, temperatureUnit: temperatureUnit))"
        if let suffix = controlStateSuffix(for: readout) {
            text += " (\(suffix))"
        }
        return text
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
