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
        if let ended = observation.endedLease {
            lines.append(
                "Ended the manual-control lease held by \"\(holder(ended))\" (id "
                    + "\(ended.id.uuidString)). The helper's snapshot no longer lists it; that "
                    + "client will find its lease gone.")
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

    /// Fans that still read manual, one line each, in the helper's own words.
    private static func manualFanLines(
        _ snapshot: SystemSnapshot, excluding excluded: [Int] = [], also: Bool = false
    ) -> [String] {
        let verb = also ? "also still reads manual" : "still reads manual"
        return snapshot.fans.filter { $0.mode != .automatic && !excluded.contains($0.index) }.map {
            "  Fan \($0.index) \(verb): "
                + StatusCommand.availability($0.manualControlAvailability)
        }
    }

    /// Exit 8: not confirmed, with no lease in the way and nothing durable pinned.
    static func notConfirmedMessage(_ observation: Observation) -> String {
        var paragraphs: [String] = []
        if let interruption = observation.interruption {
            paragraphs.append(
                "This run could not confirm the result: after the restore request the helper "
                    + "stopped answering (\(interruption)). The snapshot shown may predate the "
                    + "restore.")
        } else {
            paragraphs.append(
                "The helper did not report every fan automatic and no lease within "
                    + "\(windowSeconds) seconds of the restore request.")
        }
        var still = manualFanLines(observation.snapshot)
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

    /// Exit 9: a fan reads manual for a reason waiting will not change.
    ///
    /// Each pinned fan carries its reason's own summary and advice and the wire value a user
    /// finds in `docs/RECOVERY.md`. That advice for `restoreToAutomaticFailed` is `fanctl reset
    /// --all`, which is the request this run already made, so it is said rather than left
    /// circular. Stopping the helper is offered only for that reason: it does not release a fan
    /// another program holds, and offering it for one would send a user to the wrong step.
    static func cannotReturnMessage(_ observation: Observation, pinned: [Int]) -> String {
        let snapshot = observation.snapshot
        var lines = [
            "These fans still read manual, for a reason that repeating the request will not "
                + "change:"
        ]
        var refusedByFirmware = false
        for fan in snapshot.fans where pinned.contains(fan.index) {
            guard case .unavailable(let reason) = fan.manualControlAvailability else { continue }
            let shown = StatusCommand.displayable(reason)
            if shown == .restoreToAutomaticFailed { refusedByFirmware = true }
            lines.append(
                "  Fan \(fan.index): \(shown.recoveryDescription) (reason: \(shown.wireValue))")
        }
        lines.append(contentsOf: manualFanLines(snapshot, excluding: pinned, also: true))
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
