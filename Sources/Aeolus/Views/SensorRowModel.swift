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

    init(reading: SensorPollingReading) {
        id = reading.key
        key = reading.key
        label = reading.decoration?.label
        categoryLabel = reading.decoration?.category.schemaValue
        confidence = reading.decoration?.confidence
        value = KeyedValueDisplay(reading: reading.sample, unit: Self.unit(for: reading.kind))
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
