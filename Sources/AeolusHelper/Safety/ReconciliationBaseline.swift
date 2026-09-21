import FanKit

// What `docs/SAFETY.md` § 6's one-shot pass leaves behind, and the two seams that read it.
//
// Lifted out of `StartupReconciliation.swift` by
// [#204](https://github.com/blamechris/Aeolus/issues/204), which gave the durable refusals a
// second reader. Until then only `refusalForGrant(overFans:heldByAeolus:)` consulted them, so
// on a seam that can write the snapshot offered a fan as `.available` — or blamed another
// program — while the grant path refused it as `.supervisorBlind` or
// `.restoreToAutomaticFailed`. On today's `.notBuilt` seam both answer `.writePathNotBuilt`
// first, and the snapshot keeps doing so; see `ReadOnlyFanReport.reportingForeignControl`.

// MARK: - The baseline

/// The three durable refusals the pass can leave, as one value.
///
/// **One value, and one function over it, is the whole point.** The grant path and the
/// snapshot both have to answer "why can this fan not be leased" from these three facts, and
/// the ladder's rule is that they give the same reason for the same fan in the same instant
/// (`AvailabilityRestatement.swift`). Two copies of the precedence below would be two
/// places for that to drift, so neither caller has one: both ask `durableRefusal(overFans:)`.
///
/// Immutable once `reconcile()` returns. The pass is one-shot and runs before the listener
/// resumes, so no client can ever observe it mid-write — which is why the snapshot may read it
/// in a hop of its own rather than inside the lease core's view.
struct ReconciliationBaseline: Sendable, Hashable {

    /// The pass established nothing at all: the machine's fans would not enumerate, and no
    /// read after the keystone could enumerate them either.
    var establishedNothing: Bool

    /// Fans the pass found in manual, handed back by name through the restorer, and whose
    /// write the firmware refused until the restorer gave up.
    var refusedHandbacks: Set<Int>

    /// Fans whose mode this pass never established — never read — or that the keystone's
    /// read-back did not confirm automatic: in manual, unreadable, or past the budget.
    var unreconciled: Set<Int>

    /// A pass that ran to completion and left nothing to refuse.
    static let complete = ReconciliationBaseline(
        establishedNothing: false, refusedHandbacks: [], unreconciled: [])

    /// Why a lease over `candidates` cannot be granted on this baseline's account, or `nil`.
    ///
    /// Most durable and most specific first, so a client is never told the vaguer of two
    /// true things — see `StartupReconciliation.refusalForGrant(overFans:heldByAeolus:)` for
    /// each question in turn. `candidates` is already stripped of fans Aeolus holds: a fan
    /// Aeolus leases is judged by the lease core, never by this.
    func durableRefusal(overFans candidates: Set<Int>) -> ManualControlAvailability.Reason? {
        guard !candidates.isEmpty else { return nil }
        guard !establishedNothing else { return .supervisorBlind }
        guard candidates.isDisjoint(with: refusedHandbacks) else {
            return .restoreToAutomaticFailed
        }
        guard candidates.isDisjoint(with: unreconciled) else { return .supervisorBlind }
        return nil
    }
}

/// What the snapshot asks of § 6: the baseline, and nothing that reads the firmware.
///
/// Separate from `ForeignManualControlSensing` because the snapshot must not be handed a
/// method that issues fresh `.supervisor` reads per fan per snapshot — it already has the
/// mode, from its own read path, and step 5 of the ladder judges that.
protocol ReconciliationBaselineReporting: Sendable {

    /// The durable refusals the one-shot pass left. `.complete` before it has run.
    func baseline() async -> ReconciliationBaseline
}

// MARK: - The seam the lease core sees

/// What `LeaseAuthority` asks before it grants, and the whole of what it may ask.
///
/// Narrow on purpose. The lease core has no business driving reconciliation, and giving it
/// the whole of `StartupReconciliation` would put `reconcile(fans:)` one `await` from a
/// decoded client message — the same argument `FanAuthority` makes about not holding a
/// `FanControlPlane`. It asks a question and is told a reason.
protocol ForeignManualControlSensing: Sendable {

    /// Why manual control of `fans` cannot be granted, or `nil` when this mechanism has no
    /// objection. `heldByAeolus` is excluded from the judgement, never judged.
    func refusalForGrant(
        overFans fans: Set<Int>, heldByAeolus held: Set<Int>
    ) async -> ManualControlAvailability.Reason?
}

// MARK: - The bound

enum ReconciliationLimits {

    /// How long the whole pass may take before the helper serves clients anyway.
    ///
    /// **A budget, not a timeout.** It is checked between fans, so it bounds the number of
    /// reads the pass will start — not the duration of any one of them. A single read that
    /// never returns still hangs the bring-up, and that is deliberate rather than an
    /// oversight: `HelperComposition.bringUp()` records the same choice for itself, because
    /// a daemon that answers no connections is the fail-safe direction and a daemon serving
    /// over unreconciled fans is not. Making one read cancellable would mean abandoning a
    /// `.supervisor` turn mid-flight, which is the scheduler's invariant to keep, not this
    /// mechanism's to break.
    ///
    /// Five seconds against a machine whose 34-key curated supervisor read costs 5.6 ms and
    /// whose whole 2930-key snapshot costs 2.3 s (measured, `Mac16,5`): a two-fan
    /// reconciliation is three orders of magnitude inside it, and a machine that cannot do
    /// two mode reads in five seconds is one whose lease refusal is the correct outcome.
    static let budget: Duration = .seconds(5)
}
