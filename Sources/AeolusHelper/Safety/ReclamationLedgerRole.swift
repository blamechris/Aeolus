/// What § 5 may do to the ledger, and nothing else: say why it gave a fan up, and take that back
/// ([#380](https://github.com/blamechris/Aeolus/issues/380)).
///
/// A role rather than the actor, for `HeldLeaseRole`'s two reasons. It narrows what
/// `ReclamationWatchdog` can do to the ledger to the three calls it makes, so § 5 holds no read
/// of what the snapshot reports. And it is a seam: a test can hold any of the three open on a
/// continuation, which is the only way to land a registration or a report between the ledger
/// answering and § 5 resuming, at `diverged`'s reclamation report or after
/// `cycleCouldNotSee`'s blind mark, without racing one in (#109) or blocking a cooperative-pool
/// thread (#344).
///
/// `ReclamationLedger` is the one conformer in `Sources/`, and `HelperComposition` hands § 5 the
/// instance the snapshot reads, so what § 5 records is what the user is told.
protocol ReclamationLedgerRole: Sendable {

    /// `ReclamationLedger.markReclaimed(fanAt:)`.
    func markReclaimed(fanAt index: Int) async -> Bool

    /// `ReclamationLedger.markSupervisorBlind(fanAt:)`. Discardable, as on the actor: § 5's one
    /// call does not read whether the entry changed.
    @discardableResult
    func markSupervisorBlind(fanAt index: Int) async -> Bool

    /// `ReclamationLedger.clearReclaimed(fanAt:)`.
    func clearReclaimed(fanAt index: Int) async -> Bool
}
