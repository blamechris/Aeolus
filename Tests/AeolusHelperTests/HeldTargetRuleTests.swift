import Foundation
import Testing

@testable import AeolusHelper

/// `ReadOnlyFanReport.heldTarget`, the rule the supervised snapshot states a fan's `targetRPM` by
/// (ADR 0014's #410 snapshot-target amendment), as a table: one row where every condition holds,
/// one row per condition with only that one failing, and the kept fan.
///
/// Each failing row holds the other three conditions, so a row is red only when its own guard is
/// gone. Fan 0 is the fan asked about; fan 1 is covered by the same lease and has a record of its
/// own, so a rule that read any fan's record in place of fan 0's has one to find.
@Suite("The snapshot's target rule, one row per condition", .timeLimit(.minutes(1)))
struct HeldTargetRuleTests {

    /// One row of the table: the four inputs for fan 0, and what the rule must answer.
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        var leasedFans: Set<Int> = [0, 1]
        var recorded: [Int: Double] = [0: 3_000, 1: 4_000]
        var observedMode: FirmwareFanMode? = .manual
        var reclaimedBySystem = false
        let expected: Double?

        var testDescription: String { name }
    }

    /// **Mutations, each run on its own** (local runs, cited in the PR):
    ///
    /// - Delete the guard on `leasedFans`. Run: red on "the lease does not cover the fan".
    /// - Read `recorded[index] ?? recorded.values.first` in place of `recorded[index]`, so a record
    ///   of any fan stands for fan 0's. Run: red on "§ 5 holds no record of the fan under the
    ///   lease" and on the kept fan. The guard cannot be deleted on its own, because the rule
    ///   returns the record; reading another fan's is how a dropped condition would show.
    /// - Delete the guard on `observedMode`. Run: red on both mode rows.
    /// - Write that guard as `observedMode != .automatic`. Run: red on "the mode did not read".
    /// - Delete the guard on `reclaimedBySystem`. Run: red on "§ 5 has marked the fan reclaimed".
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
        // #423's kept fan: its hand-back was refused, so it reads manual under its live lease, and
        // level 6 dropped § 5's record of it before the hand-back. Nothing holds it at a target.
        Row(name: "a kept fan whose hand-back was refused", recorded: [1: 4_000], expected: nil),
    ]

    @Test("The target is § 5's record only while every condition holds", arguments: rows)
    func theTargetIsTheRecordOnlyWhileEveryConditionHolds(row: Row) {
        let target = ReadOnlyFanReport.heldTarget(
            ofFan: 0, leasedFans: row.leasedFans, recorded: row.recorded,
            observedMode: row.observedMode, reclaimedBySystem: row.reclaimedBySystem)

        #expect(
            target == row.expected, "\(row.name): the rule answered \(String(describing: target))")
    }
}
