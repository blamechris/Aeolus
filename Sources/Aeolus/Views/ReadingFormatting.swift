import Foundation

/// Human-readable rendering shared by every fan and sensor row.
///
/// Mirrors `fanctl`'s identical `Formatting.number` (`Sources/fanctl/Formatting.swift`)
/// and its "unavailable (<reason>)" convention (`SensorsCommand.rendered(_:)`),
/// reimplemented here rather than imported: `AeolusUI` does not depend on the `fanctl`
/// executable target, and each unprivileged client owning its own thin formatting layer
/// is the same split this project already makes for `SensorProvider`-reading logic (see
/// `FanPoller`/`SensorPoller`'s documentation).
enum ReadingFormatting {
    /// Renders `value` as a whole number when it already is one, or to two decimal places
    /// otherwise. SMC readings decode to whole RPM, whole-plus-quarter RPM (`fpe2`), and
    /// IEEE-754 floats depending on key and generation — this stays readable across all
    /// three without pretending to more precision than two places.
    ///
    /// - Important: Never traps, on any `Double` — same rationale as `fanctl`'s
    ///   `Formatting.number`: `SMCValue.scalar()` applies no finiteness or magnitude
    ///   guard on the way out of `SMCCore`, so a byte-swapped `flt` can decode to
    ///   `±.infinity`/`.nan`, and `Int(exactly:)` (never `Int(_:)`) is what keeps that
    ///   from crashing the window instead of just looking wrong.
    static func number(_ value: Double) -> String {
        guard value.isFinite else {
            return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
        }
        if let whole = Int(exactly: value) {
            return String(whole)
        }
        return String(format: "%.2f", value)
    }

    /// Renders one `KeyedReading` as display text.
    ///
    /// `.value` renders as the formatted number, with `unit` appended when supplied.
    /// `.unavailable` renders as an explicit "unavailable (<reason>)" string — never as
    /// `0`, an empty string, or a bare "—" that could be mistaken for an actual reading.
    /// A value below a declared minimum (e.g. `F0Ac` measured under `F0Mn` on this
    /// project's development hardware) is not treated specially: it renders exactly like
    /// any other `.value`, because it is a legitimate observation, not a fault.
    static func text(for reading: KeyedReading, unit: String? = nil) -> String {
        switch reading.availability {
        case .value(let value):
            let formatted = number(value)
            guard let unit else { return formatted }
            return "\(formatted) \(unit)"
        case .unavailable(let reason):
            return "unavailable (\(reason))"
        }
    }
}
