import Foundation

/// What § 5 may ask of the lease core about the lease a fan is held under, and nothing else:
/// whether that lease is live and covers the fan, and to revoke that lease
/// ([#353](https://github.com/blamechris/Aeolus/issues/353),
/// [#357](https://github.com/blamechris/Aeolus/issues/357)).
///
/// A role rather than the actor, for two reasons. It narrows what `ReclamationWatchdog` can do
/// to the lease core to the two calls it makes, so § 5 cannot grant, release or revoke every
/// lease. And it is the seam #344 asked for: a test can hold the answer to the liveness question
/// open on a continuation, which is the only way to land a release or a re-grant between the
/// lease core answering and § 5 resuming, without blocking a cooperative-pool thread.
/// `LeaseAuthority` is the one conformer in `Sources/`.
protocol HeldLeaseRole: Sendable {

    /// `LeaseAuthority.hasLiveLease(id:coveringFan:)`.
    func hasLiveLease(id: UUID, coveringFan fan: Int) async -> Bool

    /// `LeaseAuthority.revokeLease(id:because:)`.
    func revokeLease(id: UUID, because cause: FanRestoreCause) async -> LeaseRevocation
}

/// What `revokeLease(id:because:)` did with the lease it was asked to end (#361's panel).
enum LeaseRevocation: Sendable, Hashable {
    /// It was live: revoked whole, and its fans restored under the cause given.
    case revoked
    /// It had lapsed and not yet been swept: ended now, and its fans restored as
    /// `.leaseExpired`, so nobody is told the system took control the lease had already lost.
    case expired
    /// The table no longer held it: another path had already removed it. That path's restore,
    /// and its release notice, may still be in flight — a sweep or teardown landing after the
    /// terminal action's hand-back and before this call can clear the mark it keeps (#368).
    case gone
}
