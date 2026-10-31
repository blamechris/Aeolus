import Foundation

/// Human-readable number formatting shared by the table renderers. `--json` output never
/// goes through this — it encodes the `Double` directly (after sanitisation — by
/// `SMCFanEnumeration.checked(_:in:)` for `list`/`watch`, and by `SensorsCommand`'s own
/// `sanitize` helper for `sensors`) — this is display-only.
enum Formatting {
    /// Renders `value` as a whole number when it already is one, or to two decimal
    /// places otherwise. SMC readings decode to whole RPM, whole-plus-quarter RPM
    /// (`fpe2`), and IEEE-754 floats depending on key and generation — this stays
    /// readable across all three without pretending to more precision than two places.
    ///
    /// - Important: Never traps, on any `Double`. `SMCValue.scalar()` applies no
    ///   finiteness or magnitude guard on the way out of `SMCCore`: a byte-swapped
    ///   `flt` — the `.modern`, bit-clear branch is untested on real hardware (every
    ///   `flt` key observed on `Mac16,5` carries the bit set; see
    ///   `docs/ADR/0004-float-byte-order.md`) — can decode to `±.infinity`, `.nan`, or
    ///   a value outside `Int`'s range, and a `ui64`/`si64` key can legitimately exceed
    ///   `Int64.max` on its own (`Double(UInt64.max)` already does). `value ==
    ///   value.rounded()` is `true` for `.infinity` — a genuine `Double` property, not a
    ///   bug — so the naive `Int(value)` this function used to call traps on exactly the
    ///   byte-order anomaly this CLI exists to surface. `Int(exactly:)` never traps: it
    ///   returns `nil`, rather than crashing, for anything fractional, non-finite, or
    ///   out of `Int`'s range, and this falls back to the `%.2f` branch for all of those
    ///   instead of the process.
    static func number(_ value: Double) -> String {
        guard value.isFinite else {
            return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
        }
        if let whole = Int(exactly: value) {
            return String(whole)
        }
        return String(format: "%.2f", value)
    }

    /// Renders `value` exactly: like `number(_:)` for a non-finite value or one that is a
    /// whole `Int`, and otherwise as Swift's shortest description that reads back as the same
    /// `Double`, never rounded to two places.
    ///
    /// For a value that was refused *because* it is not whole, such as a fractional `FNum`.
    /// `number(_:)` would print 1.9999999 as "2.00" and 0.001 as "0.00". Both read as whole
    /// numbers inside the trusted range, which hides the one fact the message reports.
    /// Never traps, for the same reason as `number(_:)`.
    static func exactNumber(_ value: Double) -> String {
        guard value.isFinite, Int(exactly: value) == nil else {
            return number(value)
        }
        return "\(value)"
    }
}
