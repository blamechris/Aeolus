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

    /// The restore did not take, the attempts are spent, and the helper has stopped asking.
    ///
    /// `.fault`, and it is the line `restored(fans:because:)` above must be read against:
    /// that one is written before the write is attempted, so for this fan it says something
    /// that turned out not to be true. Correcting the record is exactly what this level is
    /// for — a user asking why a fan can no longer be controlled has this line as the
    /// answer, and nothing else in the log says it.
    func abandonedHandback(
        fanAt index: Int, because cause: FanRestoreCause, after attempts: Int, error: any Error
    ) {
        log.fault(
            """
            Fan \(index, privacy: .public) could not be returned to automatic control \
            (\(Self.describe(cause), privacy: .public)) after \(attempts, privacy: .public) \
            attempts: \(String(describing: error), privacy: .public). Aeolus has stopped \
            trying and will refuse manual control of this fan. The system's own thermal \
            management is what the firmware left it under.
            """
        )
    }

    /// A client asked for a fan whose handback was given up on.
    ///
    /// `.notice` rather than `.fault`: the fault was logged once, where it happened. This is
    /// a client meeting the consequence, and it is worth persisting because a client that
    /// sees it repeatedly is the evidence that the durable refusal is durable — which is the
    /// half of [#110](https://github.com/blamechris/Aeolus/issues/110) a client can see.
    func refusedAbandonedHandback(_ connection: ConnectionID, fans: Set<Int>) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for fan(s) \
            \(Self.describe(fans), privacy: .public) that Aeolus could not return to \
            automatic control. Refused: their mode is not what the helper last asked for, \
            and a lease over one would be claiming control nothing has confirmed.
            """
        )
    }

    /// A lease was taken from a client that had done nothing wrong.
    ///
    /// `.fault` — the level this type reserves for "a safety mechanism decided the machine
    /// matters more than the client's claim". `refusedBlindTelemetry` is the other one, and
    /// an earlier version of this comment called this the only one, which was false. Every
    /// *other* line here is a client running out of claim; this is the line a user arrives
    /// with when they ask why their fan settings vanished.
    func revoked(_ connection: ConnectionID, fans: Set<Int>, because cause: FanRestoreCause) {
        log.fault(
            """
            Connection \(connection.logDescription, privacy: .public) had its lease over \
            fan(s) \(Self.describe(fans), privacy: .public) revoked whole \
            (\(Self.describe(cause), privacy: .public)). It was not trimmed to a subset: a \
            client holding part of a lease it can no longer command would be told it has \
            control it does not have.
            """
        )
    }

    /// A grant was refused because § 3 is holding.
    ///
    /// Separate from `refusedBlindTelemetry` although both mean "not now": one says the
    /// mechanism cannot see, the other says it has seen something and acted. Collapsing
    /// them would make it impossible to tell, afterwards, whether a machine that refused
    /// every lease for a minute was too hot or merely blind.
    func refusedThermalEmergency(_ connection: ConnectionID) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) was refused manual \
            control: the thermal emergency override is latched. A revoked holder is not \
            silently re-granted — it asks again, and is refused until a fresh reading falls \
            a hysteresis margin below the ceiling.
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

    /// `.fault`, not `.info`. Every other refusal here is a normal negotiation outcome —
    /// somebody else has the fans, a handback is in flight, the build has no self-renewal.
    /// This one says the helper cannot see a temperature, which is a machine in a degraded
    /// state rather than a client asking for the wrong thing, and it needs to be in the
    /// log a user reaches for after the fact.
    func refusedBlindTelemetry(_ connection: ConnectionID, detail: String) {
        log.fault(
            """
            Connection \(connection.logDescription, privacy: .public) asked for manual \
            control while no critical temperature could be read (\(detail, privacy: .public)). \
            Refused: the thermal override is a precondition of a lease, not a peer of it, \
            and a lease granted now would pin fans with nothing watching them.
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

    /// A refusal that resolves itself in milliseconds, so it is worth being able to tell
    /// apart from the ones that do not. A client seeing this repeatedly is watching a
    /// restore that never completes, which is a different and much worse fault.
    func refusedMidHandback(_ connection: ConnectionID, fans: Set<Int>) {
        // `.notice` rather than `.info`, for the reason the doc comment above gives: `.info`
        // is not persisted by default, so the repeated-refusal evidence would not be there
        // when someone went looking for it. Same argument that promoted `refusedInFlightBinding`.
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for fans \
            \(fans.sorted().map(String.init).joined(separator: ", "), privacy: .public) \
            while their restore to automatic is still in flight. Refused: a lease granted \
            now would be overwritten by that restore.
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
        }
    }
}
