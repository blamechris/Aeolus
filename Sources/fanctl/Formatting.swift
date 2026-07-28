import Foundation

/// Human-readable number formatting shared by the table renderers. `--json` output never
/// goes through this — it encodes the full-precision `Double` — this is display-only.
enum Formatting {
    /// Renders `value` as a whole number when it already is one, or to two decimal
    /// places otherwise. SMC readings decode to whole RPM, whole-plus-quarter RPM
    /// (`fpe2`), and IEEE-754 floats depending on key and generation — this stays
    /// readable across all three without pretending to more precision than two places.
    static func number(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
