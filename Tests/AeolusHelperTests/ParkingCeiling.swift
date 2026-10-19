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
/// `SystemPowerTests.theAcknowledgementIsBoundedByItsBudget`). Measured over a whole clean run, the
/// longest legitimate park was 0.18 s, and 1.4 s with the CPU twice oversubscribed; so 5 s leaves
/// about 3.7 times the worst seen. Lowering it below those figures makes those parks expire,
/// record an issue and release mid-test. It is wall-clock time on the real `ContinuousClock`, as
/// `outwaitCeiling` is, because the virtual clock a test moves by hand would have it expire at
/// once. And it is well under the parking suites' one-minute `.timeLimit`, so a test that hits it
/// more than once still ends before the limit does.
let parkCeiling = Duration.seconds(5)

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
