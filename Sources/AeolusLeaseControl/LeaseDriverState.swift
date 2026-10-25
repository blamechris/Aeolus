import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// Where the app's lease stands. See `LeaseDriver` for the transitions.
///
/// ## Only `held` says the app holds the fans
///
/// Every other case says it does not, or cannot show that it does. `lost` is never drawn as
/// `held`, and nothing moves from `lost` back to `held` except a new user action,
/// `LeaseDriver.take(_:)`, which goes through `acquiring` like any other (`CLAUDE.md` rules 2 and
/// 6). `LeaseDriver.adjust(_:)` never leaves `lost`.
///
/// ## Text from another client is carried verbatim
///
/// A `Lease.holderDescription` is text the client that holds that lease chose, stored by the
/// helper. One can arrive inside `lost` (`ControlLoss.leaseNotListed(listed:)` names whatever
/// lease the snapshot lists instead), and an `AeolusXPCFault` inside `refused` or `HelperFailure`
/// can carry the helper's free-text `detail`. The driver formats none of it. **The renderer must
/// sanitise every such string before it shows it**, as `fanctl` does with
/// `DisplayText.sanitised(_:)`: what is safe to show depends on where it is shown, so it is
/// decided there.
public enum LeaseDriverState: Sendable, Hashable {

    /// No lease has been asked for.
    case idle

    /// A lease over `fans` has been asked for and the helper has not answered.
    case acquiring(fans: [Int])

    /// The helper granted the lease, it has not been shown to have ended, and the heartbeat is
    /// renewing it.
    case held(HeldLease)

    /// The app asked for the fans back and the helper has not answered.
    case releasing

    /// The driver holds nothing and has nothing in flight, after a release. What the fans are doing
    /// is the next snapshot's to report: this says nothing about them, and nothing about whether
    /// the helper answered (`LeaseDriver`, "Release"; ADR 0015).
    case released

    /// Control ended without the app asking for it to, could not be shown to have begun, or was
    /// given back without the helper confirming it. Final: the driver neither renews nor acquires
    /// again on its own.
    case lost(LeaseLoss)

    /// The helper refused the lease, in its own words: `.leaseHeldByAnotherClient`,
    /// `.thermalEmergencyActive` and `.noThermalTelemetry` among them. A state, not an error.
    case refused(AeolusXPCFault)

    /// Whether this state says the app holds the fans. `true` only for `held`.
    public var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}

/// A lease the helper granted and the driver still holds.
public struct HeldLease: Sendable, Hashable {

    /// The lease as the helper last returned it, unchanged: the grant, then each renewal's
    /// answer, so `expiresAt` is the helper's latest word. It is display-grade all the same;
    /// nothing enforces it.
    public let lease: Lease

    /// The fans the grant covers.
    ///
    /// `Lease` carries no fan list, so this cannot be read from the lease the helper returned.
    /// It is the list the granted request named, bound to this grant when the grant arrived and
    /// never replaced by a later request: the helper grants exactly the fans it was asked for or
    /// refuses (`LeaseAuthority` stores the request's indices, and `AeolusXPCValidation` refuses
    /// rather than repairs). It is what the driver passes
    /// `SystemSnapshot.controlLoss(leaseID:covering:)`, and it is never empty.
    public let fans: [Int]

    /// What has been sent under the lease.
    public let phase: Phase

    public enum Phase: Sendable, Hashable {

        /// An `apply` of this target is in flight. `queued` is the latest target asked for while
        /// it is, which is sent when it answers; a newer request replaces it.
        case applying(LeaseTarget, queued: LeaseTarget?)

        /// The helper answered the `apply` of this target with success: it accepted and applied
        /// it. That is all it says. What the fans are doing is the snapshot's to report, and an
        /// intended speed is never drawn as an actual one.
        case confirmed(LeaseTarget)
    }

    /// The same lease, in `phase`.
    func with(_ phase: Phase) -> HeldLease {
        HeldLease(lease: lease, fans: fans, phase: phase)
    }

    /// The same grant and phase, with the lease as the helper last renewed it.
    func with(lease renewed: Lease) -> HeldLease {
        HeldLease(lease: renewed, fans: fans, phase: phase)
    }
}

/// Why control ended, as the driver saw it.
public struct LeaseLoss: Sendable, Hashable {

    /// The lease that ended, as the helper granted it, or `nil` when no grant was ever seen.
    public let lease: Lease?

    public let cause: Cause

    /// Whether the driver was told the Mac woke after the last renewal the helper accepted, and
    /// before this loss was found. It is an order of events the driver saw, not a cause the helper
    /// reported: the helper releases every lease before a sleep (`docs/SAFETY.md` § 4), so a
    /// renderer may say control ended across the sleep, and the driver does not ask for the fans
    /// again on wake (#153's default, the maintainer's to change).
    public let afterWake: Bool

    public enum Cause: Sendable, Hashable {

        /// `acquireLease` failed without the helper saying no. Whether it granted a lease cannot be
        /// known here; the driver tore the connection down, which ends any lease on it. For
        /// `HelperClientError.clientCannotVerifyHelper` it is known that nothing was sent at all.
        case acquireUnanswered(HelperFailure)

        /// A renewal was refused or went unanswered. Never retried.
        case renewal(HelperFailure)

        /// An `apply` was refused or went unanswered. A refused `apply` may already have
        /// commanded a fan, so nothing is said about the fans except what a snapshot shows.
        case apply(HelperFailure)

        /// A snapshot shows the lease no longer proves control: one asked for after the grant
        /// answered, for the lease itself, or after the first `apply` was accepted, for its fans.
        /// `isThermalEmergencyActive` is that snapshot's flag, kept beside the loss because § 3
        /// revokes every lease when it fires: a snapshot taken during an emergency usually lists
        /// **no** lease and answers `.leaseNotListed(listed: nil)`, not `.thermalEmergency`, so
        /// for a loss a snapshot found, the flag is the only place the emergency is named.
        ///
        /// A loss a renewal found first reads `.renewal(.refused(.leaseUnknown))` and names none,
        /// even when § 3 revoked the lease; the renderer names the emergency only from a live
        /// snapshot whose flag is set.
        ///
        /// **When the flag is clear, nothing here says why the lease went.** § 3's latch releases,
        /// and the flag clears, once a reading falls a hysteresis margin below the ceiling, so a
        /// snapshot read after that shows the lease gone and no flag (#476 NB3). Name the
        /// emergency when the flag is set; otherwise say only that control ended.
        case snapshot(ControlLoss, isThermalEmergencyActive: Bool)

        /// The control connection left `.handshaken`. The lease is bound to that connection, and
        /// the helper ends a connection's leases when it goes or is replaced.
        case connection(HelperConnectionHealth)

        /// The heartbeat's wait failed with nothing asking it to stop, so the lease could no
        /// longer be renewed on schedule.
        case heartbeatFailed

        /// The app released the lease, and the helper refused the release or did not answer it.
        /// Nothing then says the helper let the fans go: it can still hold them until its
        /// connection-invalidation backstop or the lease's TTL ends the lease. A status line, true
        /// where it is emitted; no claim depends on it (ADR 0015 D3).
        case releaseUnconfirmed(HelperFailure)
    }
}

/// What a verb's failure was: the helper saying no, or the client not getting an answer it could
/// read.
///
/// The distinction `HelperClientError` exists to keep. A refusal is the helper's decision, in its
/// own vocabulary. A client failure says nothing about what the helper decided, and is never read
/// as "no problem".
public enum HelperFailure: Sendable, Hashable {

    /// The helper answered, and the answer was this refusal.
    case refused(AeolusXPCFault)

    /// No answer this client could read: the connection, the deadline, or the reply failed.
    case failed(HelperClientError)

    /// Anything else, by its description.
    case other(String)

    /// Whether the helper answered, and said no.
    var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    init(_ error: any Error) {
        if let fault = error as? AeolusXPCFault {
            self = .refused(fault)
        } else if let failure = error as? HelperClientError {
            self = .failed(failure)
        } else {
            self = .other(String(describing: error))
        }
    }
}

/// What a release came to, for the caller that waited on it.
public enum ReleaseOutcome: Sendable, Hashable {

    /// Nothing was held, and nothing was sent.
    case nothingHeld

    /// The helper answered the release with success.
    case released

    /// The release was refused or went unanswered. The lease is not held by the driver either way.
    case failed(HelperFailure)

    /// The bound passed before the release answered. It may still be in flight, or, if asked for
    /// while acquiring, not sent yet; on quit the teardown that follows ends any lease on the
    /// connection.
    case notAnswered(within: Duration)
}
