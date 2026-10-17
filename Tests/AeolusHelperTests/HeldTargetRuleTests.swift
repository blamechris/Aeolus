import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `ReadOnlyFanReport.heldTarget`, the rule the supervised snapshot states a fan's `targetRPM` by
/// (ADR 0014's #410 snapshot-target amendment), as a table: one row where every condition holds,
/// and one row per condition with only that one failing.
///
/// Each failing row holds the other four conditions, so a row is red only when its own guard is
/// gone. Fan 0 is the fan asked about; fan 1 is covered by the same lease and has a record of its
/// own, so a rule that read any fan's record in place of fan 0's has one to find.
///
/// #423's kept fan is not a row of its own: as the rule sees it, it is the "no record" row's
/// inputs, so a row for it could not fail apart from that one. It is pinned through the composed
/// helper instead, at `HeldTargetCompositionTests.swift:134`
/// (`aKeptFanStatesNoTargetAndAReAdoptedOneItsOwn`).
@Suite("The snapshot's target rule, one row per condition", .timeLimit(.minutes(1)))
struct HeldTargetRuleTests {

    /// One row of the table: the five inputs for fan 0, and what the rule must answer.
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        var leasedFans: Set<Int> = [0, 1]
        var recorded: [Int: Double] = [0: 3_000, 1: 4_000]
        var observedMode: FirmwareFanMode? = .manual
        var reclaimedBySystem = false
        var thermalEmergencyActive = false
        let expected: Double?

        var testDescription: String { name }

        /// Fan 0 as the ladder hands it to the rule: the row's mark, and nothing else the rule
        /// reads.
        var fan: FanState {
            FanState(
                index: 0, actualRPM: .measured(3_000), minimumRPM: .measured(1_350),
                maximumRPM: .measured(5_777), targetRPM: nil, mode: .manualFixed,
                isReclaimedBySystem: reclaimedBySystem, manualControlAvailability: .available)
        }
    }

    /// **Mutations, each run on its own** (local runs, cited in the PR):
    ///
    /// - Delete the guard on `leasedFans`. Run: red on "the lease does not cover the fan".
    /// - Read `recorded[fan.index] ?? recorded.values.first` in place of `recorded[fan.index]`, so
    ///   a record of any fan stands for fan 0's. Run: red on "§ 5 holds no record of the fan under
    ///   the lease". The guard cannot be deleted on its own, because the rule returns the record;
    ///   reading another fan's is how a dropped condition would show.
    /// - Delete the guard on `observedMode`. Run: red on both mode rows.
    /// - Write that guard as `observedMode != .automatic`. Run: red on "the mode did not read".
    /// - Delete the guard on `fan.isReclaimedBySystem`. Run: red on "§ 5 has marked the fan
    ///   reclaimed".
    /// - Delete the guard on `thermalEmergencyActive`. Run: red on "§ 3's latch is set".
    static let rows: [Row] = [
        Row(name: "every condition holds", expected: 3_000),
        Row(name: "the lease does not cover the fan", leasedFans: [1], expected: nil),
        Row(
            name: "§ 5 holds no record of the fan under the lease", recorded: [1: 4_000],
            expected: nil),
        Row(
            name: "the snapshot read the mode as automatic", observedMode: .automatic,
            expected: nil),
        Row(name: "the mode did not read", observedMode: nil, expected: nil),
        Row(name: "§ 5 has marked the fan reclaimed", reclaimedBySystem: true, expected: nil),
        Row(name: "§ 3's latch is set", thermalEmergencyActive: true, expected: nil),
    ]

    @Test("The target is § 5's record only while every condition holds", arguments: rows)
    func theTargetIsTheRecordOnlyWhileEveryConditionHolds(row: Row) {
        let target = ReadOnlyFanReport.heldTarget(
            of: row.fan, leasedFans: row.leasedFans, recorded: row.recorded,
            observedMode: row.observedMode, thermalEmergencyActive: row.thermalEmergencyActive)

        #expect(
            target == row.expected, "\(row.name): the rule answered \(String(describing: target))")
    }
}
