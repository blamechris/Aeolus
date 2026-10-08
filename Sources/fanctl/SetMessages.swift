import AeolusXPC
import FanKit
import Foundation

/// Everything `fanctl set` says in words.
///
/// One rule runs through all of it ([CLAUDE.md](../../CLAUDE.md) rule 6): **say what the helper
/// reported, and say that it is the helper's report.** The speed is a *target*; the fan's own
/// reading is the helper's `actualRPM`. A sentence that could be read as "the fans are
/// automatic" exists in exactly one place, `closingLine`, behind the one verdict that earns it,
/// and `FanctlSetEndingTests.noFailureClaimsSuccess` holds every other outcome to never saying
/// it.
enum SetMessages {

    typealias Hold = SetCommand.Hold
    typealias Ending = SetCommand.Ending
    typealias Loss = SetCommand.Loss
    typealias Release = SetCommand.Release

    // MARK: - Starting

    /// One line per fan, then the way out. The last line carries it so a single fan reads as
    /// one sentence: `Holding fan 0 at 75% (4670 RPM target; firmware 1350–5777 RPM) for 30m
    /// under lease <id>. Ctrl-C returns it to automatic sooner.`
    static func startLines(_ hold: Hold) -> [String] {
        let duration = SetArguments.describe(seconds: hold.durationSeconds)
        var lines = hold.plans.map { plan -> String in
            let firmware =
                "firmware \(Formatting.number(plan.envelope.declaredMinimumRPM))–"
                + "\(Formatting.number(plan.envelope.declaredMaximumRPM)) RPM"
            let target = "\(Formatting.number(plan.commandedRPM)) RPM target"
            let speed: String
            switch plan.requested {
            case .percent(let percent): speed = "\(percent)% (\(target); \(firmware))"
            case .rpm: speed = "\(target) (\(firmware))"
            }
            return "Holding fan \(plan.index) at \(speed) for \(duration) under lease "
                + "\(hold.leaseID.uuidString)."
        }
        let way = hold.plans.count == 1 ? "it" : "them"
        lines[lines.count - 1] += " Ctrl-C returns \(way) to automatic sooner."
        return lines
    }

    // MARK: - Ending

    /// Why the hold ended, as a clause.
    static func why(_ ending: Ending, hold: Hold) -> String {
        switch ending {
        case .durationElapsed:
            return "the \(SetArguments.describe(seconds: hold.durationSeconds)) it was asked for "
                + "has passed"
        case .signal(let signal):
            return "\(signal.name) was received"
        case .parentExited:
            return "the process that started it exited"
        case .outputClosed:
            return "standard output was closed"
        }
    }

    static func releaseSentence(_ release: Release, hold: Hold) -> String {
        switch release {
        case .accepted:
            return "The helper accepted the release of lease \(hold.leaseID.uuidString)."
        case .failed(let reason):
            return "The helper did not confirm the release of lease \(hold.leaseID.uuidString): "
                + "\(reason)"
        }
    }

    /// The one sentence a clean ending prints, and the only place `set` says the helper reports
    /// the safe state. In the helper's voice, with the time the helper captured it.
    ///
    /// **Mutation target:** returning this for every verdict is what
    /// `FanctlSetEndingTests.noFailureClaimsSuccess` exists to catch.
    static func closingLine(
        _ ending: Ending, hold: Hold, release: Release, snapshot: SystemSnapshot?
    ) -> String {
        let captured = snapshot.map { StatusCommand.iso8601($0.capturedAt) } ?? "an unknown time"
        let state =
            snapshot?.fans.isEmpty == true
            ? "no fans and no manual-control lease"
            : "every fan automatic and no manual-control lease"
        return "The hold ended: \(why(ending, hold: hold)). "
            + "\(releaseSentence(release, hold: hold)) "
            + "The helper now reports \(state), in a snapshot it captured at \(captured)."
    }

    // MARK: - Not the safe state: 8 and 9

    private static let window = SafeState.window.components.seconds

    private static let lifetime = Int(Lease.defaultTimeToLive)

    /// Where to go when a hold ended and the helper did not report the fans returned.
    private static let nextSteps = """
        This run renews nothing now, and will not release the lease a second time. By design the \
        helper ends a lease that is not renewed within \(lifetime) seconds. Run `fanctl status` \
        to see what the helper reports, or `fanctl auto` to ask it to return every fan to \
        automatic control and check.

        \(ResetCommand.stopTheHelper)
        """

    /// Exit 8: the hold ended, and within the wait the helper did not report every fan automatic
    /// and no lease.
    static func notConfirmed(
        _ ending: Ending, hold: Hold, release: Release, settlement: SafeState.Settlement,
        snapshot: SystemSnapshot?
    ) -> String {
        var paragraphs = [
            "The hold ended: \(why(ending, hold: hold)). \(releaseSentence(release, hold: hold))"
        ]
        if let interruption = settlement.interruption {
            let when =
                settlement.snapshot != nil
                ? "The snapshot shown was read after the release, and is the last the helper "
                    + "returned."
                : "No snapshot was read after the release."
            paragraphs.append(
                "This run could not confirm the result: after the release the helper stopped "
                    + "answering (\(SetCommand.describe(interruption))). \(when)")
        } else {
            paragraphs.append(
                "The helper did not report every fan automatic and no lease within \(window) "
                    + "seconds of the release.")
        }
        var still: [String] = []
        if let snapshot {
            still += AutoCommand.unclearedFanLines(snapshot)
            if let lease = snapshot.activeLease {
                still.append(listedLease(lease, hold: hold))
            }
            if snapshot.isThermalEmergencyActive {
                still.append(
                    "The helper reports a thermal emergency, and its override outranks this hold.")
            }
        }
        if !still.isEmpty { paragraphs.append(still.joined(separator: "\n")) }
        paragraphs.append(nextSteps)
        return paragraphs.joined(separator: "\n\n")
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
        _ ending: Ending, hold: Hold, release: Release, snapshot: SystemSnapshot?,
        pinned: [Int]
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
            "The hold ended: \(why(ending, hold: hold)). \(releaseSentence(release, hold: hold))",
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

    // MARK: - Control held, then lost: 6

    static func lost(_ loss: Loss, hold: Hold, release: Release) -> String {
        """
        Control was lost: \(sentence(for: loss, hold: hold))

        This run took the lease once and never re-acquires it. \
        \(releaseSentence(release, hold: hold)) Nothing is held by this process now. Run \
        `fanctl status` to see what the helper reports, or `fanctl auto` to ask it to return \
        every fan to automatic control and check.
        """
    }

    private static func sentence(for loss: Loss, hold: Hold) -> String {
        let id = hold.leaseID.uuidString
        switch loss {
        case .renewalFailed(let reason):
            return "the helper did not renew lease \(id): \(reason)"
        case .snapshotFailed(let reason):
            return "the helper's snapshot could not be read, so this run can no longer say it "
                + "holds the fans: \(reason)"
        case .leaseNotListed(let listed):
            let instead =
                listed.map {
                    "It lists a lease held by \"\($0.holder)\" (id \($0.id.uuidString)) instead."
                } ?? "It lists no lease."
            return "the helper's snapshot no longer lists lease \(id). \(instead)"
        case .reclaimed(let fan):
            return "the helper reports fan \(fan) reclaimed by the system. Aeolus is not driving "
                + "that fan right now, whatever the target says."
        case .thermalEmergency:
            return "the helper reports a thermal emergency, and its override outranks manual "
                + "control."
        case .fanNotReported(let fan):
            return "the helper's snapshot no longer reports fan \(fan), so this run cannot say it "
                + "is holding it."
        }
    }

    // MARK: - Other ways a run does not hold

    /// `apply` was refused or unanswered.
    static func refused(
        _ failure: HelperCommandFailure, hold: Hold, release: Release
    ) -> String {
        """
        The helper took lease \(hold.leaseID.uuidString) and did not accept the speed: \
        \(failure.message)

        \(releaseSentence(release, hold: hold)) Nothing is held by this process.
        """
    }

    static func timerFailed(hold: Hold, release: Release) -> String {
        """
        fanctl's timer failed, so it can no longer pace the lease's heartbeat. \
        \(releaseSentence(release, hold: hold)) Nothing is held by this process now. Run \
        `fanctl status` to see what the helper reports, or `fanctl auto` to ask it to return \
        every fan to automatic control and check.
        """
    }

    static func interruptedBeforeControl(_ signal: HoldSignal) -> String {
        "\(signal.name) was received before control was taken. Nothing was acquired and nothing "
            + "was sent to a fan."
    }
}
