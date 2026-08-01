import SMCCore
import Testing

// Fixtures shared by the fan-enumeration suites.
//
// Split out of `FanEnumerationTests.swift` when adding the addressable-index test pushed
// that file one line past the 400-line limit. `internal` rather than `private` is the
// point of the split: `FanEnumerationHardwareTests.swift` needs `value(_:)`, and a second
// copy of a one-line accessor is how two suites begin disagreeing about what
// "unavailable" means.

/// One fan's three readings, as a fixture. A named type rather than a tuple so the call
/// sites below read as `.init(actual:minimum:maximum:)` and cannot silently transpose two
/// of the three.
struct FanFixture {
    let actual: Double
    let minimum: Double
    let maximum: Double

    init(actual: Double, minimum: Double = 1350, maximum: Double = 5777) {
        self.actual = actual
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Builds the canned outcome table for a machine reporting `fanCount` fans, each of them
/// reading the given actual/minimum/maximum. Keys not produced here answer `.unknownKey`
/// from the fake, which is what a machine that does not expose them would report.
func machine(
    fanCount: Double,
    fans: [FanFixture] = []
) -> [String: Result<SensorReading, SensorReadFailure>] {
    var table: [String: Result<SensorReading, SensorReadFailure>] = [
        SMCFanEnumeration.fanCountKey: .rpm(SMCFanEnumeration.fanCountKey, fanCount)
    ]
    for (index, fan) in fans.enumerated() {
        table[SMCFanEnumeration.actualKey(forFan: index)] =
            .rpm(SMCFanEnumeration.actualKey(forFan: index), fan.actual)
        table[SMCFanEnumeration.minimumKey(forFan: index)] =
            .rpm(SMCFanEnumeration.minimumKey(forFan: index), fan.minimum)
        table[SMCFanEnumeration.maximumKey(forFan: index)] =
            .rpm(SMCFanEnumeration.maximumKey(forFan: index), fan.maximum)
    }
    return table
}

/// The value of a fan's key, or `nil` when it is unavailable. Used only to assert on what
/// enumeration surfaced; production code switches on the outcome rather than flattening it.
func value(_ outcome: SensorReadOutcome) -> Double? {
    guard case .success(let reading) = outcome.result else { return nil }
    return reading.value
}

func failure(_ outcome: SensorReadOutcome) -> SensorReadFailure? {
    guard case .failure(let failure) = outcome.result else { return nil }
    return failure
}
