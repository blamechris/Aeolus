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
/// the longest return of any wait (3.62 s, the 150 ms wait at `ParkingCeilingTests.swift:92`);
/// both ratios are floored. Lowering it below 1.40 s would make legitimate parks expire, record an
/// issue and release mid-test.
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
/// `parkCeiling` is wall-clock time on the real `ContinuousClock`, because the virtual clock a
/// test moves by hand would have it expire at once. It is not scheduled waiting time as
/// `outwaitCeiling` now is (#547): a runner stall is spent from it, not added to it. Stopping the
/// test process for 15 s expired the parks held at that moment in `SleepGrantSealTests`,
/// `SleepCycleSurvivalTests` and `UnconfirmedHandbackTests`, and that is #549. Three expiries in a
/// row take 30 s of the parking suites' one-minute `.timeLimit`, so a test that hits it that often
/// still ends before the limit does.
let parkCeiling = Duration.seconds(10)

extension AsyncSignal {

    /// `wait()`, for at most `ceiling` of wall-clock time.
    ///
    /// - Returns: `true` when the signal was sent, `false` when `ceiling` passed first. On `false`
    ///   the signal has been sent on the waiter's behalf, so every waiter on it goes on, and a
    ///   later one does not park for another ceiling: the signal is a latch, and it is open.
    ///
    /// The timer is a sleeping task, never a blocked thread. It sends the signal rather than
    /// cancelling the wait, because `wait()`'s cancellation handler resumes *every* waiter on the
    /// signal with `CancellationError`, which would turn one park's expiry into a thrown error in
    /// the others.
    func wait(atMost ceiling: Duration) async throws -> Bool {
        let expired = CompletionFlag()
        let timer = Task {
            try? await Task.sleep(for: ceiling)
            guard !Task.isCancelled else { return }
            await expired.mark()
            signal()
        }
        defer { timer.cancel() }
        try await wait()
        return await !expired.isSet
    }
}

/// Records that `double` held a restore of `scope` for `ceiling` and nobody let it through.
///
/// Called by the double itself, from inside the restore it held, so the issue lands on the test
/// whose task the restore runs under.
func recordAbandonedPark(
    by double: String, of scope: FanRestoreScope, after ceiling: Duration,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(
        """
        \(double) held a restore of \(scope) for \(ceiling) and nobody let it through: a restore \
        the test did not account for, or a release it never made. It has gone on, so that the run \
        ends red instead of hanging.
        """,
        sourceLocation: sourceLocation)
}
