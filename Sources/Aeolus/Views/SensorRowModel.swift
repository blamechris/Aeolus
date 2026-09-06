import FanKit
import Foundation
import SMCCore

/// A pure, testable projection of `SensorPollingReading` into what a sensor row shows.
///
/// `label`/`categoryLabel`/`confidence` come from `decoration` and are `nil` together
/// when the catalog has no opinion on this key — an unrecognised or unlabelled sensor is
/// a normal, fully-functional result, not a degraded one. `key` is carried unconditionally
/// regardless: per `CLAUDE.md`, the raw key is shown alongside any label, never in its
/// place.
struct SensorRowModel: Equatable, Identifiable {
    let id: String
    let key: String
    let label: String?
    let categoryLabel: String?
    let confidence: CatalogConfidence?
    let value: KeyedValueDisplay

    /// - Parameters:
    ///   - reading: The live sample to project into a row.
    ///   - temperatureUnit: `Preferences.temperatureUnit`, applied for display only via
    ///     `TemperatureDisplay` — see that type's documentation for why this never
    ///     changes what `reading.sample` decoded to. Defaults to `.celsius`, `SMCCore`'s
    ///     own decoded unit, so every existing call site is unaffected by this
    ///     parameter's addition.
    init(reading: SensorPollingReading, temperatureUnit: TemperatureUnit = .celsius) {
        id = reading.key
        key = reading.key
        label = reading.decoration?.label
        categoryLabel = reading.decoration?.category.schemaValue
        confidence = reading.decoration?.confidence
        let displaySample = TemperatureDisplay.convert(
            reading.sample, kind: reading.kind, to: temperatureUnit)
        let displayUnit =
            TemperatureDisplay.unit(for: reading.kind, temperatureUnit: temperatureUnit)
            ?? Self.unit(for: reading.kind)
        value = KeyedValueDisplay(reading: displaySample, unit: displayUnit)
    }

    /// A display unit for `reading.kind`, or `nil` when the kind carries no natural unit
    /// suffix (`.unknown` — see `SMCSensorProvider.kind(for:)`'s documentation for why
    /// most SMC keys stay `.unknown` rather than guessing).
    static func unit(for kind: SensorReading.Kind) -> String? {
        switch kind {
        case .temperatureCelsius: return "°C"
        case .rpm: return "RPM"
        case .watts: return "W"
        case .volts: return "V"
        case .amps: return "A"
        case .percent: return "%"
        case .unknown: return nil
        }
    }
}
