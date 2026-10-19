import AeolusXPC
import FanKit
import Foundation

// What `fanctl set` says when the check after the release did not find the safe state (8 and 9),
// and when `apply` did not become a hold: it got no answer, the helper answered with a fault, or
// the lease ended while it worked.
//
// **Everything said about the lease and the fans here comes from a snapshot read after the
// release, or is not said.** The snapshot the hold last read was taken while the lease was
// still held, so it lists this run's lease and a fan reading manual even when the release took
// them both away. A check that could not read after the release has no such snapshot, and what
// it reports is that the state is unknown (`unknownAfterRelease`), not the earlier one in the
// present tense.
extension SetMessages {

    private static let window = SafeState.window.components.seconds

    /// Where to go when a hold ended and the helper did not report the fans returned.
    private static let nextSteps = """
        This run renews nothing now, and will not release the lease a second time. By design the \
        helper ends a lease that is not renewed within \(lifetime) seconds. Run `fanctl status` \
        to see what the helper reports, or `fanctl auto` to ask it to return every fan to \
        automatic control and check.

        \(ResetCommand.stopTheHelper)
        """

    /// Exit 8: within the wait the helper did not report every fan automatic and no lease.
    ///
    /// - Parameters:
    ///   - lead: The first sentence, which says what ended or failed. The release sentence
    ///     follows it.
    ///   - hold: The lease and the fans.
    ///   - release: What became of the request to release the lease.
    ///   - settlement: What the check read after the release. Only this is described as the
    ///     state of the lease and the fans.
    /// - Returns: The message.
    static func notConfirmed(
        lead: String, hold: Hold, release: Release, settlement: SafeState.Settlement
    ) -> String {
        var paragraphs = ["\(lead) \(releaseSentence(release, hold: hold))"]
        let snapshot = settlement.snapshot
        if let interruption = settlement.interruption {
            paragraphs.append(
                snapshot == nil
                    ? unknownAfterRelease(
                        release, why: SetCommand.describe(interruption))
                    : "This run could not confirm the result: after the release the helper "
                        + "stopped answering (\(SetCommand.describe(interruption))). The "
                        + "snapshot shown was read after the release, and is the last the "
                        + "helper returned.")
        } else {
            paragraphs.append(
                "The helper did not report every fan automatic and no lease within \(window) "
                    + "seconds of the release.")
        }
        if let snapshot {
            var still = AutoCommand.unclearedFanLines(snapshot)
            if let lease = snapshot.activeLease {
                still.append(listedLease(lease, hold: hold))
            }
            if snapshot.isThermalEmergencyActive {
                still.append(
                    "The helper reports a thermal emergency, and its override outranks this hold.")
            }
            if !still.isEmpty { paragraphs.append(still.joined(separator: "\n")) }
        }
        paragraphs.append(nextSteps)
        return paragraphs.joined(separator: "\n\n")
    }

    /// What is said when no snapshot was read after the release: the helper's last word is its
    /// answer to the release, and everything after it is unknown.
    private static func unknownAfterRelease(_ release: Release, why: String) -> String {
        let stopped =
            release == .accepted
            ? "The helper accepted the release and then stopped answering (\(why))."
            : "After the release the helper stopped answering (\(why))."
        return "\(stopped) No snapshot was read after the release, so whether the lease ended "
            + "and what the fans are doing is unknown."
    }

    /// The lease the latest snapshot lists, and whether it is the one this run released.
    private static func listedLease(_ lease: Lease, hold: Hold) -> String {
        let holder = DisplayText.sanitised(lease.holderDescription)
        let whose =
            lease.id == hold.leaseID
            ? "this run's lease, which the release did not end"
            : "another client's lease, taken after this run's"
        return "A manual-control lease is still listed: id \(lease.id.uuidString), held by "
            + "\"\(holder)\" — \(whose)."
    }

    /// Exit 9: the helper reports a reason releasing the lease will not change, whatever mode
    /// the fan reads.
    static func cannotReturn(
        lead: String, hold: Hold, release: Release, snapshot: SystemSnapshot?, pinned: [Int]
    ) -> String {
        var lines = [
            "The helper reports a reason for these fans that releasing the lease will not "
                + "change, and the mode a fan reads does not clear it:"
        ]
        var refusedByFirmware = false
        for fan in snapshot?.fans ?? [] where pinned.contains(fan.index) {
            guard case .unavailable(let reason) = fan.manualControlAvailability else { continue }
            let shown = StatusCommand.displayable(reason)
            if shown == .restoreToAutomaticFailed { refusedByFirmware = true }
            lines.append(
                "  Fan \(fan.index) (\(AutoCommand.reads(fan))): \(shown.recoveryDescription) "
                    + "(reason: \(shown.wireValue))")
        }
        if let snapshot {
            lines += AutoCommand.unclearedFanLines(snapshot, excluding: pinned, also: true)
        }
        var paragraphs = [
            "\(lead) \(releaseSentence(release, hold: hold))",
            lines.joined(separator: "\n"),
            "What to do about each reason is in docs/RECOVERY.md, under \"A specific fan says "
                + "manual control is not available\".",
        ]
        if refusedByFirmware {
            paragraphs.append(
                "If the fan stays pinned, the next step needs neither this command nor the "
                    + "helper:")
            paragraphs.append(ResetCommand.stopTheHelper)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - An apply that did not become a hold

    /// What is said after the lease was released and the safe state looked at, whatever came
    /// before it: the lead says what happened to `apply`, and the check's verdict says what the
    /// helper reports now.
    ///
    /// **Nothing that reads as "no fan was touched" is said here.** Only the `.automatic` arm
    /// describes the fans, and in the helper's voice with the time it captured the snapshot.
    static func afterApply(
        lead: String, hold: Hold, release: Release, settlement: SafeState.Settlement
    ) -> String {
        switch settlement.verdict {
        case .automatic:
            let captured =
                settlement.snapshot.map { StatusCommand.iso8601($0.capturedAt) }
                ?? "an unknown time"
            return "\(lead) \(releaseSentence(release, hold: hold))\n\nA snapshot read after the "
                + "release, captured at \(captured), lists no manual-control lease and every "
                + "fan automatic, as the helper reports it."
        case .cannotReturn(let pinned):
            return cannotReturn(
                lead: lead, hold: hold, release: release, snapshot: settlement.snapshot,
                pinned: pinned)
        case .notConfirmed:
            return notConfirmed(lead: lead, hold: hold, release: release, settlement: settlement)
        }
    }

    /// The first sentence when `apply` got no answer. It says what is known (nothing came back)
    /// and what is not (whether the speed was applied), and never "refused".
    static func unansweredApplyLead(_ failure: HelperCommandFailure, hold: Hold) -> String {
        "The helper took lease \(hold.leaseID.uuidString) and then did not answer the request to "
            + "apply the speed, so it may have applied it. \(failure.message)"
    }

    /// `apply` got no answer: the lease was released, the safe-state check looked, and this is
    /// what it found. The exit is the check's verdict where that is worse than the code the failure
    /// classified to (`SetCommand.Report.code(_:after:)`).
    static func unansweredApply(
        _ failure: HelperCommandFailure, hold: Hold, release: Release,
        settlement: SafeState.Settlement
    ) -> String {
        afterApply(
            lead: unansweredApplyLead(failure, hold: hold), hold: hold, release: release,
            settlement: settlement)
    }

    /// The first sentence when the helper **answered `apply` with a fault**.
    ///
    /// "Did not accept the speed" is the helper's refusal read as the whole story, and it is the
    /// whole story only if the check that followed found every fan automatic and no lease. Level
    /// 6 can engage a fan, fail on the next, have the undo refused, and answer only the original
    /// fault; it can also find a thermal emergency set once every fan was written. So that
    /// phrase is said **only for `.automatic`**; otherwise the lead says what the answer was and
    /// that it does not settle what happened to the fans.
    static func faultedApplyLead(
        _ failure: HelperCommandFailure, hold: Hold, verdict: SafeState.Verdict
    ) -> String {
        let id = hold.leaseID.uuidString
        guard verdict == .automatic else {
            return "The helper took lease \(id) and answered the request to apply the speed with "
                + "a fault: \(failure.message) An answer like that does not say whether the "
                + "speed reached a fan before it, so this run released the lease and looked."
        }
        return "The helper took lease \(id) and did not accept the speed: \(failure.message)"
    }

    /// The helper answered `apply` with a fault; the lease was released and the safe state looked
    /// at. The exit is the fault's own code unless the check found something worse.
    static func faultedApply(
        _ failure: HelperCommandFailure, hold: Hold, release: Release,
        settlement: SafeState.Settlement
    ) -> String {
        afterApply(
            lead: faultedApplyLead(failure, hold: hold, verdict: settlement.verdict),
            hold: hold, release: release, settlement: settlement)
    }

    /// **Control was lost before the hold began**: the lease could no longer be *shown* to be
    /// held while the speed was being applied. Said as that: not a refusal, not "did not
    /// accept", and not a claim that the lease ended, which nobody saw (a reply that is not
    /// delivered leaves the lease live, and a renewal still in flight leaves it unknown). The
    /// helper ends a lease that is not renewed within `lifetime` seconds, but neither `apply`'s
    /// answer nor a failed renewal nor a snapshot says what it did to the fans, so this run
    /// released the lease and looked, and the verdict that follows is all it says of them.
    static func lapsed(
        _ lapse: SetCommand.Lapse, hold: Hold, release: Release, settlement: SafeState.Settlement
    ) -> String {
        var sentences = [
            "Control was lost before the hold began: control of lease \(hold.leaseID.uuidString) "
                + "could no longer be shown to be held."
        ]
        if let failure = lapse.renewalFailure {
            sentences.append(
                "A renewal of it failed while the speed was being applied: \(failure)")
        }
        switch lapse.apply {
        case .accepted:
            sentences.append("The helper accepted the request to apply the speed.")
        case .answered(let answer) where lapse.renewalFailure == nil:
            sentences.append(
                "The helper answered the request to apply the speed that the lease was gone: "
                    + "\(answer)")
        case .answered(let answer):
            sentences.append("The helper answered the request to apply the speed with: \(answer)")
        case .unanswered(let seen):
            sentences.append(
                "The request to apply the speed then got no answer, so the helper may have "
                    + "applied it: \(seen)")
        }
        switch lapse.confirmation {
        case .snapshotFailed(let reason)?:
            sentences.append("The snapshot read after it could not be read: \(reason)")
        case .notHeld(let loss)?:
            sentences.append(
                "The snapshot read after it did not show control held: "
                    + "\(sentence(for: loss, hold: hold))")
        case .timerFailed?:
            sentences.append(
                "fanctl's timer failed, so it could no longer pace the lease's heartbeat.")
        case nil:
            break
        }
        sentences.append(
            "The helper ends a lease that is not renewed within \(lifetime) seconds. This run "
                + "cannot say what it did to the fans, so it released the lease and looked.")
        return afterApply(
            lead: sentences.joined(separator: " "), hold: hold, release: release,
            settlement: settlement)
    }
}
