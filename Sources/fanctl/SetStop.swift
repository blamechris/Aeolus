import Foundation

extension SetCommand {

    /// Whether the hold has been asked to stop, and for which of its reasons.
    ///
    /// A consumer that is not draining ends the hold as `outputClosed` (`SetOutput.hasTrouble`),
    /// but **a stop request is always the reason when there is one**: a signal, the parent
    /// exiting, or the deadline ends the hold for *that* reason whatever standard output is
    /// doing, and only when nothing else asked it to stop is the consumer the reason.
    ///
    /// The order is the order they are looked in: a signal, then the parent, then the deadline.
    struct StopWatch: Sendable {
        let interrupt: HoldInterrupt
        let environment: HoldEnvironment
        let clock: SettleClock
        let startingParent: Int32
        let deadline: ContinuousClock.Instant

        var reason: Ending? {
            if let signal = interrupt.pending { return .signal(signal) }
            if environment.parentProcessID() != startingParent { return .parentExited }
            if clock.now() >= deadline { return .durationElapsed }
            return nil
        }
    }
}
