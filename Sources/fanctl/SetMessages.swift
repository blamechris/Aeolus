import AeolusXPC
import FanKit
import Foundation

/// Everything `fanctl set` says in words.
///
/// One rule runs through all of it ([CLAUDE.md](../../CLAUDE.md) rule 6): **say what the helper
/// reported, and say that it is the helper's report.** The speed is a *target*; the fan's own
/// reading is the helper's `actualRPM`. A sentence that could be read as "the fans are
/// automatic" exists in two places, each behind the `.automatic` verdict of a snapshot read after
/// the release and in the helper's voice: `closingLine`, for an ordinary ending (exit 0), and
/// `afterApply`'s `.automatic` arm, for a loss, a timer failure or an `apply` that did not become
/// a hold (`SetMessages+SafeState`). `FanctlSetEndingTests.noFailureClaimsSuccess` holds every
/// outcome but exit 0 to never saying the first, and `SetHoldLossMessagesTests` holds the second
/// to the check's verdict. The same rule has a second half: **never present what was seen before
/// the release as what the helper reports after it.** When no snapshot was read after the
/// release, the lease and the fans are said to be unknown, not described from the snapshot
/// before (`SetMessages+SafeState`).
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
    ///
    /// **The target named is the one the helper holds**, from `snapshot`, the snapshot that
    /// confirmed the hold. The helper may hold a fan above the speed that was sent: until run 2
    /// it raises any client target below a fan's client floor to the floor (#670). The line then
    /// leads with the helper's target and names the one asked for as not held, so it never
    /// reports a target nothing is honouring (`CLAUDE.md` rule 6). `started` follows a snapshot
    /// in which every covered fan carries a held target (`SetCommand.loss`), so a fan without one
    /// is not reached here; the speed that was sent stands in for it if one ever is.
    static func startLines(_ hold: Hold, snapshot: SystemSnapshot) -> [String] {
        let duration = SetArguments.describe(seconds: hold.durationSeconds)
        var lines = hold.plans.map { plan -> String in
            let firmware =
                "firmware \(Formatting.number(plan.envelope.declaredMinimumRPM))–"
                + "\(Formatting.number(plan.envelope.declaredMaximumRPM)) RPM"
            let sent = "\(Formatting.number(plan.commandedRPM)) RPM"
            let held = snapshot.fans.first { $0.index == plan.index }?.targetRPM
            let speed: String
            if let held, held != plan.commandedRPM {
                let asked: String
                switch plan.requested {
                case .percent(let percent): asked = "the \(sent) that \(percent)% asked for"
                case .rpm: asked = "the \(sent) asked for"
                }
                speed =
                    "\(Formatting.number(held)) RPM target (the helper's, not \(asked); "
                    + "\(firmware))"
            } else {
                switch plan.requested {
                case .percent(let percent): speed = "\(percent)% (\(sent) target; \(firmware))"
                case .rpm: speed = "\(sent) target (\(firmware))"
                }
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
        case .signalBeforeHold(let signal):
            return "\(signal.name) was received \(beforeHold)"
        case .parentExited:
            return "the process that started it exited"
        case .outputClosed:
            return "standard output was closed or stopped taking lines"
        }
    }

    /// The first sentence of everything said about an ordinary ending. A run that ended before
    /// `started` never said "Holding", so it does not say a hold ended.
    static func lead(_ ending: Ending, hold: Hold) -> String {
        if case .signalBeforeHold = ending {
            return "The hold was not begun: \(why(ending, hold: hold))."
        }
        return "The hold ended: \(why(ending, hold: hold))."
    }

    /// When a signal noted before `started` landed: after the lease was taken and before the
    /// pending signal was looked at, which is once `apply` and the snapshot confirming it have
    /// both been answered.
    static let beforeHold = "while the speed was being applied or confirmed"

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
        return "\(lead(ending, hold: hold)) \(releaseSentence(release, hold: hold)) "
            + "The helper now reports \(state), in a snapshot it captured at \(captured)."
    }

    // MARK: - Control held, then lost: 6

    /// Control was lost once the hold was under way. The lease was released and the safe state
    /// looked at, and **what is said of the fans is the check's verdict and nothing else**: a
    /// release answered "accepted" says nothing of a restore the firmware refused, so "nothing is
    /// held" is never said on the release's word.
    static func lost(
        _ loss: Loss, hold: Hold, release: Release, settlement: SafeState.Settlement
    ) -> String {
        afterApply(
            lead: "Control was lost: \(sentence(for: loss, hold: hold))\n\n"
                + "This run took the lease once and never re-acquires it.",
            hold: hold, release: release, settlement: settlement)
    }

    /// What a loss says, as a clause that follows a colon.
    static func sentence(for loss: Loss, hold: Hold) -> String {
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
            // The helper's report, in its voice: the only evidence is the emergency flag, and an
            // emergency that clears inside the check's window leaves every fan automatic.
            return "the helper reports a thermal emergency, and its override outranks manual "
                + "control. The helper reports its thermal protection, not this run, in control "
                + "of the fans."
        case .fanNotReported(let fan):
            return "the helper's snapshot no longer reports fan \(fan), so this run cannot say it "
                + "is holding it."
        case .fanNotHeld(let fan):
            return "the helper's snapshot lists lease \(id) but states no held target for fan "
                + "\(fan), so the helper is not saying it holds that fan and this run cannot say "
                + "it is holding it. A fan the helper holds under a live lease carries one."
        }
    }

    // MARK: - Other ways a run does not hold

    /// A sentence for a signal that landed while the speed was being applied or confirmed, which
    /// a failure that followed it must not lose. Empty when none did.
    static func signalNote(_ signal: HoldSignal?) -> String {
        guard let signal else { return "" }
        return "\n\n\(signal.name) was received \(beforeHold)."
    }

    /// The hold's own timer failed. Released, and the safe state looked at: what is said of the
    /// fans is the check's verdict.
    static func timerFailed(
        hold: Hold, release: Release, settlement: SafeState.Settlement
    ) -> String {
        afterApply(
            lead: "fanctl's timer failed, so it can no longer pace the lease's heartbeat.",
            hold: hold, release: release, settlement: settlement)
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
