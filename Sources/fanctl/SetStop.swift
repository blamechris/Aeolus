import Foundation

extension SetCommand {

    /// Whether the hold has been asked to stop, and for which of its reasons.
    ///
    /// A write to standard output waits on a reader for a bounded time (`Terminal.bounded`), and
    /// it asks this between waits. **A stop request wins over pending output:** a signal, the
    /// parent exiting, or the deadline ends the hold without the line being finished, and the
    /// hold ends for *that* reason. Only when nothing else asked it to stop is a reader that
    /// would not make room the reason (`outputClosed`).
    ///
    /// The order is the order they are looked in: a signal, then the parent, then the deadline.
    struct StopWatch: Sendable {
        let interrupt: HoldInterrupt
        let environment: HoldEnvironment
        let clock: SettleClock
        let startingParent: Int32
        /// `nil` before the hold has begun to count: the start lines are written before the
        /// deadline is minted, and cannot be late for it.
        let deadline: ContinuousClock.Instant?

        var reason: Ending? {
            if let signal = interrupt.pending { return .signal(signal) }
            if environment.parentProcessID() != startingParent { return .parentExited }
            if let deadline, clock.now() >= deadline { return .durationElapsed }
            return nil
        }
    }
}
