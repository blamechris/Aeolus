import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// Fans, screens and driver states for the per-fan row suites (#154). Namespaced, so nothing here
/// can shadow a global helper another suite in this target declares.
///
/// Fan 0 has `Mac16,5`'s bounds, 1350 to 5777 RPM, and an actual reading of 2345 RPM. Where the
/// driver holds it, the driver's target is **3000** and the snapshot's held target is **3200**, so
/// a field that showed the snapshot's would be a different number.
enum RowFixtures {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Row = FanRowControlPresentation

    /// The driver's target for fan 0 wherever it holds the fan.
    static let driverRPM: Double = 3000
    /// The held target the snapshot reports for fan 0 wherever it lists the lease.
    static let snapshotRPM: Double = 3200

    /// A fan with these bounds and readings, offered by the helper unless said otherwise.
    static func fan(
        _ index: Int, minimum: Double = 1350, maximum: Double = 5777,
        actual: FanReading = .measured(2345), mode: FanControlMode = .automatic,
        target: Double? = nil, availability: ManualControlAvailability = .available
    ) -> FanState {
        FanState(
            index: index, actualRPM: actual, minimumRPM: .measured(minimum),
            maximumRPM: .measured(maximum), targetRPM: target, mode: mode,
            isReclaimedBySystem: false, manualControlAvailability: availability)
    }

    /// No lease listed, both fans offered and on automatic.
    static let free = Support.snapshot(fans: [fan(0), fan(1)])

    /// The app's own lease listed, fan 0 held at `snapshotRPM`, fan 1 offered.
    static let holding = Support.snapshot(
        fans: [fan(0, mode: .manualFixed, target: snapshotRPM), fan(1)],
        activeLease: Fixtures.ours)

    /// A speed fan 0's envelope names for `rpm`.
    static func speed(_ rpm: Double) throws -> FanTargetRPM {
        try AllFansFixtures.envelope(0).target(for: rpm)
    }

    static func held(_ phase: HeldLease.Phase, fans: [Int] = [0]) -> LeaseDriverState {
        Fixtures.held(Fixtures.ours, fans: fans, phase)
    }

    static func target(_ speeds: [Int: Double]) throws -> LeaseTarget {
        try Fixtures.target(speeds)
    }

    /// Fan 0 held at `driverRPM`, confirmed.
    static func heldConfirmed() throws -> LeaseDriverState {
        held(.confirmed(try target([0: driverRPM])))
    }

    /// One state of every `LeaseDriverState` case, and both held phases. Where a state names fans
    /// it names fan 0, at `driverRPM`.
    static func everyState() throws -> [LeaseDriverState] {
        var states = try Fixtures.DriverTag.allCases.map { try $0.state() }
        states.append(held(.applying(try target([0: driverRPM]), queued: nil)))
        return states
    }

    /// The snapshot a screen beside `state` shows: the held lease where the driver holds one, and
    /// otherwise no lease.
    static func snapshot(beside state: LeaseDriverState) -> SystemSnapshot {
        state.isHeld ? holding : free
    }

    /// Fan `index`'s inputs on `screen`, from its row there and its presentation.
    static func inputs(_ index: Int, on screen: Fixtures.Screen) throws -> Row.Inputs {
        let row = try #require(screen.rows.first { $0.index == index }, "no row for fan \(index)")
        return inputs(row, on: screen)
    }

    /// The inputs `row` gives on `screen`'s inputs: for a row whose displayed values differ from
    /// the snapshot's.
    static func inputs(_ row: FanPollingReading, on screen: Fixtures.Screen) -> Row.Inputs {
        Row.Inputs(
            reading: row, presentation: FanControlPresentation(reading: row, given: screen.inputs),
            snapshot: screen.inputs.renderedSnapshot, driver: screen.inputs.driver)
    }

    /// Fan 0's inputs on `snapshot` beside `state`, with any read admitted.
    static func inputs(
        _ snapshot: SystemSnapshot, beside state: LeaseDriverState
    ) throws -> Row.Inputs {
        try inputs(0, on: Fixtures.screen(snapshot, driver: state))
    }

    /// `row`, displaying `minimum` and `maximum` instead of what the snapshot carries, and
    /// `actual` where given.
    static func displaying(
        _ row: FanPollingReading, minimum: Double, maximum: Double, actual: Double? = nil
    ) -> FanPollingReading {
        FanPollingReading(
            index: row.index, displayName: row.displayName,
            actual: actual.map { .value(key: SMCFanEnumeration.actualKey(forFan: row.index), $0) }
                ?? row.actual,
            minimum: .value(key: SMCFanEnumeration.minimumKey(forFan: row.index), minimum),
            maximum: .value(key: SMCFanEnumeration.maximumKey(forFan: row.index), maximum),
            control: row.control)
    }
}
