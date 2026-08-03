import Foundation
import os

/// Everything the lease core says about itself.
///
/// A separate category from `HelperLog`'s `XPCBoundary`, and a separate type, because the
/// questions are different: the boundary log answers *"did the helper refuse this client?"*
/// and this one answers *"why are the fans not where the user left them?"* — which is the
/// question a user actually arrives with, and the one every mechanism in `docs/SAFETY.md`
/// is ultimately accountable to.
///
/// Every restore says **which mechanism** performed it. ADR 0005 requires the lease's two
/// teardown paths to be independent, and an operator cannot check that from a log that only
/// records that fans went back to automatic.
///
/// `holderDescription` is client-chosen text. It has been through
/// `AeolusXPCValidation.validateHolderDescription(_:)` — bounded in characters and bytes,
/// no control characters, no bidirectional overrides — so it cannot forge a log line. It is
/// still the client's own account of itself and the wording says so, exactly as
/// `HelperLog` does for the handshake.
struct LeaseLog: Sendable {

    private let log: Logger

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Lease") {
        log = Logger(subsystem: subsystem, category: category)
    }

    func granted(
        _ connection: ConnectionID, holder: String, fans: Set<Int>, timeToLive: TimeInterval
    ) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) took manual control of \
            fan(s) \(Self.describe(fans), privacy: .public) for \
            \(Int(timeToLive), privacy: .public)s. Holder describes itself as \
            "\(holder, privacy: .public)" — self-described, not verified. Expiry is enforced \
            on the monotonic clock; nothing renews this lease but the client.
            """
        )
    }

    func renewed(_ connection: ConnectionID, timeToLive: TimeInterval) {
        log.debug(
            """
            Connection \(connection.logDescription, privacy: .public) renewed its lease for \
            another \(Int(timeToLive), privacy: .public)s.
            """
        )
    }

    /// A restore happened, and this is which mechanism did it.
    func restored(fans: Set<Int>, because cause: FanRestoreCause) {
        log.notice(
            """
            Fan(s) \(Self.describe(fans), privacy: .public) returned to automatic control \
            (\(Self.describe(cause), privacy: .public)).
            """
        )
    }

    /// The in-flight half of #95's fix fired.
    ///
    /// Worth `notice` rather than `info`: it means a client was `SIGKILL`ed or disconnected
    /// during a lease acquisition, and it is the only evidence that the race is real on a
    /// user's machine rather than only in a test.
    func refusedInFlightBinding(_ connection: ConnectionID) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) was invalidated while \
            its acquireLease was in flight, so no lease was bound to it. Binding to a dead \
            connection would leave the TTL as the only path back to automatic control.
            """
        )
    }

    func refusedSelfRenewal(_ connection: ConnectionID) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) asked for a \
            self-renewing lease. Refused: this build has no startup reconciliation, which is \
            the whole of a self-renewing lease's safety story.
            """
        )
    }

    func refusedConcurrentLease(_ connection: ConnectionID) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) asked for manual \
            control while another connection holds it. Refused: one lease at a time.
            """
        )
    }

    /// A tombstone was dropped to keep the set bounded.
    ///
    /// Logged at `notice` because it is the moment #95's race reopens for one
    /// `ConnectionID`. It is safe only while self-renewal is refused — see
    /// `ConnectionTombstones`.
    func evictedTombstone(_ connection: ConnectionID, capacity: Int) {
        log.notice(
            """
            Evicted the oldest connection tombstone \
            (\(connection.logDescription, privacy: .public)) after \
            \(capacity, privacy: .public) dead connections. That connection can no longer be \
            refused a late lease binding; the TTL is what bounds the consequence, and it \
            does so only while self-renewing leases are refused.
            """
        )
    }

    /// The supervisor stopped. Only ever cancellation today, but a lease enforcer that went
    /// quiet without saying so would be the worst possible silent failure.
    func supervisorStopped(leasesOutstanding: Int) {
        log.notice(
            """
            The lease expiry supervisor stopped with \
            \(leasesOutstanding, privacy: .public) lease(s) outstanding. Connection death \
            remains an independent path back to automatic control; the TTL does not.
            """
        )
    }

    private static func describe(_ fans: Set<Int>) -> String {
        fans.sorted().map(String.init).joined(separator: ", ")
    }

    private static func describe(_ cause: FanRestoreCause) -> String {
        switch cause {
        case .leaseExpired: return "the lease expired — TTL, monotonic clock"
        case .connectionInvalidated: return "the holding connection died"
        case .leaseReleased: return "the client released the lease"
        case .allLeasesDropped: return "every lease was dropped"
        }
    }
}
