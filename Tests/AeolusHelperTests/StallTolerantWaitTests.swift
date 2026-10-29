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
    /// **Mutation:** in `StallTolerantWait.poll`, change `granted += overrun` to
    /// `_ = overrun`, so a late poll is never added to the deadline. Run: red, with
    /// "timed out after 27.3 s of waiting (plus 0.0 s of runner stall compensated)".
    @Test("A stall longer than the whole budget is not spent from it")
    func aStallIsCompensated() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(27_300) : .zero })

        try await waitCollectingNotes("an event the stall delayed", on: clock) {
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

        try await waitCollectingNotes("an event the stall delayed", on: clock) {
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
    /// **Mutation:** in `StallTolerantWait.poll`, return `.held(…)` where it returns `.timedOut`.
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
    /// **Mutation:** delete the `if await condition() { return .held(…) }` after the loop in
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
    /// made to count the interval (`granted += overrun + interval`) the loop would never end at
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

    /// The backstop the one-minute suites fail at leaves their client room to report before the
    /// limit ([#589](https://github.com/blamechris/Aeolus/issues/589)).
    ///
    /// `FanctlResetCorruptedStateTests` and `FanctlAutoUnreadModeTests` carry
    /// `.timeLimit(.minutes(1))`, as do the client suites. Each counts its deadlines on a harness
    /// clock only the test moves (#421, #583), so a request nothing answers does not fail when its
    /// deadline's figure has passed. It fails when `ClockBackstop` runs the deadline out,
    /// `ClockBackstop.defaultBudget` of scheduled waiting time into the harness's life. The
    /// client's own "did not confirm" must surface before the limit fires with a message that says
    /// nothing about why (#443), which is two relations:
    ///
    /// - **The budget is under the ceiling.** The backstop waits through `StallTolerantWait`, so
    ///   a stall is added to the budget until the wait reaches `ceiling`, and ends there whatever
    ///   it has compensated. A budget at or over the ceiling is a budget no stall can extend.
    /// - **The ceiling leaves `margin` under the limit.** That is the latest the backstop fires,
    ///   and the client reports once it has. The limit is restated here and not read, as above: a
    ///   suite's trait cannot be read at run time.
    ///
    /// **The margin is 5 s.** With the harness dropping the panic request, the client's "did not
    /// confirm" came 0.04 s after the backstop fired (30.037 to 30.041 s a test, two tests in each
    /// of two runs, at a load average of 15). So the margin is over a hundred times what it took,
    /// and half of the 10 s the ceiling leaves.
    ///
    /// **What this replaces.** The guard held `FanctlResetTests.unhurried`'s deadlines and a 30 s
    /// margin under 60 s, which named a 10 s that decides nothing for these suites: it is only
    /// what the client reports. Moved to the backstop, 30 s plus that margin is not under 60 s, so
    /// the margin is derived again (above) and not carried.
    ///
    /// **Mutation:** set `ClockBackstop.defaultBudget` to `.seconds(55)`. Run: red on the first
    /// expectation, the budget at or over the ceiling.
    /// **Mutation:** set `StallTolerantWait.ceiling` to `.seconds(56)`. Run: red on the second,
    /// while `theCeilingIsInsideTheShortestTimeLimit` stays green.
    @Test("The backstop the one-minute suites fail at leaves their client room to report")
    func theOneMinuteSuitesBackstopFitsInsideTheirTimeLimit() {
        let margin = Duration.seconds(5)
        let budget = ClockBackstop.defaultBudget
        #expect(
            budget < StallTolerantWait.ceiling,
            """
            the backstop fires after \(budget) of scheduled time, and a wait is ended at \
            \(StallTolerantWait.ceiling) of wall time whatever it has compensated, so no stall \
            can extend it
            """)
        #expect(
            StallTolerantWait.ceiling + margin < .seconds(60),
            """
            a backstop ended at the ceiling of \(StallTolerantWait.ceiling) leaves its client \
            less than \(margin) to report before a one-minute limit
            """)
    }

    /// What a setup wait on a delivery is given reaches past the delivery it was missed by, and
    /// stops inside the backstop and the ceiling ([#592](https://github.com/blamechris/Aeolus/issues/592)).
    ///
    /// Three relations, each of which a plausible edit breaks:
    ///
    /// - **Over twice the longest wait missed.** On `5034c41` (run 40946892305) the longest setup
    ///   wait to give up had spent 5.0 s and had 7.5 s of stall compensated. A budget under twice
    ///   that is a budget the next slow run also misses. The 5.0 and 7.5 are restated, since they
    ///   are a measurement and no constant of the target.
    /// - **Not over the backstop.** `ClockBackstop` runs every deadline of a harness out once it
    ///   has lived `ClockBackstop.defaultBudget`. A delivery wait longer than that would still be
    ///   waiting for a message after the client had been told its call timed out, and the failure
    ///   would name the timeout and not the missing delivery.
    /// - **Under the ceiling.** A wait ends at the ceiling whatever it has compensated, so a
    ///   budget at or over it is one no stall can extend, and the ceiling is itself held under a
    ///   minute above.
    ///
    /// **Mutation:** set `StallTolerantWait.deliveryBudget` to `.seconds(20)`. Run: red on the
    /// first expectation only.
    /// **Mutation:** set it to `.seconds(31)`. Run: red on the second only.
    /// **Mutation:** set it to `.seconds(55)`. Run: red on the second and third.
    @Test("A delivery wait reaches past the delivery it was missed by and fits the backstop")
    func aDeliveryWaitFitsInsideTheBackstopAndTheTimeLimit() {
        let budget = StallTolerantWait.deliveryBudget
        let longestMissed = Duration.seconds(5) + .seconds(7.5)
        #expect(
            budget >= longestMissed * 2,
            """
            a delivery wait of \(budget) is under twice the \(longestMissed) the longest setup \
            wait on 5034c41 had spent when it gave up
            """)
        #expect(
            budget <= ClockBackstop.defaultBudget,
            """
            a delivery wait of \(budget) outlasts the backstop's \(ClockBackstop.defaultBudget), \
            so a missing delivery would be reported after the client had been told its call \
            timed out
            """)
        #expect(
            budget < StallTolerantWait.ceiling,
            "a delivery wait of \(budget) is ended by the ceiling of \(StallTolerantWait.ceiling)")
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

    /// `waitUntil(_:timeout:interval:budget:_:)` — the one every suite calls — is this poll on the
    /// real clock. A real, short wait, so the entry point is not asserted by nothing: every test
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

    /// The caller's `timeout:` is the one the shipping wait runs under.
    ///
    /// The bound is on the **scheduled waiting time the message reports**, not on the wall
    /// clock of this test: a stop of the whole process during these 50 ms adds to the wall time
    /// and to the stall figure, and takes nothing from the figure asserted here, so the test
    /// cannot fail for the runner it exists to tolerate.
    ///
    /// **Mutations.**
    /// - Replace the body of the shipping `waitUntil` in `AnonymousListenerTests.swift` with
    ///   `return`. Run: red — "Known issue was not recorded".
    /// - **X11:** in the same body, pass `timeout: .seconds(5)` where it passes `timeout`, so
    ///   the shipping wait ignores the caller's. Run: red — the wait takes 5 s and reports
    ///   "timed out after 5.0 s of waiting", which no fragment accepts.
    @Test("The shipping waitUntil records a timeout, and says how much stall it compensated")
    func theShippingWaitTimesOut() async throws {
        try await expectTimeout(
            saying: "timed out after", "of runner stall compensated) for: never holds",
            waitedUnder: 1
        ) {
            try await waitUntil("never holds", timeout: .milliseconds(50)) { false }
        }
    }

    /// A cancelled shipping wait ends with the cancellation, and records nothing.
    ///
    /// `cancellationEndsTheWait` pins this on the virtual clock, whose `sleep` is the double's
    /// own. `SystemWaitClock.sleep` is another function, and the only one that runs in a suite
    /// whose `.timeLimit` expires: it has to propagate the cancellation by itself. A wait that
    /// swallowed it would carry on to its own timeout and record one; the 2 s is that
    /// timeout, so the test is bounded without a stopwatch on the wall clock.
    ///
    /// **Mutation (X16):** in `SystemWaitClock.sleep`, `try?` the
    /// `ContinuousClock().sleep(for:)`. Run: red — the wait returns normally after spinning
    /// to its timeout, and records one.
    @Test("A cancelled shipping wait ends with the cancellation and records nothing")
    func cancellationEndsTheShippingWait() async throws {
        let began = CompletionFlag()
        let wait = Task {
            try await waitUntil("a condition that never holds", timeout: .seconds(2)) {
                await began.mark()
                return false
            }
        }
        try await waitUntil("the wait began") { await began.isSet }
        wait.cancel()
        let result = await wait.result

        guard case .failure(let error) = result else {
            Issue.record("a cancelled shipping wait returned as though its condition had held")
            return
        }
        #expect(error is CancellationError)
    }
}
