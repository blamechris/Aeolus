import Foundation

/// What level 6 may tell § 5, and nothing else: that it engaged a fan under a lease, what it
/// commanded there, and that it handed the fan back
/// ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s A6 PR-2 amendment).
///
/// A role rather than the actor, for `HeldLeaseRole`'s first reason: it narrows what
/// `LeaseApplier` can do to § 5 to the three calls it makes, so level 6 cannot run a cycle, send
/// a release notice in the lease core's place or read § 5's diagnostics. `ReclamationWatchdog` is
/// the one conformer in `Sources/`, and A6's next step hands level 6 the instance § 5's
/// supervisor cycles. `LeaseApplierTripwireTests` holds where the role is named.
///
/// ## It refines `Actor`, so the report stays synchronous on the conformer
///
/// `ReclamationWatchdog.commandedTarget(_:under:)` is synchronous on the actor, and an actor's
/// isolated method witnesses a requirement only of a protocol that refines `Actor`. Declared
/// `async` here instead, it would be an `async` function whose name holds `Target` and that takes
/// a `UUID`, and `WriteAuthorisationTests.everyTargetWriteVerbTakesAnAuthorisation` refuses that
/// shape, rightly: the name family is how that scan finds the write verbs. A caller outside the
/// actor awaits every call either way.
protocol ReclamationRegistrationRole: Actor {

    /// `ReclamationWatchdog.manualControlEngaged(_:under:)`.
    func manualControlEngaged(_ fan: CommandableFan, under lease: UUID) async throws

    /// `ReclamationWatchdog.commandedTarget(_:under:)`, with what became of the report: level 6
    /// answers applied only for a report § 5 recorded.
    func commandedTarget(_ commanded: CommandedTarget, under lease: UUID) -> ReportReceipt

    /// `ReclamationWatchdog.manualControlHandedBack(fanAt:under:)`.
    func manualControlHandedBack(fanAt index: Int, under lease: UUID) async
}

/// What § 5 did with a target level 6 reported (ADR 0014's A6 PR-2 amendment).
enum ReportReceipt: Sendable, Hashable {
    /// The record holds it: the next examination judges the fan against it.
    case recorded
    /// No record of the fan under that lease: it was released, given up or never registered, so
    /// nothing judges the fan against the target.
    case notHeld
    /// The record refused it: not a number, or below the floor every permit is clamped to, which
    /// no plane can write (#395).
    case refused
}
