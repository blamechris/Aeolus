import Foundation

/// The two temperature units Preferences (`#64`) lets a user choose between, for display
/// only.
///
/// ## Display formatting, never decoding
///
/// `SMCCore` decodes every temperature key to Celsius — that is what the firmware's
/// declared type and byte order produce, and neither this type nor anything that reads
/// it may change that. `displayValue(fromCelsius:)` takes the *already-decoded* Celsius
/// `Double` a `KeyedReading` carries and converts it for presentation; it is never given
/// raw SMC bytes, and nothing upstream of it re-reads or re-decodes anything when this
/// preference changes. See `TemperatureDisplay`, the one place in `AeolusUI` that calls
/// this conversion on a live reading.
public enum TemperatureUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case celsius
    case fahrenheit

    /// The suffix a formatted value carries — `ReadingFormatting`'s existing convention
    /// for every other kind, extended here rather than replaced.
    public var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    /// Converts an already-decoded Celsius value into this unit, for display only.
    ///
    /// - Parameter celsius: A value already produced by `SMCCore`'s decoder — this
    ///   function never sees, and never needs, the raw SMC bytes it came from.
    /// - Returns: `celsius` unchanged for `.celsius`, or the Fahrenheit equivalent for
    ///   `.fahrenheit`.
    public func displayValue(fromCelsius celsius: Double) -> Double {
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9.0 / 5.0 + 32.0
        }
    }
}
