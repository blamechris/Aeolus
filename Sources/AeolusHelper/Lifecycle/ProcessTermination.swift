import os

/// The one claim on ending the process: **the first claimant calls the terminate seam, and
/// every later one logs and returns** (ADR 0012 I5, and correction 3 of the amendment).
///
/// Two things end the helper. `SignalTeardown` ends it after the orderly sequence, with the
/// code the keystone's answer names, and `LivenessWatchdog` ends it `.blind` when a round trip
/// or a safety cycle does not return. Both go through the same object, built once inside
/// `TeardownSeams`, so there is one claim and not two: a teardown that finished a moment after
/// the watchdog fired must not run `exit` a second time with a different code, and a watchdog
/// that fired after the teardown had already begun the exit must not start another.
///
/// ## The ending is synchronous, on purpose
///
/// `claim(_:)` and `Claim.end()` are plain synchronous calls, and the terminate seam they end
/// in is synchronous too. This reverses an alternative ADR 0012 first rejected (a hand-off
/// from the watchdog's queue to an `async` seam), and the reason is evidence, not taste: a
/// verdict is only worth reaching in the case where the cooperative pool is not making
/// progress, and a `Task` needs a pool thread. With the pool parked the hand-off never runs, no
/// `ExitTimeOut` bounds a job that nothing is stopping, and `fired` stops a second tick from
/// trying again. `exit` needs no executor. So the watchdog takes the claim and ends the process
/// on its own queue, and `exit` is still named in exactly one place (`TeardownExit`).
///
/// ## What it must not do: consult whether the teardown has begun
///
/// `SignalTeardown` sets its `hasBegun` before it awaits the gate close and the lease release,
/// and both of those queue behind a wedged connection. A guard that read "the teardown has
/// begun" and stood down would silence the watchdog in exactly the case the watchdog stays
/// armed through teardown for. And `hasBegun` is private actor state, so reading it from the
/// watchdog's queue would mean awaiting `SignalTeardown`, which the watchdog never does. The
/// claim is taken by the first caller to *end the process*, whatever else is in progress.
///
/// ## Why a class
///
/// The claim is shared state taken from two threads. An `OSAllocatedUnfairLock` holds it, so
/// the compiler checks `Sendable` and there is no unchecked claim to review.
final class ProcessTermination: Sendable {

    /// The outcome of asking to end the process.
    enum Claim: Sendable {
        /// This caller holds the claim and **must** call `end()`. Nobody else will.
        case granted(Ending)
        /// Something else already holds it, and is ending the process as `holder`.
        case refused(holder: TeardownOutcome)
    }

    /// The right to end the process, which only a granted claim can hold.
    ///
    /// A value rather than a method on `ProcessTermination` so that "call the terminate seam
    /// without having taken the claim" is not a thing a caller can write.
    struct Ending: Sendable {
        let outcome: TeardownOutcome
        fileprivate let terminate: @Sendable (TeardownOutcome) -> Void

        /// Ends the process. In the shipping daemon this does not return.
        func end() {
            terminate(outcome)
        }
    }

    /// What actually ends the process: `TeardownExit.process` in every shipping build.
    private let terminate: @Sendable (TeardownOutcome) -> Void

    /// The outcome the process is ending with, or `nil` while nothing has claimed it. Set in
    /// the same locked step that decides who is first, so there is no gap between the check
    /// and the claim for a second caller to fit in.
    private let held = OSAllocatedUnfairLock<TeardownOutcome?>(initialState: nil)

    private let log: WatchdogLog

    init(
        terminate: @escaping @Sendable (TeardownOutcome) -> Void,
        log: WatchdogLog = WatchdogLog()
    ) {
        self.terminate = terminate
        self.log = log
    }

    /// Takes the claim, or says who holds it. Never ends the process by itself.
    func claim(_ outcome: TeardownOutcome) -> Claim {
        let holder = held.withLock { held -> TeardownOutcome? in
            if let held { return held }
            held = outcome
            return nil
        }
        if let holder { return .refused(holder: holder) }
        return .granted(Ending(outcome: outcome, terminate: terminate))
    }

    /// Ends the process with `outcome`, unless something already is — in which case it logs
    /// that and returns. The orderly teardown's last step.
    func end(_ outcome: TeardownOutcome) {
        switch claim(outcome) {
        case .granted(let ending):
            ending.end()
        case .refused(let holder):
            log.terminationAlreadyClaimed(by: holder, refused: outcome)
        }
    }
}
