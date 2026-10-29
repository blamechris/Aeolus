import Foundation
import Testing

@testable import AeolusHelper

/// The two outwaits every test calls are the stall-tolerant ones
/// ([#551](https://github.com/blamechris/Aeolus/issues/551)).
///
/// `OutwaitStallToleranceTests` drives the injectable `clock:` overloads, and the ~45 call sites
/// call the shipping forwards, `revocationProgress(of:outwaiting:in:)` and
/// `finishedBeforeCeiling(_:_:)`. A forward that went back to the wall-clock loops of
/// `9b1bfda^` left all 1559 tests of `AeolusHelperTests` green. These tests call the shipping
/// entry points, on the real clock, each for the one thing the old loop did not do.
///
/// Neither costs a stall: what a stall does to a wait is the other suite's, on a clock that can be
/// late. These are real waits, so each is bounded by what it asserts and not by a stopwatch.
@Suite("The shipping outwaits are the stall-tolerant ones", .timeLimit(.minutes(1)))
struct ShippingOutwaitTests {

    /// A cancelled shipping `revocationProgress` ends with the cancellation, and records nothing.
    ///
    /// The old wait was a `Task.yield` spin on the wall clock, which ignores cancellation: a
    /// suite whose `.timeLimit` expired cancelled the test and left the spin to run on for the
    /// whole of `outwaitCeiling`, spinning a pool thread, and then record an issue. The wait
    /// that ships sleeps, and `SystemWaitClock.sleep` propagates the cancellation.
    ///
    /// The task is cancelled at once, and the test needs no look at whether the wait had begun:
    /// before its first sleep the poll has only read two states, and the sleep it then asks for
    /// throws, so either order ends the same way. The work here never finishes and no revocation
    /// is parked, so nothing but the cancellation can end the wait before its 10 s.
    ///
    /// **Mutation (shipping `revocationProgress` reverted):** replace the body of
    /// `revocationProgress(of:outwaiting:in:sourceLocation:)` with the loop `9b1bfda^` had,
    /// keeping the `async throws` signature (read `fansARevocationAwaits`, `Task.yield()`, until
    /// `ContinuousClock.now` passes `outwaitCeiling`, then record "the revocation neither
    /// finished nor parked on fan 3 within 10.0 seconds"). Run: red, after the spin's 10 s, on
    /// "a cancelled shipping revocationProgress returned as though it had an answer", and on
    /// the spin's own issue.
    @Test("A cancelled shipping revocationProgress ends with the cancellation and records nothing")
    func cancellationEndsTheShippingRevocationProgress() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        let leases = LeaseFixture.authority()
        let wait = Task {
            try await revocationProgress(of: work, outwaiting: 3, in: leases)
        }
        wait.cancel()
        let result = await wait.result

        guard case .failure(let error) = result else {
            Issue.record(
                "a cancelled shipping revocationProgress returned as though it had an answer")
            return
        }
        #expect(error is CancellationError)
    }

    /// The shipping `finishedBeforeCeiling` gives up on work that never finishes after
    /// `outwaitCeiling` of waiting, and the issue says how much stall it compensated.
    ///
    /// That sentence is what separates the wait that ships from the wall-clock loop it replaced,
    /// which said "did not finish within 10.0 seconds" and had no stall to report. It costs the
    /// 10 s of waiting it asserts. The bound on the figure is on the **scheduled waiting time**
    /// the message gives, not on the wall clock, so a stop of the process in these seconds adds
    /// to the stall and takes nothing from it.
    ///
    /// **Mutation (shipping `finishedBeforeCeiling` reverted):** replace the body of
    /// `finishedBeforeCeiling(_:_:sourceLocation:)` with the loop `9b1bfda^` had (`deadline =
    /// ContinuousClock.now + outwaitCeiling`, `Task.sleep(for: .milliseconds(1))` while the flag
    /// is unset and the deadline has not passed, then record "\(description) did not finish
    /// within \(outwaitCeiling): something it awaits was never resumed" and return `nil`). Run:
    /// red, with the old text as an issue no fragment accepts, and "Known issue was not
    /// recorded".
    @Test("The shipping finishedBeforeCeiling gives up on stuck work, and says what it compensated")
    func theShippingFinishedBeforeCeilingTimesOut() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        var returned: Int? = -1

        try await expectTimeout(
            saying: "timed out after 10.",
            "of runner stall compensated) for: the stuck work to finish: "
                + "something it awaits was never resumed",
            waitedUnder: 11
        ) {
            returned = try await finishedBeforeCeiling("the stuck work", work)
        }

        #expect(
            returned == nil, "the outwait joined work whose flag was never set: \(returned as Any)")
    }
}
