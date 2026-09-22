// The user-facing rendering of `ManualControlAvailability.Reason` — #310, and the gap #303's
// completeness review found first: the doc comments on every case in
// `ManualControlAvailability.swift` carefully distinguish what happened and what to do about
// it, and until this file, nothing on the client side of the boundary read a single one of
// them. The only rendering was `AeolusXPCFault.errorDescription` printing the raw wire value —
// `restoreToAutomaticUnconfirmed` — which is the vocabulary this type serialises as, not a
// sentence a person asked "why can't I control this fan" can act on.
//
// Its own file, and in `FanKit` rather than in `AeolusXPC`, for the same two reasons
// `FaultText.swift` split out of `AeolusXPCFault.swift`: a rendering concern is a different
// question from a wire-shape concern, and `ManualControlAvailability.swift` already carries the
// vocabulary at a size that has no headroom for another switch this large. Living in `FanKit`
// also means it is reachable from anything that already links the pure model target — today
// that is `AeolusXPC`'s `errorDescription`, and it should be reachable from `fanctl` or the app
// directly the day either one grows a command that shows a fan's availability without going
// through a fault at all.
//
// `Sources/AeolusHelper` never runs a line of this file. It is prose, not control flow: no
// case here decides what the helper does, only what a client says about what the helper
// already decided.

extension ManualControlAvailability.Reason {

    /// What is true right now, in one sentence a user can read without the source open next
    /// to it. Never claims the fan is controllable — that is `ManualControlAvailability`'s own
    /// `.available` case, a different value entirely, and nothing here is reachable from it.
    ///
    /// **Exhaustive, with no `default:` arm.** A `Reason` this file has not been taught about
    /// is a compile error here, not a value that falls through to a generic sentence nobody
    /// wrote — see `ManualControlAvailabilityRecoveryTests` for the mutation that proves it.
    ///
    /// Faithful to each case's own documentation in `ManualControlAvailability.swift`: this
    /// property states nothing that type's doc comment does not already say. Where that
    /// comment gives no explicit advice for a reason, `recoveryAdvice` below says so rather
    /// than inventing a fix.
    public var userFacingSummary: String {
        switch self {
        case .writePathNotBuilt:
            return "This build of Aeolus has no path to write to the SMC yet, so manual "
                + "control is not available for any fan."
        case .boundsImplausible:
            return "This fan's firmware speed bounds did not pass a plausibility check, so "
                + "there is no safe range to control it within."
        case .reclaimedBySystem:
            return "The system has taken this fan back from manual control. Aeolus is not "
                + "driving it right now."
        case .leaseHeldByAnotherClient:
            return "Another Aeolus client already holds the manual-control lease that would "
                + "be needed to take this fan."
        case .selfRenewalNotBuilt:
            return "A self-renewing lease was requested for this fan, and this build does not "
                + "implement one."
        case .releaseInProgress:
            return "This fan is mid-handback: a previous lease just ended and the write that "
                + "returns it to automatic control has not completed yet."
        case .handbackUnconfirmed:
            return "Aeolus asked for this fan back and stopped waiting for an answer before "
                + "one arrived, so it does not yet know what mode the fan is in."
        case .restoreToAutomaticUnconfirmed:
            return "Aeolus issued a restore-to-automatic write for this fan and has not yet "
                + "confirmed the fan is back under automatic control — the write may or may "
                + "not have been accepted."
        case .restoreToAutomaticFailed:
            return "Aeolus tried to hand this fan back to automatic control and the firmware "
                + "never took the write, so Aeolus no longer knows what mode the fan is in."
        case .systemSleeping:
            return "The machine is going to sleep (or Aeolus believes it is), and every fan "
                + "has already been handed back to automatic control for the duration."
        case .noThermalTelemetry:
            return "Aeolus cannot currently read a critical temperature, so it cannot safely "
                + "watch a fan under manual control."
        case .supervisorBlind:
            return "Aeolus cannot currently read this fan's own control state, so it cannot "
                + "tell whether something else has taken it back."
        case .foreignManualControl:
            return "Something other than Aeolus has put this fan under manual control."
        case .unknown:
            return "The helper refused manual control for a reason this build does not "
                + "recognise."
        }
    }

    /// What to do about it, or the honest admission that there is nothing to do from this
    /// client. Never invents a fix `ManualControlAvailability.swift`'s own documentation does
    /// not give for that case — several reasons below say plainly that there is no user action,
    /// because that is what their doc comments say.
    ///
    /// Exhaustive for the same reason `userFacingSummary` is.
    public var recoveryAdvice: String {
        switch self {
        case .writePathNotBuilt:
            return "This is the expected answer for every fan on the current build; there is "
                + "no user action that changes it yet."
        case .boundsImplausible:
            return "There is no user action that resolves this from this client; it is a "
                + "property of what the firmware reported for this fan's bounds."
        case .reclaimedBySystem:
            return "There is no user action; it returns to Aeolus's control if the system "
                + "yields the fan again."
        case .leaseHeldByAnotherClient:
            return "It becomes available again once that lease ends or is released."
        case .selfRenewalNotBuilt:
            return "Ask for a lease without self-renewal instead."
        case .releaseInProgress:
            return "Retry in a moment; this normally clears in milliseconds."
        case .handbackUnconfirmed:
            return "The outstanding restore is still running; retry shortly, or watch "
                + "connection health. A helper restart is not the first action — only reach "
                + "for it if this still stands after the machine wakes from sleep."
        case .restoreToAutomaticUnconfirmed:
            return "This ordinarily clears within one supervisor cycle; retry shortly. If it "
                + "persists, see docs/RECOVERY.md."
        case .restoreToAutomaticFailed:
            return "Run `fanctl reset --all` to ask the firmware for this fan again, or see "
                + "docs/RECOVERY.md if that does not clear it."
        case .systemSleeping:
            return "Retry after the machine wakes, not immediately. If it is still refused "
                + "after that, see docs/RECOVERY.md."
        case .noThermalTelemetry:
            return "There is nothing to do from here; it clears when the SMC answers again, "
                + "and retrying does not speed that up."
        case .supervisorBlind:
            return "It may clear on its own if the connection recovers; if it does not, see "
                + "docs/RECOVERY.md."
        case .foreignManualControl:
            return "Quit or stop the other program that is driving this fan."
        case .unknown:
            return "This client may be older than the helper that sent it. It is not "
                + "available in the meantime — do not treat this as permission to control "
                + "the fan."
        }
    }

    /// `userFacingSummary` and `recoveryAdvice`, combined into the one string a client with
    /// no reason to keep them apart can print. Every caller that needs the raw wire value
    /// alongside it — so a user can find the matching section of `docs/RECOVERY.md` — appends
    /// `wireValue` itself; this property carries only the prose.
    public var recoveryDescription: String {
        "\(userFacingSummary) \(recoveryAdvice)"
    }
}
