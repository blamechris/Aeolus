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
/// it. The same rule has a second half: **never present what was seen before the release as what
/// the helper reports after it.** When no snapshot was read after the release, the lease and the
/// fans are said to be unknown, not described from the snapshot before (`SetMessages+SafeState`).
enum SetMessages {

    typealias Hold = SetCommand.Hold
    typealias Ending = SetCommand.Ending
    typealias Loss = SetCommand.Loss
    typealias Release = SetCommand.Release

    /// How long the helper keeps a lease that is no longer renewed.
    static let lifetime = Int(Lease.defaultTimeToLive)

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
            return "standard output was closed or stopped taking lines"
        }
    }

    /// The first sentence of everything said about an ordinary ending.
    static func lead(_ ending: Ending, hold: Hold) -> String {
        "The hold ended: \(why(ending, hold: hold))."
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

    /// What this process still holds once it has asked for the release. A release the helper
    /// did not confirm leaves a lease it may keep listing for its whole lifetime, so that is
    /// said instead of "nothing".
    static func heldSentence(_ release: Release) -> String {
        switch release {
        case .accepted:
            return "Nothing is held by this process now."
        case .failed:
            return "This process renews nothing now; the helper may keep listing the lease for "
                + "up to \(lifetime) seconds."
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
        return "\(lead(ending, hold: hold)) \(releaseSentence(release, hold: hold)) "
            + "The helper now reports \(state), in a snapshot it captured at \(captured)."
    }

    // MARK: - Control held, then lost: 6

    static func lost(_ loss: Loss, hold: Hold, release: Release) -> String {
        """
        Control was lost: \(sentence(for: loss, hold: hold))

        This run took the lease once and never re-acquires it. \
        \(releaseSentence(release, hold: hold)) \(heldSentence(release)) Run `fanctl status` to \
        see what the helper reports, or `fanctl auto` to ask it to return every fan to automatic \
        control and check.
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
                    "It lists a lease held by \"\(DisplayText.sanitised($0.holder))\" (id "
                        + "\($0.id.uuidString)) instead."
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

    /// `apply` was **refused**: the helper answered, and said no.
    static func refused(
        _ failure: HelperCommandFailure, hold: Hold, release: Release
    ) -> String {
        """
        The helper took lease \(hold.leaseID.uuidString) and did not accept the speed: \
        \(failure.message)

        \(releaseSentence(release, hold: hold)) \(heldSentence(release))
        """
    }

    static func timerFailed(hold: Hold, release: Release) -> String {
        """
        fanctl's timer failed, so it can no longer pace the lease's heartbeat. \
        \(releaseSentence(release, hold: hold)) \(heldSentence(release)) Run `fanctl status` to \
        see what the helper reports, or `fanctl auto` to ask it to return every fan to automatic \
        control and check.
        """
    }

    static func interruptedBeforeControl(_ signal: HoldSignal) -> String {
        "\(signal.name) was received before control was taken. Nothing was acquired and nothing "
            + "was sent to a fan."
    }

    /// The lease was taken, and a signal landed before the speed was sent.
    static func interruptedBeforeApply(
        _ signal: HoldSignal, hold: Hold, release: Release
    ) -> String {
        "\(signal.name) was received after lease \(hold.leaseID.uuidString) was taken and "
            + "before any speed was sent. \(releaseSentence(release, hold: hold)) Nothing was "
            + "sent to a fan."
    }
}
