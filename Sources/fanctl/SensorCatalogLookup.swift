import Foundation
import SMCCore

/// The unit a sensor value is expressed in, for `--json` output. Mirrors
/// `AeolusXPC.SensorSample.Unit`'s raw values exactly (not by importing the type — see
/// `SensorCatalogLookup`'s note on why these commands stay off XPC), so `"unit"` in the
/// JSON reads as a unit name rather than `SensorReading.Kind`'s own `"temperatureCelsius"`
/// case name.
enum SensorUnit: String, Sendable, Codable, Equatable {
    case celsius
    case rpm
    case watts
    case volts
    case amps
    case percent
    case unknown

    init(kind: SensorReading.Kind) {
        switch kind {
        case .temperatureCelsius: self = .celsius
        case .rpm: self = .rpm
        case .watts: self = .watts
        case .volts: self = .volts
        case .amps: self = .amps
        case .percent: self = .percent
        case .unknown: self = .unknown
        }
    }
}

/// How much a `SensorCatalogLookup` match should be trusted. Mirrors
/// `AeolusXPC.SensorSample.LabelConfidence` in shape (not by importing the type: these
/// commands never touch XPC, per `fanctl`'s design — see `FanctlCommand.swift`), so the
/// helper-backed path E6 eventually adds does not have to change what this field means.
enum SensorLabelConfidence: String, Sendable, Codable, Equatable {
    case verified
    case community
    case guess
}

/// One catalog match: a human-readable name plus how much it should be trusted. Never
/// shown by itself — every caller pairs this with the raw SMC key it decorates, so a
/// wrong label can never quietly stand in for the key it came from.
struct SensorCatalogLabel: Sendable, Equatable {
    let text: String
    let confidence: SensorLabelConfidence
}

/// Decorates a raw SMC key with a human-readable label, if one is known.
///
/// Optional and injectable by design: E6, the sensor catalog itself (#42/#43/#44), is
/// being built in parallel and must not gate this command. `fanctl sensors` has to work
/// completely — every reading shown, fully and normally — with no catalog wired in at
/// all, because that is genuinely the state most machines will be in until someone files
/// a `sensor-catalog.yml` report for them. An unlabelled sensor is a normal result, not a
/// degraded one.
protocol SensorCatalogLookup: Sendable {
    /// Returns a label for `key`, or `nil` if this lookup has no opinion.
    func label(for key: String) -> SensorCatalogLabel?
}

/// The default lookup: labels nothing. Used whenever no real catalog has been wired in,
/// and always used when `--raw-keys` is passed — see `SensorsCommand.swift`.
struct NoSensorCatalog: SensorCatalogLookup {
    func label(for key: String) -> SensorCatalogLabel? { nil }
}
