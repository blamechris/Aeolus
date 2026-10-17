import FanKit
import Foundation

/// Level 6's `apply`, as the privilege boundary holds it: one verb, no permit
/// ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s A6 PR-3 amendment).
///
/// `SupervisedFanAuthority` holds this and nothing wider of level 6. Its one requirement takes
/// what a decoded client message carries, the settings, the lease and the connection, so the
/// authority's file names no plane, no writer and no permit, as `AuthorityRoleTripwireTests`
/// holds. `LeaseApplier` is its one conformer under `Sources/`, and the composition builds exactly
/// one; the test target's `NoLevelSix` is another, for authorities built to test something else.
///
/// It refines `Sendable` and nothing else, and it is never extended, refined or converted: each
/// would widen what a decoded message can reach. Its verb is called only from
/// `SupervisedFanAuthority.swift`, after the shutdown refusal. `LeaseApplyingTripwireTests` holds
/// the declaration, the name's sites and the verb's callers by census; the authority file's
/// conversion ban is `AuthorityRoleTripwireTests.theAuthorityHoldsNoPlane`, and the refusal's
/// order is `SupervisedApplyBoundaryTests`'.
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
/// The last is the residual ruling D19 on [#197](https://github.com/blamechris/Aeolus/pull/197)
/// accepts for § 5's re-assert (`SignalTeardown`'s step 5, `docs/SAFETY.md` § 6), which level 6
/// inherits, at most once per teardown. In the daemon, on the force-key path, the after-check sits
/// behind the driver's poll sleep, which an exiting process does not outlive, so if the step's
/// writes land, `Ftst = 1` is in practice left set with exit 0; on the naive path the undo races
/// the exit. Nothing outside the process reconciles that, so D19's acceptance does not extend to a
/// plane that can write. The fix is [#410](https://github.com/blamechris/Aeolus/issues/410)'s
/// items 1 and 1a, a `.forExit` restore scope that seals the plane against every forward write and
/// an engagement ticket taken before the entitlement, which land on `main` with item 1b before
/// B1's first `.built` commit. `SignalTeardownInFlightApplyTests` pins the residual until then.
protocol LeaseApplying: Sendable {

    /// Writes `settings` under `lease`, or refuses having undone what it engaged: `LeaseApplier`'s
    /// order, items 0 to 5 of ADR 0014's A6 amendments.
    func apply(
        _ settings: [FanSetting], leaseID lease: UUID, from connection: ConnectionID
    ) async throws
}
