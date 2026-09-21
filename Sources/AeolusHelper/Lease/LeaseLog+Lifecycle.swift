import FanKit
import Foundation

/// The lease lifecycle: `granted`, `renewed`, `restored`, `revoked`.
///
/// Split out of `LeaseLog.swift` by [#272](https://github.com/blamechris/Aeolus/issues/272);
/// see that file for the type's declaration and the two `describe` helpers this extension
/// calls.
extension LeaseLog {

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
}
