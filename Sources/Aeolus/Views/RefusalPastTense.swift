import FanKit

extension ManualControlAvailability.Reason {

    /// What the helper's refusal said, as an event that has already happened: the line beneath
    /// the control after a refused request (`FanControlPresentation`'s status line, #153).
    ///
    /// `userFacingSummary` says what is true **now**, which is right for a fan's row, where the
    /// availability is the current snapshot's. Under "the helper refused the request" it read as
    /// a claim about the machine at this moment ("right now", "currently", "has not completed
    /// yet"), made from an answer that may be minutes old. So each sentence here is that summary
    /// moved into the past and stripped of its words for the present, and nothing more: it adds
    /// no cause and no advice the summary does not give.
    ///
    /// "A fan", not "this fan": a request for control is refused for the whole request, and the
    /// line is shown beneath every fan's control.
    ///
    /// **Exhaustive, with no `default:`**, as `userFacingSummary` is, so a reason added to the
    /// vocabulary does not compile here until it has a sentence.
    var pastTenseSummary: String {
        switch self {
        case .writePathNotBuilt:
            return "The helper's build had no path to write to the SMC, so manual control was "
                + "not available for any fan."
        case .boundsImplausible:
            return "A fan's firmware speed bounds did not pass a plausibility check, so there was "
                + "no safe range to control it within."
        case .reclaimedBySystem:
            return "The system had taken a fan back from manual control."
        case .leaseHeldByAnotherClient:
            return "Another Aeolus client held the manual-control lease that taking a fan "
                + "required."
        case .selfRenewalNotBuilt:
            return "A self-renewing lease was requested, and the helper's build did not implement "
                + "one."
        case .releaseInProgress:
            return "A fan was mid-handback: a previous lease had ended and the write that returns "
                + "it to automatic control had not completed, or a restore of every fan at once "
                + "was running (`fanctl reset --all`, `fanctl auto`, or the handback before the "
                + "Mac sleeps)."
        case .handbackUnconfirmed:
            return "Aeolus had asked for a fan back and stopped waiting before an answer arrived, "
                + "so it did not know what mode the fan was in."
        case .restoreToAutomaticUnconfirmed:
            return "Aeolus had issued a restore-to-automatic write for a fan and had not confirmed "
                + "the fan back under automatic control; whether the write was accepted was not "
                + "known."
        case .restoreToAutomaticFailed:
            return "Aeolus had tried to hand a fan back to automatic control and the firmware "
                + "never took the write, so Aeolus did not know what mode the fan was in."
        case .systemSleeping:
            return "The machine was going to sleep (or Aeolus believed it was), and every fan had "
                + "been handed back to automatic control for the duration."
        case .noThermalTelemetry:
            return "Aeolus could not read a critical temperature, so it could not safely watch a "
                + "fan under manual control."
        case .supervisorBlind:
            return "Aeolus could not confirm a fan's own control state: a read of it failed, or "
                + "start-up could not confirm it back under automatic control."
        case .foreignManualControl:
            return "Something other than Aeolus had put a fan under manual control."
        case .unknown:
            return "The helper refused manual control for a reason this build does not "
                + "recognise."
        }
    }
}
