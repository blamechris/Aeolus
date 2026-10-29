import Foundation
import Testing

@testable import AeolusHelper

/// The outwaits on their default clock end with a cancellation
/// ([#551](https://github.com/blamechris/Aeolus/issues/551)).
///
/// `revocationProgress` and `finishedBeforeCeiling` are one function each, with the real clock as
/// the default for `clock:`, so `OutwaitStallToleranceTests` drives the body the ~45 call sites
/// run and a reversion of either to the wall-clock loops of `9b1bfda^` turns it red. What it
/// cannot show is what only the real clock does, which is this suite's: `SystemWaitClock.sleep`
/// has to propagate a cancellation by itself, where the virtual clock's own `sleep` throws.
@Suite("The outwaits on their default clock", .timeLimit(.minutes(1)))
struct ShippingOutwaitTests {

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
    /// throws, so either order ends the same way. The work here never finishes and no revocation
    /// is parked, so nothing but the cancellation can end the wait before its 10 s. The test
    /// costs milliseconds.
    ///
    /// **Mutation (`revocationProgress` reverted):** replace the body of `revocationProgress`
    /// with the loop `9b1bfda^` had, keeping the signature (read `fansARevocationAwaits`,
    /// `Task.yield()`, until `ContinuousClock.now` passes `outwaitCeiling`, then record "the
    /// revocation neither finished nor parked on fan 3 within 10.0 seconds"). Run: red, after
    /// the spin's 10 s, on "a cancelled revocationProgress returned as though it had an answer",
    /// and on the spin's own issue.
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
}
