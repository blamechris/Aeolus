// The target the supervised snapshot states for a fan
// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 snapshot-target amendment).
//
// Until #410's item 5 the snapshot said `targetRPM: nil` for every fan, unconditionally. Once B1
// makes the write plane `.built`, a snapshot after `apply` would then say a fan is in manual and
// asking for nothing while level 6 holds it at a target. The answer is § 5's record of what was
// put on the wire, under the snapshot's live lease, and only while the same snapshot shows the fan
// holding manual control and § 3 not holding it at maximum: `CLAUDE.md` rule 6, never claim
// control you do not have.
//
// Pure functions beside `AvailabilityRestatement.swift`, for that file's reason: the rule is the
// part worth reading on its own, it needs none of the authority's state, and
// `SupervisedFanAuthority.swift` has no lines to hold it.

import FanKit

extension ReadOnlyFanReport {

    /// One fan as the supervised snapshot states it, once the ladder has restated its
    /// availability: the target `heldTarget` allows in place of the read path's `nil`, and every
    /// other field as the read path and the ladder left it.
    ///
    /// The five inputs are the snapshot's own: `leases.leasedFans`, the fans of the lease the view
    /// reports, read in its hop; `recorded`, § 5's answer for that lease's id, asked after it; and
    /// three from `machine`, the one machine read the fan was built from: its `F<n>Md` answer
    /// (`MachineObservation.modes`), its `isReclaimedBySystem` from § 5's ledger, and § 3's latch
    /// as `isThermalEmergencyActive`. None is read again in a hop of its own. `recorded` is
    /// **required, with no default**, for `observedMode`'s reason on the ladder: a default of
    /// "nothing recorded" would compile and put back the unconditional `nil`.
    static func statingHeldTarget(
        of fan: FanState, in machine: MachineObservation, given leases: LeaseAccountability,
        recorded: [Int: Double]
    ) -> FanState {
        let target = heldTarget(
            of: fan, leasedFans: leases.leasedFans, recorded: recorded,
            observedMode: machine.modes[fan.index],
            thermalEmergencyActive: machine.snapshot.isThermalEmergencyActive)
        return restating(fan, as: fan.manualControlAvailability, target: target)
    }

    /// The target the supervised snapshot states for `fan`, or `nil`.
    ///
    /// § 5's recorded target when **all five** of these hold, and `nil` otherwise:
    ///
    /// 1. **`leasedFans`:** the snapshot's live lease covers the fan. The fans of the lease the
    ///    view shows, read in the same hop as it.
    /// 2. **`recorded`:** § 5 holds a record of the fan under that lease's id, with a target.
    ///    `ReclamationReporting.recordedTargets(under:)`'s answer, which filters on the lease id.
    /// 3. **`observedMode`:** the same snapshot read the fan's `F<n>Md` as manual. Not automatic,
    ///    and not unread: a mode the snapshot could not read confirms nothing.
    /// 4. **`fan.isReclaimedBySystem`:** § 5's ledger carries no `.systemReclaimed` cause for the
    ///    fan. The fan's own field, so the rule reads the condition that field is read from.
    /// 5. **`thermalEmergencyActive`:** § 3's latch is not set, as the same snapshot's
    ///    `isThermalEmergencyActive` read it. § 3 holds a latched machine's fans at maximum and
    ///    outranks level 6 (ADR 0007), and the lease outlives the latch until `fire` revokes it,
    ///    so without this a snapshot taken between a fan's maximum and that revocation would state
    ///    the client's target beside the maximum (#426's review).
    ///
    /// So a non-nil answer comes only beside `mode == .manualFixed`, `!isReclaimedBySystem`,
    /// `!isThermalEmergencyActive` and a lease covering the fan. A reclaimed fan has no target, its
    /// mode as the firmware read and the mark once § 5 has judged it; when § 5's re-assert
    /// converges, the mark clears and the target returns. The rule reads `F<n>Md`, not `F<n>Tg`, so
    /// a system that rewrites the target and leaves the mode is caught only by § 5's next
    /// examination: until then the record is stated (ADR 0014's #410 snapshot-target amendment,
    /// "What remains").
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
        of fan: FanState, leasedFans: Set<Int>, recorded: [Int: Double],
        observedMode: FirmwareFanMode?, thermalEmergencyActive: Bool
    ) -> Double? {
        guard leasedFans.contains(fan.index) else { return nil }
        guard let target = recorded[fan.index] else { return nil }
        guard observedMode == .manual else { return nil }
        guard !fan.isReclaimedBySystem else { return nil }
        guard !thermalEmergencyActive else { return nil }
        return target
    }
}
