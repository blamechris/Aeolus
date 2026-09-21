import FanKit
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

    let log: Logger

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Lease") {
        log = Logger(subsystem: subsystem, category: category)
    }

    /// § 4 closed the table for a sleep.
    func sealedForSleep() {
        log.notice(
            """
            No further manual control will be granted until this machine wakes: the system \
            is going to sleep and docs/SAFETY.md § 4 is handing every fan back.
            """
        )
    }

    /// A seal arrived after its own wake had already been answered, and was declined.
    ///
    /// `.fault`, and it is the only record that this happened. Reaching it means a
    /// `.willSleep` body was starved past the kernel's acknowledgement window, so the machine
    /// slept without this helper having handed a single fan back — the failure § 4 exists to
    /// prevent, arriving by a route § 4 cannot see. Declining keeps the seal from outliving
    /// the episode; it does not undo the missed handback.
    ///
    /// **The fault is here rather than on the wake**, which is where an earlier version put
    /// it. A wake that finds no seal standing is not by itself evidence of anything — a helper
    /// that restarted inside a sleep window hears exactly one, legitimately — and logging a
    /// `.fault` for it would have fired on every ordinary wake once the seal stopped being
    /// set. A declined seal *is* evidence: it can only happen when a sleep was stamped before
    /// a wake that was answered first.
    func declinedASealItsWakeAlreadyAnswered() {
        log.fault(
            """
            A sleep was sealed too late to matter: its wake had already been answered, so the \
            will-sleep handler had not run by the time the machine came back. Every fan \
            crossed that sleep however the last lease left it. Declining the seal so it \
            cannot refuse manual control on a machine that is already awake.
            """
        )
    }

    /// § 4 reopened the table after a wake. No fan was touched to do it.
    func unsealedAfterWake() {
        log.notice(
            """
            Manual control may be acquired again: the machine woke and the sleep window is \
            closed. Nothing was written to reopen it, and no previous lease came back.
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

    static func describe(_ fans: Set<Int>) -> String {
        fans.sorted().map(String.init).joined(separator: ", ")
    }

    static func describe(_ cause: FanRestoreCause) -> String {
        switch cause {
        case .thermalEmergency:
            return "the thermal emergency override fired — docs/SAFETY.md § 3"
        case .systemReclaimed:
            return "the system took the fans back — docs/SAFETY.md § 5"
        case .supervisorBlind:
            return "the helper could not read the fans it was holding — docs/SAFETY.md § 5"
        case .leaseExpired: return "the lease expired — TTL, monotonic clock"
        case .connectionInvalidated: return "the holding connection died"
        case .leaseReleased: return "the client released the lease"
        case .allLeasesDropped: return "every lease was dropped"
        case .startupReconciliation:
            return "startup reconciliation found the fan in manual — docs/SAFETY.md § 6"
        }
    }
}
