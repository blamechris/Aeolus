import AeolusXPC
import Foundation
import os

/// Everything the privilege boundary says about itself, under one category, so that "did
/// the boundary refuse?" is answerable from `log show` on a user's machine.
///
/// ## It says the weaker true thing
///
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) claimed every accept and refuse
/// would be logged "with identifier, team, and reason". Two facts measured in #72 make
/// half of that unimplementable, and this type says less rather than saying it anyway:
///
/// 1. **`setCodeSigningRequirement` is enforced per message, not at accept time.**
///    `listener(_:shouldAcceptNewConnection:)` returns `true` for a peer that will never be
///    permitted to send anything. Accepting a connection is therefore not evidence that a
///    client was authorised, and no line here says it is. A log reading "authorised client
///    connected" would be `CLAUDE.md` rule 6 — never claim what you do not have — applied
///    to the boundary's own diagnostics.
/// 2. **A requirement-refused peer is never identified.** libxpc drops it and fires the
///    connection's `invalidationHandler`; the message never reaches the exported object,
///    and nothing about who it was is available. An invalidation with zero messages
///    delivered is *consistent with* a requirement refusal, not *proof* of one — a client
///    that connected and disconnected before its first message looks identical. So that
///    line names both possibilities and prefers neither.
///
/// The identity that *is* logged, at handshake, is explicitly the client's own account of
/// itself. It has been validated — bounded, no control characters, no bidirectional
/// overrides — but validated is not verified, and the wording says so.
///
/// ## Levels
///
/// A refused foreign binary is the mechanism working, so it is `info`, not `fault`. Fault
/// level is reserved for the helper being broken — the refuse-all rows, which
/// `ClientAuthorisation` already logs. A boundary that logged every refusal at fault level
/// would train whoever reads the log to ignore it.
struct HelperLog: Sendable {

    private let log: Logger

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "XPCBoundary") {
        log = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Connections

    /// A connection was accepted and had the requirement applied to it.
    ///
    /// Note what this does *not* say: nothing about who connected. At this point nothing
    /// has been verified — see this type's documentation, fact 1.
    func acceptedConnection(_ connection: ConnectionID, teamIdentifier: String) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) accepted with the \
            client code-signing requirement applied (team \
            \(teamIdentifier, privacy: .public)). Nothing about this peer is verified yet: \
            the requirement is enforced per message, not at accept time.
            """
        )
    }

    /// A connection was refused before it was ever configured, because this helper is
    /// refusing every connection.
    func refusedConnection(_ refusal: ClientAuthorisationRefusal) {
        log.error(
            """
            Refused an XPC connection: \(refusal.description, privacy: .public)
            """
        )
    }

    /// A connection ended.
    ///
    /// `messagesDelivered` is the count that reached the exported object. Zero is the
    /// interesting case and is called out explicitly, because it is exactly the case
    /// nothing can distinguish — see this type's documentation, fact 2.
    func connectionInvalidated(
        _ connection: ConnectionID,
        handshake: NegotiatedClient?,
        messagesDelivered: Int
    ) {
        let state =
            handshake.map { "handshaken as \($0.logDescription)" } ?? "never handshaken"
        guard messagesDelivered > 0 else {
            log.info(
                """
                Connection \(connection.logDescription, privacy: .public) invalidated \
                (\(state, privacy: .public)) with no message ever delivered. That is what a \
                code-signing requirement refusal looks like from this side, and it is also \
                what a client that disconnects before its first message looks like. The two \
                are indistinguishable by design; libxpc does not report who was refused.
                """
            )
            return
        }
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) invalidated \
            (\(state, privacy: .public)) after \
            \(messagesDelivered, privacy: .public) message(s).
            """
        )
    }

    /// The transport was interrupted. Distinct from invalidation: the connection object
    /// survives and may carry further messages.
    func connectionInterrupted(_ connection: ConnectionID) {
        log.info(
            "Connection \(connection.logDescription, privacy: .public) was interrupted."
        )
    }

    // MARK: - Messages

    /// A handshake succeeded. The description is the client's own account of itself,
    /// validated but not verified — see this type's documentation.
    func handshakeCompleted(_ connection: ConnectionID, client: NegotiatedClient) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) completed its \
            handshake at protocol version \(client.protocolVersion, privacy: .public). The \
            client describes itself as "\(client.clientDescription, privacy: .public)" — \
            self-described, not verified.
            """
        )
    }

    /// A message was refused. `detail` is never client-supplied text: every
    /// `AeolusXPCFault` detail describes the violation rather than quoting the value.
    func refusedMessage(_ connection: ConnectionID, message: String, fault: AeolusXPCFault) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) was refused \
            \(message, privacy: .public): \(fault.wireCode, privacy: .public).
            """
        )
    }

    /// The panic path ran.
    func restoredAllToAutomatic(connection: ConnectionID) {
        log.notice(
            """
            Connection \(connection.logDescription, privacy: .public) asked for every fan \
            to be restored to automatic. This build has no write path, so every fan was \
            already under the system's control and nothing had to change.
            """
        )
    }

    // MARK: - Sensors

    func discoveredSensors(count: Int, duration: Duration) {
        log.notice(
            """
            Discovered \(count, privacy: .public) sensor keys in \
            \(duration.milliseconds, privacy: .public) ms. This is the only full SMC \
            enumeration the helper performs; every snapshot after it is a subset read.
            """
        )
    }

    func sensorDiscoveryFailed(reason: String) {
        log.error(
            """
            Sensor discovery failed (\(reason, privacy: .public)). This snapshot carries no \
            sensors; the next one will try discovery again.
            """
        )
    }

    func sensorRefreshFailed(reason: String) {
        log.error(
            """
            Sensor refresh failed (\(reason, privacy: .public)). This snapshot carries no \
            sensors.
            """
        )
    }

    // MARK: - Fans

    /// `F<n>Md` did not answer for one fan, so the snapshot could not say who owns it.
    ///
    /// The wire has no way to report "not known" at protocol version 1 — see
    /// `ReadOnlyFanReport.controlMode(_:)` — so this line is the only place the gap is
    /// visible. It is `error` rather than `info` for that reason: what reaches the client is
    /// a fallback, and an operator diagnosing "why does Aeolus say this fan is automatic"
    /// needs to find this. Expected on every Intel Mac, which expresses fan mode as a
    /// bitmask rather than as this key.
    func fanModeUnreadable(fanIndex: Int, reason: String) {
        log.error(
            """
            Fan \(fanIndex, privacy: .public)'s mode key could not be read \
            (\(reason, privacy: .public)). This snapshot reports it as automatic, which is a \
            fallback and not an observation: the wire has no way to say "not known" at \
            protocol version 1.
            """
        )
    }

    // MARK: - Lifecycle

    func listening(machServiceName: String, build: String) {
        log.notice(
            """
            AeolusHelper \(build, privacy: .public) listening on \
            \(machServiceName, privacy: .public). No SMC write path exists in this build.
            """
        )
    }
}

extension Duration {
    /// Whole milliseconds, for a log line. Diagnostic only.
    fileprivate var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
