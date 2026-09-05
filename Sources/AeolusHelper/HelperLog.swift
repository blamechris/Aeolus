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

    /// The two levels the fan lines below choose between. Only those lines, deliberately —
    /// see `fanLineSink`.
    enum FanLineLevel: Sendable, Hashable {
        /// Persisted, and the level an operator goes looking at.
        case error
        /// Not persisted by default. What a repeat of an already-reported condition costs.
        case debug
    }

    private let log: Logger

    /// A sink the **fan** lines are also handed to, with their level, so a test can assert
    /// which level one was emitted at.
    ///
    /// Shaped after `SafetyLog.init(recording:)`, and narrow on purpose. Most lines in this
    /// type interpolate a client-supplied string under a deliberate `privacy:` annotation,
    /// and funnelling those through one already-rendered `String` would move the redaction
    /// decision out of `os_log` — a change to what a shipping helper discloses, made for a
    /// test's benefit. The fan lines interpolate an `Int` and an error description this
    /// module produced, so mirroring them redacts nothing differently.
    ///
    /// `nil` in every shipping build: `AeolusHelperMain` calls `init(subsystem:category:)`,
    /// which cannot set it.
    private let fanLineSink: (@Sendable (FanLineLevel, String) -> Void)?

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "XPCBoundary") {
        log = Logger(subsystem: subsystem, category: category)
        fanLineSink = nil
    }

    /// A log whose fan lines a test can read back, level included.
    ///
    /// The level is the whole assertion: `fanModeUnreadable` reports a condition that is
    /// *normal* on an entire architecture family, so whether the tenth occurrence is an
    /// error or a debug line is the difference between a diagnostic and a denial of service
    /// against whoever reads the log. Before this seam that choice was a claim no test could
    /// observe — `Logger` writes to the unified log, `.debug` is not persisted by default,
    /// and reading it back with `OSLogStore` would make the assertion depend on the
    /// machine's logging configuration rather than on the code.
    init(
        subsystem: String = "dev.aeolus.AeolusHelper",
        category: String = "XPCBoundary",
        recordingFanLines sink: @escaping @Sendable (FanLineLevel, String) -> Void
    ) {
        log = Logger(subsystem: subsystem, category: category)
        fanLineSink = sink
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
    ///
    /// **Which is exactly why only the first occurrence per fan is an error.** `snapshot()`
    /// is on a 1 Hz path, so an unthrottled line here is about 86,400 error-level entries per
    /// fan per day, for the life of the process, on a condition that is normal for a whole
    /// architecture — the signal this line exists to preserve, drowned on the one
    /// architecture this project cannot test. The repeats say nothing the first did not, so
    /// they go to `.debug`, which is not persisted by default. The wording is identical
    /// either way: the level carries the distinction, not the prose. The caller owns the
    /// "have I said this about this fan before" state, because this type is a value and holds
    /// none — `ObservedFanModes.reportedUnreadable`.
    func fanModeUnreadable(fanIndex: Int, reason: String, alreadyReported: Bool) {
        // Rendered once and logged `.public` whole, rather than interpolated per field: both
        // fields are the helper's own — an index it enumerated and an error it produced —
        // so there is nothing here for `os_log` to redact, and the mirror below must see the
        // same text the unified log gets.
        let message = """
            Fan \(fanIndex)'s mode key could not be read (\(reason)). This snapshot reports \
            it as automatic, which is a fallback and not an observation: the wire has no way \
            to say "not known" at protocol version 1.
            """
        if alreadyReported {
            log.debug("\(message, privacy: .public)")
            fanLineSink?(.debug, message)
        } else {
            log.error("\(message, privacy: .public)")
            fanLineSink?(.error, message)
        }
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

    // MARK: - Orderly teardown

    /// A control verb arrived after `SignalTeardown` closed the gate.
    ///
    /// `info`, not `error`: the client did nothing wrong and the refusal is the mechanism
    /// working. It is logged at all because an operator watching a client fail during a
    /// shutdown is entitled to know that the helper refused it *on purpose*, which is the
    /// one thing the generic `helperFailed` code on the wire cannot say.
    func refusedDuringTeardown(_ connection: ConnectionID, message: String) {
        log.info(
            """
            Connection \(connection.logDescription, privacy: .public) was refused \
            \(message, privacy: .public): the helper is shutting down and is handing every \
            fan back to the system.
            """
        )
    }

    /// A second orderly signal arrived while the first was still being served.
    func teardownAlreadyRunning() {
        log.notice(
            """
            A second orderly signal arrived while the teardown was still running. It is \
            ignored: the teardown in flight restores every fan and ends the process.
            """
        )
    }

    /// The machine-wide restore threw. `detail` is this module's own error description.
    ///
    /// `fault` level, because this is the line that says fans may still be off automatic
    /// control — the failure `docs/SAFETY.md` opens with.
    func teardownRestoreFailed(detail: String) {
        log.fault(
            """
            The orderly teardown could not restore every fan to automatic control \
            (\(detail, privacy: .public)). The helper will exit non-zero so that launchd \
            starts it again and reconciliation can clear anything left in manual.
            """
        )
    }

    /// The last line the process writes.
    func teardownFinished(outcome: TeardownOutcome) {
        log.notice(
            """
            Orderly teardown finished; exiting \(outcome.rawValue, privacy: .public). Every \
            lease was released and a machine-wide restore was attempted.
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
