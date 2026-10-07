import AeolusXPC
import FanKit
import Foundation

// What `fanctl auto` prints: the result on standard output, the diagnosis on standard error.
//
// Every sentence that could be read as "the fans are automatic" is in `verdictLine(for:)`,
// behind the one verdict that earns it, and `AutoCommandTests.noFailureClaimsSuccess` holds
// every other outcome to never saying it. The wording is the helper's report, attributed to
// the helper.
extension AutoCommand {

    // MARK: - Text

    /// What the run did and what the helper's last snapshot says. Standard output.
    static func text(for observation: Observation) -> String {
        let snapshot = observation.snapshot
        var lines: [String] = []
        if let failure = observation.firstSnapshotFailure {
            lines.append(
                "The helper's first snapshot failed (\(failure)). It had completed its "
                    + "handshake, so this run sent the request anyway and read the snapshot "
                    + "again.")
        }
        if let ended = observation.endedLease {
            lines.append(
                "The manual-control lease held by \"\(holder(ended))\" (id "
                    + "\(ended.id.uuidString)) was listed before the restore request and is no "
                    + "longer listed. The request may have dropped it, or it may have expired; "
                    + "either way that client will find its lease gone.")
        }
        if observation.restoreRequested {
            lines.append(restoreSentence(observation))
        }
        lines.append(verdictLine(for: observation))
        if snapshot.isThermalEmergencyActive {
            lines.append(StatusCommand.thermalEmergencyLine(active: true))
        }
        if snapshot.activeLease != nil {
            lines.append("")
            lines.append(contentsOf: StatusCommand.leaseLines(snapshot.activeLease))
        }
        for fan in snapshot.fans {
            lines.append("")
            lines.append(contentsOf: StatusCommand.fanLines(fan))
        }
        return lines.joined(separator: "\n")
    }

    private static func restoreSentence(_ observation: Observation) -> String {
        let asked = "Asked the helper once to return every fan to automatic control; "
        guard let failure = observation.restoreFailure else {
            return asked + "it accepted the request."
        }
        return asked + "it did not confirm the request: \(failure)"
    }

    /// The only sentence that may say the safe state was reached, and only for the verdict that
    /// says so — in the helper's voice, with the time the helper captured it.
    ///
    /// **Mutation target:** returning the first arm for every verdict is what
    /// `AutoCommandTests.noFailureClaimsSuccess` exists to catch.
    static func verdictLine(for observation: Observation) -> String {
        let snapshot = observation.snapshot
        let captured = StatusCommand.iso8601(snapshot.capturedAt)
        switch observation.verdict {
        case .automatic:
            let state =
                snapshot.fans.isEmpty
                ? "no fans and no manual-control lease"
                : "every fan automatic and no manual-control lease"
            guard observation.restoreRequested else {
                return "The helper reports \(state), in a snapshot it captured at \(captured). "
                    + "No restore request was sent."
            }
            return "The helper now reports \(state), in a snapshot it captured at \(captured)."
        case .cannotReturn, .notConfirmed:
            return "The helper's latest snapshot, captured at \(captured), is below."
        }
    }

    private static func holder(_ lease: Lease) -> String {
        DisplayText.sanitised(lease.holderDescription)
    }

    // MARK: - Text: why not

    private static var windowSeconds: Int64 { SafeState.window.components.seconds }

    private static let sentOnce =
        "This run sent the request once and will not send it again."

    /// What mode a fan reads, in words that do not claim more than the helper said.
    private static func reads(_ fan: FanState) -> String {
        fan.mode == .automatic ? "reads automatic" : "reads manual"
    }

    /// Fans the helper has not cleared, one line each, in the helper's own words: a mode that
    /// reads manual, or an availability that says the helper has not established the fan's mode
    /// — which is the one thing a mode of `automatic` cannot rule out.
    private static func unclearedFanLines(
        _ snapshot: SystemSnapshot, excluding excluded: [Int] = [], also: Bool = false
    ) -> [String] {
        let lead = also ? "is also not cleared" : "is not cleared"
        return snapshot.fans.filter { !SafeState.isCleared($0) && !excluded.contains($0.index) }
            .map {
                "  Fan \($0.index) (\(reads($0))) \(lead); manual control: "
                    + StatusCommand.availability($0.manualControlAvailability)
            }
    }

    /// Why the run could not read any snapshot after sending the request.
    ///
    /// Exit 8, with the way out that needs no snapshot: `fanctl reset --all` sends the same
    /// request, and the helper's lease sweep behind it does not read the fans first.
    static func snapshotUnavailableMessage(
        firstFailure: String, laterFailure: String?, restoreFailure: String?
    ) -> String {
        let asked =
            restoreFailure.map { "it did not confirm the request: \($0)" }
            ?? "it accepted the request."
        return """
            The helper completed its handshake but could not give a snapshot, so this run cannot \
            say what the fans are doing.

              First snapshot: \(firstFailure)
              Snapshot after the request: \(laterFailure ?? "no reason given")

            This run asked the helper once to return every fan to automatic control; \(asked)

            \(sentOnce) \(resetPointer)

            \(ResetCommand.stopTheHelper)
            """
    }

    /// Where to go when this run could not read the helper's snapshot.
    static let resetPointer =
        "Run `fanctl reset --all` if the fans are wrong: it sends the request that returns every "
        + "fan to automatic control without a snapshot, and reports what the helper accepted."

    /// Exit 1 when the first snapshot failed and no handshake was in force afterwards.
    ///
    /// **The first sentence says nothing was sent.** The cause that follows is the client's own
    /// text for the *snapshot* — "the helper accepted this request and did not answer" — and read
    /// first it sounds like the return-to-automatic request `auto` exists to send, which a user
    /// would then wait on instead of running `fanctl reset --all`.
    static func nothingSentMessage(cause: String) -> String {
        """
        No restore request was sent. This run could not read a snapshot, and no handshake was in \
        force afterwards, so there was no identified helper to send one to: a snapshot that is \
        never answered, or a helper that restarts under it, drops the connection.

        \(cause)

        \(resetPointer)
        """
    }

    /// The first sentence of an exit 8 that ran the whole window.
    ///
    /// A fan that **reads automatic but carries a pending reason** is not a fan the helper failed
    /// to report as automatic — it reports it so — so that case says the helper has not cleared
    /// it, and names the reason. The generic sentence is for fans that read manual, or a lease.
    private static func timedOutSentence(_ snapshot: SystemSnapshot) -> String {
        let withheld = snapshot.fans.filter { $0.mode == .automatic && !SafeState.isCleared($0) }
        let seconds = "within \(windowSeconds) seconds of the restore request"
        guard !withheld.isEmpty else {
            return "The helper did not report every fan automatic and no lease \(seconds)."
        }
        let named = withheld.map { fan -> String in
            guard case .unavailable(let reason) = fan.manualControlAvailability else {
                return "fan \(fan.index)"
            }
            return "fan \(fan.index) (\(StatusCommand.displayable(reason).wireValue))"
        }
        return "The helper has not cleared \(named.joined(separator: ", ")) \(seconds), although "
            + "the mode reads automatic."
    }

    /// Exit 8: not confirmed, with no lease in the way and nothing durable pinned.
    ///
    /// A fan that is not cleared is listed with its availability in the helper's words whatever
    /// its mode reads, so a blind fan (`supervisorBlind`) names its reason and carries the
    /// reason's own advice; the restart that advice leads to is the paragraph at the end.
    static func notConfirmedMessage(_ observation: Observation) -> String {
        var paragraphs: [String] = []
        if let interruption = observation.interruption {
            // The sentence beside `snapshotFollowsRestore` says what the flag says: whether the
            // snapshot shown was read after the request was sent.
            let when =
                observation.snapshotFollowsRestore
                ? "The snapshot shown was read after the restore request, and is the last the "
                    + "helper returned."
                : "The snapshot shown was read before the restore request."
            paragraphs.append(
                "This run could not confirm the result: after the restore request the helper "
                    + "stopped answering (\(interruption)). \(when)")
        } else {
            paragraphs.append(timedOutSentence(observation.snapshot))
        }
        var still = unclearedFanLines(observation.snapshot)
        if let failure = observation.restoreFailure {
            still.append("The helper did not confirm the restore request: \(failure)")
        }
        paragraphs.append(contentsOf: still.isEmpty ? [] : [still.joined(separator: "\n")])
        if observation.snapshot.isThermalEmergencyActive {
            paragraphs.append(
                "The helper reports a thermal emergency, and its override outranks this request.")
        }
        paragraphs.append(sentOnce)
        paragraphs.append(ResetCommand.stopTheHelper)
        return paragraphs.joined(separator: "\n\n")
    }

    /// Exit 5: a lease is listed when the wait ends. Held by someone who took the fans after
    /// the restore, or never ended by it; the message does not claim to know which.
    static func leasePresentMessage(_ observation: Observation, lease: Lease) -> String {
        """
        A manual-control lease held by "\(holder(lease))" (id \(lease.id.uuidString)) is listed \
        in the helper's latest snapshot, so the safe state is not confirmed. It was held, or \
        taken again, after this run's restore request.

        \(sentOnce) Taking the fans back a second time would be a fight with that client over \
        the same fans.
        """
    }

    /// Exit 9: the helper reports a reason waiting will not change, whatever the fan's mode
    /// reads.
    ///
    /// Each pinned fan carries its reason's own summary and advice and the wire value a user
    /// finds in `docs/RECOVERY.md`. That advice for `restoreToAutomaticFailed` is `fanctl reset
    /// --all`, which is the request this run already made, so it is said rather than left
    /// circular. Stopping the helper is offered only for that reason: it does not release a fan
    /// another program holds, and offering it for one would send a user to the wrong step.
    static func cannotReturnMessage(_ observation: Observation, pinned: [Int]) -> String {
        let snapshot = observation.snapshot
        var lines = [
            "The helper reports a reason for these fans that repeating the request will not "
                + "change, and the mode a fan reads does not clear it:"
        ]
        var refusedByFirmware = false
        for fan in snapshot.fans where pinned.contains(fan.index) {
            guard case .unavailable(let reason) = fan.manualControlAvailability else { continue }
            let shown = StatusCommand.displayable(reason)
            if shown == .restoreToAutomaticFailed { refusedByFirmware = true }
            lines.append(
                "  Fan \(fan.index) (\(reads(fan))): \(shown.recoveryDescription) "
                    + "(reason: \(shown.wireValue))")
        }
        lines.append(contentsOf: unclearedFanLines(snapshot, excluding: pinned, also: true))
        var paragraphs = [lines.joined(separator: "\n")]
        paragraphs.append(
            "\(sentOnce) What to do about each reason is in docs/RECOVERY.md, under \"A specific "
                + "fan says manual control is not available\".")
        if refusedByFirmware {
            paragraphs.append(
                "That advice names `fanctl reset --all`; this run already made that request, so "
                    + "repeating it will not help. If the fan stays pinned, the next step needs "
                    + "neither this command nor the helper:")
            paragraphs.append(ResetCommand.stopTheHelper)
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
