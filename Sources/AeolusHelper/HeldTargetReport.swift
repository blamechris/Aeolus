// The target the supervised snapshot states for a fan
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 snapshot-target amendment).
//
// Until #410's item 5 the snapshot said `targetRPM: nil` for every fan, unconditionally. Once B1
// makes the write plane `.built`, a snapshot after `apply` would then say a fan is in manual and
// asking for nothing while level 6 holds it at a target. The answer is § 5's record of what was
// put on the wire, under the snapshot's live lease, and only while the same snapshot shows the fan
// holding manual control: `CLAUDE.md` rule 6, never claim control you do not have.
//
// Pure functions beside `AvailabilityRestatement.swift`, for that file's reason: the rule is the
// part worth reading on its own, it needs none of the authority's state, and
// `SupervisedFanAuthority.swift` has no lines to hold it.

extension ReadOnlyFanReport {

    /// The target the supervised snapshot states for fan `index`, or `nil`.
    ///
    /// § 5's recorded target when **all four** of these hold, and `nil` otherwise:
    ///
    /// 1. **`leasedFans`:** the snapshot's live lease covers the fan. The fans of the lease the
    ///    view shows, read in the same hop as it.
    /// 2. **`recorded`:** § 5 holds a record of the fan under that lease's id, with a target.
    ///    `ReclamationReporting.recordedTargets(under:)`'s answer, which filters on the lease id.
    /// 3. **`observedMode`:** the same snapshot read the fan's `F<n>Md` as manual. Not automatic,
    ///    and not unread: a mode the snapshot could not read confirms nothing.
    /// 4. **`reclaimedBySystem`:** § 5's ledger carries no `.systemReclaimed` cause for the fan,
    ///    the same condition `FanState.isReclaimedBySystem` is read from.
    ///
    /// So a non-nil answer comes only beside `mode == .manualFixed`, `!isReclaimedBySystem` and a
    /// lease covering the fan. A reclaimed fan has no target, its mode as the firmware read and
    /// the mark once § 5 has judged it; when § 5's re-assert converges, the mark clears and the
    /// target returns.
    ///
    /// **What the record is, and what it is not yet.** It holds the `CommandedTarget` level 6
    /// reported, or § 5's own re-assert last wrote: the step after the clamp, never the client's
    /// request. It is a confirmation only once B1's command turn reads the target back and throws
    /// outside `targetToleranceRPM` (ADR 0004; D7; U4, #9). On a `.notBuilt` plane no fan is ever
    /// commanded, so every fan reports `nil`.
    ///
    /// The conditions are separate guards, in this order, so each can be removed on its own:
    /// `HeldTargetRuleTests` is one row per condition, and each row is red with its guard gone.
    static func heldTarget(
        ofFan index: Int, leasedFans: Set<Int>, recorded: [Int: Double],
        observedMode: FirmwareFanMode?, reclaimedBySystem: Bool
    ) -> Double? {
        guard leasedFans.contains(index) else { return nil }
        guard let target = recorded[index] else { return nil }
        guard observedMode == .manual else { return nil }
        guard !reclaimedBySystem else { return nil }
        return target
    }
}
