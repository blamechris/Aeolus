import os

/// The one claim on ending the process: **the first `end(_:)` calls the terminate seam, and
/// every later one logs and returns** (ADR 0012 I5, and correction 3 of the amendment).
///
/// Two things end the helper. `SignalTeardown` ends it after the orderly sequence, with the
/// code the keystone's answer names, and `LivenessWatchdog` ends it `.blind` when a round trip
/// or a safety cycle does not return. Both go through the same object, built once inside
/// `TeardownSeams`, so there is one claim and not two: a teardown that finished a moment after
/// the watchdog fired must not run `exit` a second time with a different code, and a watchdog
/// that fired after the teardown had already begun the exit must not start another.
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

    /// What actually ends the process: `TeardownExit.process` in every shipping build.
    private let terminate: @Sendable (TeardownOutcome) async -> Void

    /// The outcome the process is ending with, or `nil` while nothing has claimed it. Set in
    /// the same locked step that decides who is first, so there is no gap between the check
    /// and the claim for a second caller to fit in.
    private let claim = OSAllocatedUnfairLock<TeardownOutcome?>(initialState: nil)

    private let log: WatchdogLog

    init(
        terminate: @escaping @Sendable (TeardownOutcome) async -> Void,
        log: WatchdogLog = WatchdogLog()
    ) {
        self.terminate = terminate
        self.log = log
    }

    /// Ends the process with `outcome`, unless something already is.
    ///
    /// In the shipping daemon the first call does not return. Under a recorder it does, which
    /// is what lets a test observe a second call being refused.
    func end(_ outcome: TeardownOutcome) async {
        let already = claim.withLock { held -> TeardownOutcome? in
            if let held { return held }
            held = outcome
            return nil
        }
        if let already {
            log.terminationAlreadyClaimed(by: already, refused: outcome)
            return
        }
        await terminate(outcome)
    }
}
