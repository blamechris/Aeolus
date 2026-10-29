import Foundation
import Testing

@testable import AeolusHelper

// The ceiling every parking double holds a restore under (#451).
//
// A double parks a restore on an `AsyncSignal`, and the park is in an unstructured task: the
// restorer runs each attempt in a `Task` that does not inherit cancellation, and the lease core
// awaits that task's `value`, which a cancellation cannot interrupt either. So a suite's
// `.timeLimit` cancels the test and leaves the park where it was. A mutation that issues a restore
// the test did not account for therefore reads as a hung run, one that never prints its
// `Test run with` line, rather than as a red one. The ceiling is what turns that into a failure:
// the park gives up, says so, and goes on.

/// How long a double holds a restore before it concludes nobody is coming for it.
///
/// **Failure-only, by margin, not by construction.** Passing tests do hold parks on purpose: across
/// one or more of § 4's 50 ms wall-clock acknowledgement budgets (the sleep suites,
/// `SystemPowerTests.theAcknowledgementIsBoundedByItsBudget`). #459 measured the longest
/// legitimate park at 0.18 s over a whole clean run, and at 1.4 s with the CPU twice
/// oversubscribed.
///
/// #464 measured it again, with the ceiling at 5 s: an instrumented `wait(atMost:)`, since
/// reverted, wrote a line per return, over twelve runs of the whole non-hardware suite on the
/// 16-core development machine, which was never idle (its load average read 197 to 570 as a run
/// began). Each run made 35 parks under the ceiling, every one was let through, and none expired.
/// The longest park was 0.19 to 0.31 s in three runs with nothing added, and in three each with
/// `yes` added at 2, 6 and 10 times the core count it was 0.42 to 0.47 s, 0.74 to 1.00 s and 1.03
/// to 1.40 s. 10 s leaves at least 7 times the longest park seen (1.40 s), and at least 2.7 times
/// the longest return of any wait (3.62 s, the 150 ms wait in
/// `ParkingCeilingTests.aGivenUpWaitDoesNotCancelTheOthers`); both ratios are floored. Lowering it
/// below 1.40 s would make legitimate parks expire, record an issue and release mid-test.
///
/// **Why it is not 5 s.** In every run all 45 returns, the 35 parks and the ten waits
/// `ParkingCeilingTests` makes, directly or through its doubles, fell within 0.2 to 1.1 s of one
/// another. One of the ten has a 150 ms ceiling (`aGivenUpWaitDoesNotCancelTheOthers`), and it
/// returned 0.24 to 3.62 s after it began; 3.62 s is 72 % of 5 s, the ceiling's value when
/// measured. It is not a park, and the longest park was 1.40 s. The logs do not say why it
/// returned late, and whether the delay that held it also reaches a park's signal path was not
/// established. That is why the value was raised from 5 s to 10 s. Nothing here covers a hold
/// longer than 3.62 s.
///
/// `parkCeiling` is **scheduled waiting time**, as `outwaitCeiling` is (#547): `wait(atMost:)` is a
/// `StallTolerantWait` poll on the real `ContinuousClock`, so a poll that comes back more than
/// 250 ms late has the difference added to the deadline, up to that wait's 50 s cap. It used to be
/// a single wall-clock sleep, which spends a stall: stopping the test process for 15 s expired the
/// parks held at that moment in `SleepGrantSealTests`, `SleepCycleSurvivalTests` and
/// `UnconfirmedHandbackTests`, with a test about to release each one (#549). The virtual clock a
/// test moves by hand is still not an option, because it would have the park expire at once.
///
/// A park nobody releases still gives up, within the suites' one-minute `.timeLimit`: at the
/// ceiling when the run had no stall in it, and at the 50 s cap at the latest when it had. Three
/// expiries in a row with no stall take 30 s of that limit, so a test that hits it that often
/// still ends before the limit does. What compensation cannot tell from a stall is a poll the
/// process did not run for another reason, and those are compensated too.
///
/// The issue a park that gave up records says what happened and not what was asked for: the time
/// it waited, the stall it compensated, and whether the cap ended it
/// (``recordAbandonedPark(by:of:after:sourceLocation:)``). Printing `parkCeiling` would say 10 s
/// for a park the cap ended at 50 s of wall time, 45 s of which were a stall.
let parkCeiling = Duration.seconds(10)

/// How often the park's timer looks at the clock. Short against the 250 ms a poll must come back
/// late by to count as a stall, and long enough that a park costs a wakeup per 10 ms rather than
/// per millisecond.
let parkPollInterval = Duration.milliseconds(10)

/// How a park ended.
enum ParkOutcome: Sendable, Equatable {

    /// The signal was sent: by the release the park was waiting for, or on its behalf by an
    /// earlier expiry on the same signal, whose latch is open.
    case signalled

    /// `ceiling` of scheduled waiting time passed first, and the park sent the signal itself.
    /// Carries what the poll spent, so the issue the double records can say it.
    case abandoned(StallTolerantWait.Expiry)

    /// Whether the signal was sent rather than the park abandoned.
    var wasSignalled: Bool { self == .signalled }
}

/// Where the timer leaves what it spent when it gives up, for the waiter to read once the signal
/// it sent has resumed it.
private actor AbandonedPark {

    private(set) var expiry: StallTolerantWait.Expiry?

    func abandon(after expiry: StallTolerantWait.Expiry) { self.expiry = expiry }
}

extension AsyncSignal {

    /// `wait()`, for at most `ceiling` of scheduled waiting time: a runner stall is not counted
    /// (``parkCeiling``).
    ///
    /// - Parameters:
    ///   - ceiling: the scheduled waiting time after which the wait gives up.
    ///   - clock: the time, and the sleeps. A test that must show a stall is not spent without
    ///     stopping a process passes one that can come back late; every other caller takes the
    ///     real one. There is one function and not a shipping forward over an injectable
    ///     overload, so the body the doubles run is the body the tests drive.
    /// - Returns: ``ParkOutcome/signalled`` when the signal was sent, and
    ///   ``ParkOutcome/abandoned(_:)`` when `ceiling` passed first, with what the poll spent. On
    ///   `abandoned` the signal has been sent on the waiter's behalf, so every waiter on it goes
    ///   on, and a later one does not park for another ceiling: the signal is a latch, and it is
    ///   open.
    /// - Throws: `CancellationError`, when the calling task is cancelled while it waits.
    ///
    /// The timer is `StallTolerantWait.poll` with a condition that never holds, so what counts as
    /// a stall, how it is added to the deadline and where it is capped are `waitUntil`'s and are
    /// not written a second time. It is a sleeping task, never a blocked thread. It sends the
    /// signal rather than cancelling the wait, because `wait()`'s cancellation handler resumes
    /// *every* waiter on the signal with `CancellationError`, which would turn one park's expiry
    /// into a thrown error in the others. The wait returning cancels the timer, which ends the
    /// poll's sleep.
    func wait(
        atMost ceiling: Duration, clock: some WaitClock = SystemWaitClock()
    ) async throws -> ParkOutcome {
        let gaveUp = AbandonedPark()
        let timer = Task {
            let outcome = try? await StallTolerantWait.poll(
                timeout: ceiling, interval: parkPollInterval, clock: clock
            ) { false }
            guard case .timedOut(let expiry) = outcome, !Task.isCancelled else { return }
            // Before the signal, so that a waiter the signal resumes finds it.
            await gaveUp.abandon(after: expiry)
            signal()
        }
        defer { timer.cancel() }
        try await wait()
        guard let expiry = await gaveUp.expiry else { return .signalled }
        return .abandoned(expiry)
    }
}

/// Records that `double` held a restore of `scope` and nobody let it through, saying what the
/// park spent: `expiry` is what ``AsyncSignal/wait(atMost:clock:)`` returned.
///
/// The time waited, the stall compensated and whether the cap ended the park are `waitUntil`'s
/// wording (`Expiry.message(waitingFor:)`), so a park and a wait that gave up read alike. It takes
/// the `Expiry` and not the ceiling the double was given, so a caller cannot print the constant:
/// after a stall that ceiling is not how long the park was held, or why it ended.
///
/// Called by the double itself, from inside the restore it held, so the issue lands on the test
/// whose task the restore runs under.
func recordAbandonedPark(
    by double: String, of scope: FanRestoreScope, after expiry: StallTolerantWait.Expiry,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(
        """
        \(double) held a restore of \(scope) and nobody let it through: \
        \(expiry.message(waitingFor: "its release")). That is a restore the test did not account \
        for, or a release it never made. It has gone on, so that the run ends red instead of \
        hanging.
        """,
        sourceLocation: sourceLocation)
}
