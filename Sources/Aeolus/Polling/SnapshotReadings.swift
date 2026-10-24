import AeolusXPC
import FanKit
import SMCCore

/// A helper snapshot, as the rows the app already renders.
///
/// The direct-read path produces `FanPollingReading`s and `SensorPollingReading`s from the
/// SMC; this produces the same two types from a `SystemSnapshot`, so every view renders
/// either source through one code path and can tell them apart only by `control`.
///
/// Everything here comes from **one** snapshot. ADR 0006 forbids mixing observations with
/// control claims from a different generation, and a row built from this snapshot's RPM and
/// another's mode would be exactly that.
enum SnapshotReadings {

    /// One row per fan the snapshot reports, in index order, each carrying the helper's
    /// `FanState` whole and the snapshot's emergency flag beside it.
    ///
    /// The raw keys come from `SMCFanEnumeration`, the functions the direct path and the
    /// helper's own fan reads both name them with — never respelled here — because the snapshot
    /// reports values and not the keys they were read from, and a row must show its key.
    static func fans(in snapshot: SystemSnapshot) -> [FanPollingReading] {
        snapshot.fans
            .sorted { $0.index < $1.index }
            .map { fan in
                FanPollingReading(
                    index: fan.index,
                    displayName: "Fan \(fan.index)",
                    actual: keyed(SMCFanEnumeration.actualKey(forFan: fan.index), fan.actualRPM),
                    minimum: keyed(
                        SMCFanEnumeration.minimumKey(forFan: fan.index), fan.minimumRPM),
                    maximum: keyed(
                        SMCFanEnumeration.maximumKey(forFan: fan.index), fan.maximumRPM),
                    control: .reported(
                        fan, thermalEmergency: snapshot.isThermalEmergencyActive))
            }
    }

    /// One row per sensor sample, sorted by key as the direct path's discovery is.
    ///
    /// A key is the helper's text and is shown, and kept, exactly as it arrives — a selection
    /// is persisted by it — so it is not cleaned but **checked**: a sample whose key could not
    /// be shown verbatim (`HelperAuthoredText.isDisplayableVerbatim(_:)`) is left out rather
    /// than drawn with a control or line-breaking character in it, or under a different name.
    ///
    /// Labels come from `labelSource`, the same catalog the direct path decorates with, and not
    /// from the snapshot's own `label`: a key then reads the same in the window whichever
    /// source answered, and the raw key is shown beside either way.
    static func sensors(
        in snapshot: SystemSnapshot, labelSource: some SensorLabelSource
    ) -> [SensorPollingReading] {
        snapshot.sensors
            .filter { HelperAuthoredText.isDisplayableVerbatim($0.key) }
            .sorted { $0.key < $1.key }
            .map { sample in
                SensorPollingReading(
                    key: sample.key,
                    kind: kind(of: sample.unit),
                    sample: sample.value.isFinite
                        ? .value(key: sample.key, sample.value)
                        : .unavailable(
                            key: sample.key, reason: "the helper reported a non-finite value"),
                    decoration: labelSource.decoration(for: sample.key))
            }
    }

    /// A helper's fan reading as a keyed one. The unavailable reason is the helper's free
    /// text, so it is cleaned on the way in.
    ///
    /// Read through `FanReading.value` rather than by matching the measured case by name:
    /// `FanTests.onlyConstructedInFanSwift` holds every line naming that case to `Fan.swift`.
    private static func keyed(_ key: String, _ reading: FanReading) -> KeyedReading {
        if let value = reading.value, value.isFinite {
            return .value(key: key, value)
        }
        if case .unavailable(let reason) = reading {
            return .unavailable(key: key, reason: HelperAuthoredText.sanitised(reason))
        }
        return .unavailable(key: key, reason: "the helper reported a non-finite value")
    }

    private static func kind(of unit: SensorSample.Unit) -> SensorReading.Kind {
        switch unit {
        case .celsius: return .temperatureCelsius
        case .rpm: return .rpm
        case .watts: return .watts
        case .volts: return .volts
        case .amps: return .amps
        case .percent: return .percent
        case .unknown: return .unknown
        }
    }
}
