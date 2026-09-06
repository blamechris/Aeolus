import SMCCore

/// Applies a `TemperatureUnit` preference to one already-decoded `KeyedReading`, for
/// display only.
///
/// This is the single place `AeolusUI` converts a temperature for presentation — used by
/// `SensorRowModel` (the main window) and `MenuBar/MenuBarContentView`,
/// `MenuBar/MenuBarLabelView` (the menu bar) alike, so the same key never shows two
/// different converted values depending on which view rendered it.
///
/// Every non-temperature kind, and every `.unavailable` reading, passes through
/// unchanged: a unit preference has an opinion about Celsius/Fahrenheit and nothing else,
/// and there is no value to convert when nothing was read. Nothing here re-reads the SMC
/// or re-applies `SMCCore`'s type/byte-order decoding — it only ever transforms a
/// `Double` `KeyedReading` already carries, per `TemperatureUnit`'s own documentation.
enum TemperatureDisplay {
    /// - Returns: `reading` converted to `temperatureUnit`, or `reading` unchanged if
    ///   `kind` is not `.temperatureCelsius` or `reading` has no value to convert.
    static func convert(
        _ reading: KeyedReading, kind: SensorReading.Kind, to temperatureUnit: TemperatureUnit
    ) -> KeyedReading {
        guard kind == .temperatureCelsius, case .value(let celsius) = reading.availability else {
            return reading
        }
        return .value(key: reading.key, temperatureUnit.displayValue(fromCelsius: celsius))
    }

    /// The unit suffix to render alongside a converted temperature reading, or `nil` for
    /// every other kind — callers fall back to their own kind-to-unit mapping in that
    /// case (e.g. `SensorRowModel.unit(for:)`), since this type has an opinion about
    /// temperature only.
    static func unit(for kind: SensorReading.Kind, temperatureUnit: TemperatureUnit) -> String? {
        guard kind == .temperatureCelsius else { return nil }
        return temperatureUnit.suffix
    }
}
