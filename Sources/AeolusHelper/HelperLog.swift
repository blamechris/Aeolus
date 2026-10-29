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

    /// A sink every line is also handed to, with its level, so a test can read both back.
    ///
    /// Shaped after `SafetyLog.init(recording:)`. Every interpolation in this type is
    /// `privacy: .public`, so rendering a line into one `String` and logging that `.public`
    /// discloses exactly what the per-field form did. That is what lets every line take the one
    /// route below. This was only the two fan lines until the review of #349.
    ///
    /// `nil` in every shipping build: `AeolusHelperMain` calls `init(subsystem:category:)`,
    /// which cannot set it.
    private let sink: (@Sendable (Level, String) -> Void)?

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "XPCBoundary") {
        log = Logger(subsystem: subsystem, category: category)
        sink = nil
    }

    /// A log whose lines a test can read back, level included.
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
        recording sink: @escaping @Sendable (Level, String) -> Void
    ) {
        log = Logger(subsystem: subsystem, category: category)
        self.sink = sink
    }

    /// The one route to the unified log: one level, written there and handed to the sink.
    /// `HelperLogTests.everyLineTakesTheOneRoute` holds this file to it.
    private func emit(_ level: Level, _ message: String) {
        log.log(level: Self.osLogType(for: level), "\(message, privacy: .public)")
        sink?(level, message)
    }

    private func info(_ message: String) { emit(.info, message) }
    private func notice(_ message: String) { emit(.notice, message) }
    private func error(_ message: String) { emit(.error, message) }
    private func fault(_ message: String) { emit(.fault, message) }

    // MARK: - Connections

    /// A connection was accepted and had the requirement applied to it.
    ///
    /// Note what this does *not* say: nothing about who connected. At this point nothing
    /// has been verified — see this type's documentation, fact 1.
    func acceptedConnection(_ connection: ConnectionID, teamIdentifier: String) {
        notice(
            """
            Connection \(connection.logDescription) accepted with the \
            client code-signing requirement applied (team \
            \(teamIdentifier)). Nothing about this peer is verified yet: \
            the requirement is enforced per message, not at accept time.
            """
        )
    }

    /// A connection was refused before it was ever configured, because this helper is
    /// refusing every connection.
    func refusedConnection(_ refusal: ClientAuthorisationRefusal) {
        error(
            """
            Refused an XPC connection: \(refusal.description)
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
            info(
                """
                Connection \(connection.logDescription) invalidated \
                (\(state)) with no message ever delivered. That is what a \
                code-signing requirement refusal looks like from this side, and it is also \
                what a client that disconnects before its first message looks like. The two \
                are indistinguishable by design; libxpc does not report who was refused.
                """
            )
            return
        }
        info(
            """
            Connection \(connection.logDescription) invalidated \
            (\(state)) after \
            \(messagesDelivered) message(s).
            """
        )
    }

    /// The transport was interrupted. Distinct from invalidation: the connection object
    /// survives and may carry further messages.
    func connectionInterrupted(_ connection: ConnectionID) {
        info(
            "Connection \(connection.logDescription) was interrupted."
        )
    }

    // MARK: - Messages

    /// A handshake succeeded. The description is the client's own account of itself,
    /// validated but not verified — see this type's documentation.
    func handshakeCompleted(_ connection: ConnectionID, client: NegotiatedClient) {
        notice(
            """
            Connection \(connection.logDescription) completed its \
            handshake at protocol version \(client.protocolVersion). The \
            client describes itself as "\(client.clientDescription)" — \
            self-described, not verified.
            """
        )
    }

    /// A message was refused. It logs the fault's `wireCode`, never its detail, which can
    /// quote text the firmware chose (`AeolusXPCFault.crossing(_:)`).
    func refusedMessage(_ connection: ConnectionID, message: String, fault: AeolusXPCFault) {
        info(
            """
            Connection \(connection.logDescription) was refused \
            \(message): \(fault.wireCode).
            """
        )
    }

    /// The panic path ran. It says what the helper did and no more: it used to add *"every fan
    /// was already under the system's control"*, which no build can know.
    func restoredAllToAutomatic(connection: ConnectionID, machineWide: MachineWideRestore) {
        let restore =
            switch machineWide {
            case .noWritePath:
                "no machine-wide restore was issued, because the plane reports no SMC write path"
            case .notIssued:
                "no machine-wide restore was issued; this authority issues none"
            case .accepted:
                "the firmware accepted the machine-wide restore, and accepted is not automatic"
            case .refused:
                "the machine-wide restore was refused (the fault line before this one)"
            }
        notice(
            """
            Connection \(connection.logDescription) asked for every fan \
            to be restored to automatic. Every lease was released, and \(restore).
            """
        )
    }

    /// § 7's machine-wide restore threw (`detail` is this module's own error). `fault`, as the
    /// only report of a force key left set, which has no snapshot field (ADR 0014 D5).
    func panicRestoreRefused(connection: ConnectionID, detail: String) {
        fault(
            """
            The machine-wide restore that connection \(connection.logDescription) asked for was \
            refused (\(detail)). Fans may still be off automatic control and the force key set; \
            every lease was released. Run fanctl reset --all again, or see docs/RECOVERY.md.
            """
        )
    }

    // MARK: - Sensors

    func discoveredSensors(count: Int, duration: Duration) {
        notice(
            """
            Discovered \(count) sensor keys in \
            \(duration.milliseconds) ms. This is the only full SMC \
            enumeration the helper performs; every snapshot after it is a subset read.
            """
        )
    }

    /// A discovery walk has outlived twice the longest contended walk, and has not returned.
    ///
    /// `.fault` because nothing else would say so. The line names what it cannot tell apart
    /// rather than guessing: the walk may be wedged inside an IOKit call — which, because
    /// `SMCConnection` is an actor, holds up **every** SMC read, the safety cycle's included
    /// (#293; the liveness watchdog, ADR 0012, ends the helper on a round trip that wedges, so
    /// by the time this fires it is the other reading that is likely) — or it may still be
    /// parked behind a connection rebuild that has itself not returned. It also cannot rule
    /// out a machine that slept mid-walk: the alarm's clock is continuous. What a client sees
    /// meanwhile is a snapshot that never answers.
    func discoveryWalkOverran(alarm: Duration) {
        fault(
            """
            The SMC sensor discovery walk has not returned after \
            \(alarm.milliseconds) ms (longest measured under contention: \
            \(SMCReadScheduler.longestContendedDiscoveryWalk.milliseconds) \
            ms). It is not cancelled. If an SMC call is wedged, every SMC read in the helper \
            is waiting behind it, including the safety supervisors', and snapshots will not \
            answer; if a connection rebuild is wedged, the walk is waiting behind that. See \
            issues #205 and #293.
            """
        )
    }

    func sensorDiscoveryFailed(reason: String) {
        error(
            """
            Sensor discovery failed (\(reason)). This snapshot carries no \
            sensors; the next one will try discovery again.
            """
        )
    }

    func sensorRefreshFailed(reason: String) {
        error(
            """
            Sensor refresh failed (\(reason)). This snapshot carries no \
            sensors.
            """
        )
    }

    // MARK: - Fans

    /// `F<n>Md` did not answer for one fan, so the snapshot could not say who owns it.
    ///
    /// The wire has no way to report "not known" at protocol version 1 — see
    /// `ReadOnlyFanReport.controlMode(_:)` — so the fan's mode reaches the client as a
    /// fallback, `automatic`. On a helper that can write, the availability beside it says
    /// `supervisorBlind` (#360); on one that cannot, every build that has shipped, this line is
    /// the only place the gap is visible. It is `error` rather than `info` for that reason: an
    /// operator diagnosing "why does Aeolus say this fan is automatic", or "why is it blind",
    /// needs to find this. Expected on every Intel Mac, which expresses fan mode as a bitmask
    /// rather than as this key.
    ///
    /// **Which is exactly why only the first occurrence per fan is an error.** `snapshot()`
    /// is on a 1 Hz path, so an unthrottled line here is about 86,400 error-level entries per
    /// fan per day, for the life of the process, on a condition that is normal for a whole
    /// architecture — the signal this line exists to preserve, drowned on the one
    /// architecture this project cannot test. The repeats say nothing the first did not, so
    /// they go to `.debug`, which is not persisted by default. The wording is identical
    /// either way: the level carries the distinction, not the prose. The caller owns the
    /// "have I said this about this fan before" state, because this type is a value and holds
    /// none — `ObservedFanModes.reportedUnreadable`, which forgets a fan once its read answers,
    /// so a later episode is an error again.
    func fanModeUnreadable(fanIndex: Int, reason: String, alreadyReported: Bool) {
        emit(
            alreadyReported ? .debug : .error,
            """
            Fan \(fanIndex)'s mode key could not be read (\(reason)). This snapshot reports \
            its mode as automatic, which is a fallback and not an observation: the wire has no \
            way to say "not known" at protocol version 1. A helper that can write reports its \
            manual control as supervisorBlind, unless Aeolus is holding or handing back the fan.
            """
        )
    }

    // MARK: - Lifecycle

    /// The service is advertised. What the line says about writing comes from the plane's own
    /// `writeCapability`, asked at the call site: it read *"No SMC write path exists in this
    /// build"* as a literal until the delta review of #349, which a build that can write would
    /// still have printed.
    func listening(machServiceName: String, build: String, writeCapability: FanWriteCapability) {
        let writes =
            switch writeCapability {
            case .notBuilt: "No SMC write path exists in this build."
            case .built: "This build has an SMC write path."
            }
        notice(
            """
            AeolusHelper \(build) listening on \
            \(machServiceName). \(writes)
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
        info(
            """
            Connection \(connection.logDescription) was refused \
            \(message): the helper is shutting down and is handing every \
            fan back to the system.
            """
        )
    }

    /// A second orderly signal arrived while the first was still being served.
    func teardownAlreadyRunning() {
        notice(
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
        fault(
            """
            The orderly teardown could not restore every fan to automatic control \
            (\(detail)). The helper will exit non-zero so that launchd \
            starts it again and reconciliation can clear anything left in manual.
            """
        )
    }

    /// The keystone was refused because this build has no write path at all.
    ///
    /// `notice` rather than `fault`, which is ruling D15's whole point: a build that cannot
    /// write cannot have put a fan into manual, so there is nothing here for an operator to
    /// act on. It is logged rather than passed over in silence because it is also the line
    /// that explains a zero exit on a helper that wrote nothing.
    func teardownFoundNothingToRestore() {
        notice(
            """
            The orderly teardown's machine-wide restore was refused: this build has no SMC \
            write path, so no fan can be off automatic control because of Aeolus. The helper \
            exits zero and launchd leaves it down.
            """
        )
    }

    /// The last line the process writes.
    func teardownFinished(outcome: TeardownOutcome) {
        notice(
            """
            Orderly teardown finished (\(String(describing: outcome))); \
            exiting \(outcome.exitCode). Every lease was released and a \
            machine-wide restore was attempted.
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
