import Foundation
import SMCCore

/// The single place `AeolusUI` turns a `KeyedReading` into display text.
///
/// ## Why this file exists here, and why both #62 and #63 must import it
///
/// `CLAUDE.md`'s formatting rule is specific: never a second implementation, because that
/// is how the main window and the menu bar end up showing a different value for the same
/// key at the same moment. At the time this file was written E7.2 (the two-pane main
/// window, `#62`) had not yet landed a shared formatter of its own — its issue's
/// implementation plan places its own work under `Sources/Aeolus/Views/`, so this lives
/// in a sibling directory neither in-flight PR otherwise touches, specifically so the
/// inevitable rebase between the two is a straight merge rather than a conflict. If `#62`
/// already has an equivalent by the time these land together, the fix is to delete one and
/// repoint its call sites — never to keep both.
///
/// ## What this deliberately does not do
///
/// This never touches `KeyedReading.Availability` itself — an unavailable reading is
/// rendered as `unavailablePlaceholder`, a value that cannot be confused with any real
/// reading, including `0`. Callers that need to distinguish "unavailable" from "available"
/// for anything other than display text (styling, sorting, tests) should still switch on
/// `KeyedReading.availability` directly rather than parse this type's output.
public enum ReadingFormatting {
    /// Shown in place of a value whenever a `KeyedReading` is `.unavailable` — an em dash,
    /// visually distinct from any number this project would ever render, including `0`.
    /// Never blank: a blank space in a compact menu bar label reads as "nothing to report"
    /// just as easily as it reads as "loading," and neither is the truth when a read
    /// genuinely failed.
    public static let unavailablePlaceholder = "\u{2014}"

    /// Renders `reading` as display text for `kind`'s unit.
    ///
    /// - Parameters:
    ///   - reading: The value to render, or the reason it is not available right now.
    ///   - kind: The unit `reading.value` is in. Sourced from `SensorReading.Kind` —
    ///     never guessed from a catalog category, which describes *what component* a
    ///     sensor belongs to, not *what physical unit* it reports; see
    ///     `SMCSensorProvider.kind(for:)`'s own documentation for why kind
    ///     classification stays conservative rather than inferring from a key's prefix.
    /// - Returns: `reading`'s value formatted with `kind`'s unit suffix, or
    ///   `unavailablePlaceholder` if `reading` is `.unavailable`.
    public static func displayText(for reading: KeyedReading, kind: SensorReading.Kind) -> String {
        switch reading.availability {
        case .value(let value):
            return string(for: value, kind: kind)
        case .unavailable:
            return unavailablePlaceholder
        }
    }

    /// Renders `value` with the unit suffix `kind` implies. `kind == .unknown` renders no
    /// suffix at all — an unclassified reading gets a bare number, not an invented unit.
    static func string(for value: Double, kind: SensorReading.Kind) -> String {
        let number = numberText(value)
        switch kind {
        case .temperatureCelsius: return "\(number)\u{00B0}C"
        case .rpm: return "\(number) RPM"
        case .watts: return "\(number) W"
        case .volts: return "\(number) V"
        case .amps: return "\(number) A"
        case .percent: return "\(number)%"
        case .unknown: return number
        }
    }

    /// Renders `value` as a whole number when it already is one, or to two decimal places
    /// otherwise. Identical rule and identical `Int(exactly:)` non-trapping guard as
    /// `fanctl`'s `Formatting.number(_:)` (`Sources/fanctl/Formatting.swift`) — see that
    /// type's documentation for why `Int(value)` is never safe here: a byte-swapped `flt`
    /// or an out-of-`Int`-range `ui64`/`si64` must fall back to `%.2f`, never trap the
    /// process. Reimplemented rather than imported: `fanctl` is a separate executable
    /// target `AeolusUI` does not depend on, the same split `KeyedReading` itself
    /// documents for its own `fanctl`-mirroring shape.
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else {
            return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
        }
        if let whole = Int(exactly: value) {
            return String(whole)
        }
        return String(format: "%.2f", value)
    }
}
