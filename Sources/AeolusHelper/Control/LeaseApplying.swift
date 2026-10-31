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
/// - a command whose entitlement was answered first lands if its turn comes before the final
///   keystone, which then restores the fan, and is refused in its own turn by the exit's `.forExit`
///   seal if it comes after, before it writes a target;
/// - an engagement whose entitlement was answered first took its ticket before that, so its first
///   step, admitted after the teardown's restores were requested, is refused at its admission
///   before it writes, and the seal as well, if it is admitted after the final keystone's request.
///
/// The last was the residual ruling D19 on [#197](https://github.com/blamechris/Aeolus/pull/197)
/// accepted, which level 6 inherited (ADR 0014's A6 PR-3 amendment): a first step admitted after
/// the final keystone wrote `F<n>Md = 1`, and `Ftst = 1` on the force-key path, with its undo left
/// to a process that was ending; the command before it wrote a target to a restored fan. Both are
/// closed by the #410 ticket-and-seal amendment — the engagement's ticket and the exit's seal — and
/// `SignalTeardownInFlightApplyTests` holds that an engagement, a command and a re-assert in flight
/// at the exit write nothing after the keystone, over the scripted plane, and
/// `ProductionExitTests` over the production one. All of this is a plane that can write: on a
/// plane that cannot, nothing writes, because a `.notBuilt` plane grants no lease.
protocol LeaseApplying: Sendable {

    /// Writes `settings` under `lease`, or refuses having undone what it engaged: `LeaseApplier`'s
    /// order, items 0 to 5 of ADR 0014's A6 amendments.
    func apply(
        _ settings: [FanSetting], leaseID lease: UUID, from connection: ConnectionID
    ) async throws
}
