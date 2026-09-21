import FanKit
import Foundation

/// The grant-time refusals: reasons a lease request never became a lease.
///
/// Split out of `LeaseLog.swift` by [#272](https://github.com/blamechris/Aeolus/issues/272);
/// see that file for the type's declaration and the two `describe` helpers this extension
/// calls.
extension LeaseLog {

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

    /// The build has no write path, so nothing can be granted. `.info`, like the other
    /// build-level refusal below it: it is the ordinary answer of a helper that ships the
    /// safety subsystem ahead of the write path E3/E4 gate on, not a machine in trouble.
    ///
    /// It says *build* rather than *machine* deliberately. A user reading `log show` after
    /// finding the fan slider inert needs to know that nothing about their Mac is wrong.
    func refusedNoWritePath(_ connection: ConnectionID) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) asked for manual \
            control. Refused: this build has no SMC write path at all, so there is nothing a \
            lease could grant. Nothing is wrong with this machine — see docs/SAFETY.md.
            """
        )
    }

    func refusedSelfRenewal(_ connection: ConnectionID) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) asked for a \
            self-renewing lease. Refused: restart plus startup reconciliation is the whole \
            of a self-renewing lease's safety story, and it is not hardware-verified yet \
            (ADR 0007).
            """
        )
    }

    /// A grant was refused because something outside Aeolus holds the fan, or because
    /// nothing has established what mode it is in.
    ///
    /// `.notice` rather than `.info`, for `refusedMidHandback`'s reason: `.info` is not
    /// persisted by default, and this is precisely the line a user reaches for after finding
    /// the slider inert with another fan-control app open. It names neither the holder nor a
    /// remedy Aeolus could apply, because `F<n>Md` carries neither.
    func refusedForeignManualControl(
        _ connection: ConnectionID, fans: Set<Int>,
        reason: ManualControlAvailability.Reason
    ) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for manual \
            control of fan(s) \(Self.describe(fans), privacy: .public). Refused: \
            \(reason.wireValue, privacy: .public). Either something outside Aeolus is \
            holding a named fan, or startup reconciliation never established its mode — \
            see docs/ADR/0011-reconciliation-and-foreign-manual-control.md. Aeolus does not \
            take a fan back from another writer.
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

    /// A client asked for a fan while `docs/SAFETY.md` § 4's sleep window was open.
    ///
    /// `.notice`, and it is the line that distinguishes the two ways a lease can go missing
    /// across a sleep: this one says the helper refused to grant it, which is the mechanism
    /// working. A client that sees this and never sees the unseal line below is looking at a
    /// helper that heard a sleep and never heard the wake.
    func refusedSystemSleeping(_ connection: ConnectionID) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for manual \
            control while the machine is going to sleep. Refused: every fan has already been \
            handed back for this sleep, and a lease granted now would engage manual control \
            on a machine that is about to stop running this helper. Ask again after the wake.
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
}
