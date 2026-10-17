import FanKit
import Foundation

/// Level 6's `apply`, as the privilege boundary holds it: one verb, no permit
/// ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s A6 PR-3 amendment).
///
/// `SupervisedFanAuthority` holds this and nothing wider of level 6. Its one requirement takes
/// what a decoded client message carries, the settings, the lease and the connection, so the
/// authority's file names no plane, no writer and no permit, as `AuthorityRoleTripwireTests`
/// holds. `LeaseApplier` is its one conformer, and the composition builds exactly one.
///
/// It refines `Sendable` and nothing else, and it is never extended, refined or converted: each
/// would widen what a decoded message can reach. Its verb is called only from
/// `SupervisedFanAuthority.swift`, after the shutdown refusal. `LeaseApplyingTripwireTests`
/// holds all three by census.
///
/// ## A teardown with an `apply` in flight
///
/// `SignalTeardown`'s control gate refuses an `apply` that arrives, through the authority's
/// shutdown refusal, and not one already in flight. Of what that one does next:
///
/// - every step whose entitlement is asked after the teardown has emptied the lease table refuses
///   on the lease: an engagement, § 5's registration, a command, and the reply's check;
/// - its undo's hand-back is a restore, redundant after the keystone, and takes no gate;
/// - a command whose entitlement was answered first can land on a fan the keystone restored;
/// - an engagement whose entitlement was answered first can have its first step admitted after the
///   final keystone, because the plane records the restore epoch at that step (ADR 0009 D1's
///   residual; `PlaneWriteLedger`). It writes `F<n>Md = 1`, and `Ftst = 1` on the force-key path,
///   and only the driver's after-check undoes it, after the teardown's process-end call.
///
/// The last is ruling D19's residual, which § 3's fire and § 5's re-assert already carry and
/// level 6 inherits, at most once per teardown. `SignalTeardownInFlightApplyTests` pins it with
/// the step parked past the recorded exit; in production the race is between `exit()` finishing
/// and the write. The design choice is [#410](https://github.com/blamechris/Aeolus/issues/410)'s.
protocol LeaseApplying: Sendable {

    /// Writes `settings` under `lease`, or refuses having undone what it engaged: `LeaseApplier`'s
    /// order, items 0 to 5 of ADR 0014's A6 amendments.
    func apply(
        _ settings: [FanSetting], leaseID lease: UUID, from connection: ConnectionID
    ) async throws
}
