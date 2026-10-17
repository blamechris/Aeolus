import Foundation
import Testing

/// The shared `waitUntil` counts time the waiter ran, not time that passed
/// ([#341](https://github.com/blamechris/Aeolus/issues/341)).
///
/// Every test here runs on a `VirtualWaitClock`, so a 27 s runner stall costs microseconds and
/// nothing blocks a cooperative-pool thread. That is the reason it is a virtual clock and not
/// a `kill -STOP` of the test process: the stop is how the behaviour was shown end to end, and
/// a unit test that depended on it would be the same flake as the one it replaces.
///
/// `.timeLimit` is the backstop for the ceiling test: a poll whose cap were removed *and* whose
/// compensation never drained would loop on virtual time for ever, and a suite that hangs is
/// worse than one that goes red.
@Suite("The shared wait counts only time the waiter ran", .timeLimit(.minutes(1)))
struct StallTolerantWaitTests {

    // MARK: - A stall

    /// A condition that only comes true after a stall longer than the whole budget passes,
    /// and records nothing.
    ///
    /// The stall lands on the third sleep and lasts 27.3 s against a 5 s budget; the condition
    /// needs two polls after it. A wait that spent the stall would give up at the third sleep
    /// and fail on the final check.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, change `stall += overrun` to
    /// `_ = overrun`, so a late poll is never added to the deadline. Run: red, with
    /// "timed out after 27.3 s of waiting (plus 0.0 s of runner stall compensated)".
    @Test("A stall longer than the whole budget is not spent from it")
    func aStallIsCompensated() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(27_300) : .zero })

        try await waitUntil("an event the stall delayed", clock: clock) {
            await clock.sleeps >= 5
        }

        #expect(await clock.sleeps == 5, "the wait went on past the stall rather than ending in it")
        #expect(await clock.elapsed > .seconds(27), "the stall really happened on the clock")
    }

    /// The same, when the process was stopped while the condition was being evaluated rather
    /// than while it slept. Half of a descheduled process's wall time is not the sleeper's.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, measure the overrun from the instant before
    /// the sleep instead of from `mark` — `let overrun = (woke - mark) - interval` becomes a
    /// measurement of the sleep alone. Run: red.
    @Test("A stall that lands inside the condition is compensated too")
    func aStallInsideTheConditionIsCompensated() async throws {
        let clock = VirtualWaitClock()

        try await waitUntil("an event the stall delayed", clock: clock) {
            await clock.stall(for: .seconds(30), atSleep: 2)
            return await clock.sleeps >= 5
        }

        #expect(await clock.sleeps == 5)
        #expect(await clock.elapsed > .seconds(30))
    }

    /// A stall is named in the failure, with the arithmetic that makes it add up: the budget
    /// that was waited, and the stall on top of it. This is what lets someone reading a red CI
    /// run tell the runner from the client.
    @Test("A timeout after a stall says how much stall it compensated")
    func aTimeoutAfterAStallSaysSo() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(27_300) : .zero })

        try await expectTimeout(
            saying: "timed out after 5.0 s of waiting (plus 27.3 s of runner stall compensated)",
            "for: a condition that never holds"
        ) {
            try await waitUntil("a condition that never holds", clock: clock) { false }
        }
    }

    // MARK: - A real timeout

    /// A condition that never holds is still a failure, after the budget it asked for, and the
    /// figure for stall is zero — a failure with nothing to excuse it.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, return `.held` where it returns `.timedOut`.
    /// Run: red — "Known issue was not recorded".
    @Test("A condition that never holds still times out, with no stall to report")
    func aRealTimeoutIsStillATimeout() async throws {
        let clock = VirtualWaitClock()

        try await expectTimeout(
            saying: "timed out after 5.0 s of waiting (plus 0.0 s of runner stall compensated)",
            "for: a condition that never holds"
        ) {
            try await waitUntil("a condition that never holds", clock: clock) { false }
        }

        let elapsed = await clock.elapsed
        #expect(elapsed >= .seconds(5), "the wait gave up before its budget was spent")
        #expect(elapsed < .seconds(6), "the wait ran past its budget with nothing to excuse it")
    }

    /// Lateness up to the threshold is ordinary slowness and keeps costing budget. Exactly the
    /// threshold, because that is where `>` and `>=` part, and the budget is the thing a wait
    /// that is merely slow must still run out of.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, change `overrun > threshold` to
    /// `overrun >= threshold`, or drop the comparison altogether. Run: red — the wait is
    /// extended to the ceiling instead of ending at its budget.
    @Test("Lateness at the threshold is slowness, not a stall")
    func latenessAtTheThresholdIsNotAStall() async throws {
        let clock = VirtualWaitClock(lateness: { _ in StallTolerantWait.stallThreshold })

        try await expectTimeout(
            saying: "(plus 0.0 s of runner stall compensated)", "for: a slow condition"
        ) {
            try await waitUntil("a slow condition", clock: clock) { false }
        }

        #expect(await clock.elapsed < .seconds(6))
    }

    // MARK: - The final check

    /// A condition that becomes true during the very sleep that ends the budget passes.
    ///
    /// The condition turns true when one second has passed on the clock, and the budget is one
    /// second: the last sleep lands exactly on the deadline, the loop leaves, and only the
    /// final evaluation sees it.
    ///
    /// **Mutation:** delete the `if await condition() { return .held }` after the loop in
    /// `StallTolerantWait.poll`. Run: red — "timed out after 1.0 s of waiting".
    @Test("A condition that becomes true at the deadline passes")
    func theFinalCheck() async throws {
        let clock = VirtualWaitClock()

        try await waitUntil(
            "a condition that held at the deadline", timeout: .seconds(1), clock: clock
        ) {
            await clock.elapsed >= .seconds(1)
        }
    }

    // MARK: - The ceiling

    /// Compensation that never stops is stopped, and says it was.
    ///
    /// Every sleep is 10 s late, so the stall grows as fast as the clock does and the budget
    /// drains by only the 10 ms interval per poll — 500 polls, and 5000 s of virtual time, to
    /// give up on the budget alone. The ceiling ends it at 50 s.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, delete `wall >= ceiling ||` from the loop's
    /// exit. Run: red — no "cap hit", and an elapsed time of 5005 s. With the compensation also
    /// made to count the interval (`stall += overrun + interval`) the loop would never end at
    /// all, and it is this suite's `.timeLimit` that bounds it.
    @Test("Endless stall compensation stops at the ceiling and says cap hit")
    func theCeiling() async throws {
        let clock = VirtualWaitClock(lateness: { _ in .seconds(10) })

        try await expectTimeout(
            saying: "(cap hit)", "for: a condition that never holds"
        ) {
            try await waitUntil("a condition that never holds", clock: clock) { false }
        }

        let elapsed = await clock.elapsed
        #expect(elapsed >= StallTolerantWait.ceiling)
        #expect(
            elapsed < StallTolerantWait.ceiling + .seconds(11),
            "one poll in flight can overrun the ceiling by the stall it measures, and no more")
    }

    /// The ceiling is below the smallest `.timeLimit` there is.
    ///
    /// `TimeLimitTrait` is expressed in minutes, so a minute is the least any suite can be
    /// given. A ceiling at or above it would let the suite's limit fire first, with a message
    /// that does not say a wait was still stretching for a stall.
    ///
    /// **Mutation:** change `StallTolerantWait.ceiling` to `.seconds(120)`. Run: red.
    @Test("The ceiling is inside the shortest suite time limit")
    func theCeilingIsInsideTheShortestTimeLimit() {
        #expect(StallTolerantWait.ceiling < .seconds(60))
    }

    // MARK: - Cancellation

    /// A cancelled wait ends with the cancellation. It is how a wait inside a test whose
    /// `.timeLimit` expired stops, instead of going on to its own ceiling — and it must not
    /// be reported as a timeout, which it is not.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, change `try await clock.sleep(for: interval)`
    /// to `try? await clock.sleep(for: interval)`. Run: red.
    @Test("A cancelled wait ends with the cancellation and records nothing")
    func cancellationEndsTheWait() async {
        let clock = VirtualWaitClock()

        let wait = Task {
            try await waitUntil("a condition that never holds", clock: clock) { false }
        }
        wait.cancel()
        let result = await wait.result

        guard case .failure(let error) = result else {
            Issue.record("a cancelled wait returned as though its condition had held")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: - The shipping entry point

    /// `waitUntil(_:timeout:interval:_:)` — the one every suite calls — is this poll on the real
    /// clock. A real, short wait, so the entry point is not asserted by nothing: twelve tests
    /// of the injectable overload would pass with the shipping one a no-op.
    @Test("The shipping waitUntil returns when its condition comes true")
    func theShippingWaitReturns() async throws {
        let flag = CompletionFlag()
        let setter = Task {
            try await Task.sleep(for: .milliseconds(30))
            await flag.mark()
        }

        try await waitUntil("the flag was set") { await flag.isSet }

        try await setter.value
    }

    /// **Mutation:** replace the body of the shipping `waitUntil` in
    /// `AnonymousListenerTests.swift` with `return`. Run: red — "Known issue was not recorded".
    @Test("The shipping waitUntil records a timeout, and says how much stall it compensated")
    func theShippingWaitTimesOut() async throws {
        try await expectTimeout(
            saying: "timed out after", "of runner stall compensated) for: never holds"
        ) {
            try await waitUntil("never holds", timeout: .milliseconds(50)) { false }
        }
    }

    // MARK: - Support

    /// Expects exactly one issue, whose text holds every fragment.
    ///
    /// An issue that does not match is not "known": it fails the test as itself, so a wrong
    /// message reads as a wrong message and not as a missing one.
    private func expectTimeout(
        saying fragments: String...,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async throws {
        try await withKnownIssue(sourceLocation: sourceLocation) {
            try await body()
        } matching: { issue in
            fragments.allSatisfy { fragment in
                issue.comments.contains { $0.rawValue.contains(fragment) }
            }
        }
    }
}

/// A clock the test moves, whose sleeps can come back late.
///
/// Late is the whole point: `TestClock` jumps to the deadline it is asked for, so it cannot
/// show a poll a sleep that took longer than it was told to. This one advances by the interval
/// **plus** what `lateness` says that sleep (numbered from 1) was delayed by. Nothing here
/// sleeps for real, so a 27 s stall costs microseconds and no cooperative-pool thread is ever
/// blocked.
///
/// An `actor`, as the `WaitClock` members are `async` to allow. It yields once per sleep so a
/// poll driven by it still gives other tasks a chance to run, and so a suite `.timeLimit` can
/// land on a poll that has stopped making progress.
actor VirtualWaitClock: WaitClock {

    private let origin: ContinuousClock.Instant
    private var instant: ContinuousClock.Instant
    private let lateness: @Sendable (Int) -> Duration
    private var stalledAt: Set<Int> = []

    /// How many sleeps have been asked for.
    private(set) var sleeps = 0

    init(
        start: ContinuousClock.Instant = ContinuousClock.now,
        lateness: @escaping @Sendable (Int) -> Duration = { _ in .zero }
    ) {
        origin = start
        instant = start
        self.lateness = lateness
    }

    /// How far the clock has moved.
    var elapsed: Duration { instant - origin }

    func now() -> ContinuousClock.Instant { instant }

    func sleep(for interval: Duration) async throws {
        sleeps += 1
        instant = instant.advanced(by: interval + lateness(sleeps))
        await Task.yield()
        // After the advance, so a wait that swallowed the cancellation would still move
        // on the clock and end by its budget rather than spin where it stood.
        try Task.checkCancellation()
    }

    /// Stops the process for `duration`, once, when exactly `count` sleeps have been asked
    /// for — the stall landing in whatever runs between two polls, which is the condition.
    func stall(for duration: Duration, atSleep count: Int) {
        guard sleeps == count, stalledAt.insert(count).inserted else { return }
        instant = instant.advanced(by: duration)
    }
}
