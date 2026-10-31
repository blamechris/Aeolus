import Foundation
import Testing

@testable import AeolusHelper

/// The outwaits on their default clock end with a cancellation
/// ([#551](https://github.com/blamechris/Aeolus/issues/551),
/// [#562](https://github.com/blamechris/Aeolus/issues/562)).
///
/// `revocationProgress` and `finishedBeforeCeiling` are one function each, with the real clock as
/// the default for `clock:`, so `OutwaitStallToleranceTests` drives the body the ~45 call sites
/// run and a reversion of either to the wall-clock loops of `9b1bfda^` turns it red.
///
/// **What only this suite catches** is an outwait that swallows the error it is handed: the
/// `outwait` call in `revocationProgress` or in `finishedBeforeCeiling` written `try?` and not
/// `try`. A test cancelled by its suite's `.timeLimit` would then run on with `nil` and no issue.
/// No other test cancels an outwait: with either `try?` in place, the test here for that function
/// is the only red test in the whole target.
///
/// A `SystemWaitClock.sleep` that swallows the cancellation turns these red too, after the 10 s
/// the poll then spins, but it is not what this suite is for: `StallTolerantWaitTests` (X16) is
/// the test for it, and is red first, at 2 s. Each test here cancels at once and costs
/// milliseconds, because nothing but the cancellation can end the wait before its 10 s: the work
/// never finishes and no revocation is parked.
@Suite("The outwaits on their default clock", .timeLimit(.minutes(1)))
struct OutwaitsOnTheirDefaultClockTests {

    /// A cancelled `revocationProgress` on its default clock ends with the cancellation, and
    /// records nothing.
    ///
    /// The old wait was a `Task.yield` spin on the wall clock, which ignores cancellation: a
    /// suite whose `.timeLimit` expired cancelled the test and left the spin to run on for the
    /// whole of `outwaitCeiling`, spinning a pool thread, and then record an issue. The wait
    /// that ships sleeps, and `SystemWaitClock.sleep` propagates the cancellation.
    ///
    /// The task is cancelled at once, and the test needs no look at whether the wait had begun:
    /// before its first sleep the poll has only read two states, and the sleep it then asks for
    /// throws, so either order ends the same way.
    ///
    /// **Mutation (`revocationProgress` reverted):** replace the body of `revocationProgress`
    /// with the loop `9b1bfda^` had, keeping the signature (read `fansARevocationAwaits`,
    /// `Task.yield()`, until `ContinuousClock.now` passes `outwaitCeiling`, then record "the
    /// revocation neither finished nor parked on fan 3 within 10.0 seconds"). Run: red, after
    /// the spin's 10 s, on "a cancelled revocationProgress returned as though it had an answer",
    /// and on the spin's own issue.
    /// **Mutation (the error swallowed):** in `revocationProgress`, write the `outwait` call
    /// `try? await outwait(`. Run: red on the same message, at once.
    @Test("A cancelled revocationProgress ends with the cancellation and records nothing")
    func cancellationEndsRevocationProgress() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        let leases = LeaseFixture.authority()
        let wait = Task {
            try await revocationProgress(of: work, outwaiting: 3, in: leases)
        }
        wait.cancel()
        let result = await wait.result

        guard case .failure(let error) = result else {
            Issue.record("a cancelled revocationProgress returned as though it had an answer")
            return
        }
        #expect(error is CancellationError)
    }

    /// The same for `finishedBeforeCeiling`, whose doc says a `.timeLimit` cancels the poll.
    ///
    /// The work here has a value but its flag is never set, so the answer a swallowed
    /// cancellation would give is `nil` with nothing recorded: it is not joined, and no timeout
    /// has been reached to record.
    ///
    /// **Mutation:** in `finishedBeforeCeiling`, write the `outwait` call `try? await outwait(`.
    /// Run: red on "a cancelled finishedBeforeCeiling returned as though it had an answer", at
    /// once.
    @Test("A cancelled finishedBeforeCeiling ends with the cancellation and records nothing")
    func cancellationEndsFinishedBeforeCeiling() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        let wait = Task {
            try await finishedBeforeCeiling("work that never finishes", work)
        }
        wait.cancel()
        let result = await wait.result

        guard case .failure(let error) = result else {
            Issue.record("a cancelled finishedBeforeCeiling returned as though it had an answer")
            return
        }
        #expect(error is CancellationError)
    }
}
