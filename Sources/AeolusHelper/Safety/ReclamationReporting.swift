import Foundation

/// What the snapshot may ask § 5, and nothing else: the target § 5 recorded for each fan it holds
/// under one lease ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)'s #410
/// snapshot-target amendment).
///
/// A role rather than the actor, for `ReclamationRegistrationRole`'s reason: it narrows what
/// `SupervisedFanAuthority`, where a decoded client message lands, can do to § 5 to one read. It
/// declares no verb that changes anything, so the snapshot cannot register a fan, report or command
/// a target, hand one back, run a cycle or read § 5's diagnostics. `ReclamationWatchdog` is the one
/// conformer in `Sources/`, below, and the composition hands the authority the instance § 5's
/// supervisor cycles and level 6 reports to. `AuthorityRoleTripwireTests` holds what it declares
/// and where it is named.
///
/// ## It refines `Actor`, so the getter stays synchronous on the conformer
///
/// `ReclamationWatchdog.recordedTargets(under:)` is synchronous on the actor, and an actor's
/// isolated method witnesses a requirement only of a protocol that refines `Actor`. Declared
/// `async` here instead, it would be an `async` function whose name holds `Target` and that takes a
/// `UUID`, which `WriteAuthorisationTests.everyTargetWriteVerbTakesAnAuthorisation` refuses: the
/// name family is how that scan finds the write verbs. A caller outside the actor awaits it either
/// way.
///
/// ## Any hop order only under-claims, because the filter is on the lease id
///
/// The snapshot reads the machine, then the lease, then this, each in a hop of its own, so § 5 and
/// level 6 can move between them. Asked after the lease, and only when there is one, the getter
/// answers for the lease the snapshot reports and no other. A record dropped since is no target. A
/// fan handed back and engaged again under a newer lease is held under that lease's id, which this
/// is not asked about. So a target that crosses is one § 5 held under the reported lease, and
/// `ReadOnlyFanReport.heldTarget` states it only for a fan that lease covers and the machine read
/// showed in manual with no reclamation mark. A hop between the reads can take a target away; none
/// can put another lease's target, or one § 5 has dropped, beside the reported lease.
protocol ReclamationReporting: Actor {

    /// The target § 5 recorded for each fan it holds under `lease`, by fan index: the step level 6
    /// reported, or § 5's own re-assert last put on the wire. A fan held under another lease, or
    /// with nothing commanded yet, is absent.
    func recordedTargets(under lease: UUID) -> [Int: Double]
}

/// The one conformer. The getter is written in `ReclamationWatchdog.swift`, beside the registry it
/// reads, which is `private` to that file.
extension ReclamationWatchdog: ReclamationReporting {}
