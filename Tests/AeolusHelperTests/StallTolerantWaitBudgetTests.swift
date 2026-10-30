import Foundation
import Testing

/// The two ways a wait's `timeout:` can be kept, and the trace a pass leaves
/// ([#341](https://github.com/blamechris/Aeolus/issues/341)).
///
/// The companion of `StallTolerantWaitTests`, on the same `VirtualWaitClock`, for the part of
/// the wait that was added when review found that a stall-tolerant budget is wrong for a
/// `timeout:` that is a deadline, and silent about a pass that only passed because it was
/// given the stall back.
@Suite("The wait's wall-clock budget, and the note a pass leaves", .timeLimit(.minutes(1)))
struct StallTolerantWaitBudgetTests {

    // MARK: - A deadline, not a wait

    /// A wall-clock bound is spent by a stall, and the message says the stall was not
    /// compensated.
    ///
    /// The same 27.3 s stall `aStallIsCompensated` rides out ends this wait at the stall,
    /// because its five seconds are a deadline.
    ///
    /// **Mutation:** in `StallTolerantWait.poll`, delete the `if budget == .runTime` guard, so
    /// a `.wallTime` budget compensates too. Run: red — the wait carries on past the stall.
    @Test("A wall-clock bound is spent by a stall, and says it was not compensated")
    func aWallClockBoundIsSpentByAStall() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(27_300) : .zero })

        try await expectTimeout(
            saying: "timed out after 27.3 s of waiting",
            "(wall-clock bound: 27.3 s of runner stall seen, not compensated)",
            "for: a deadline the product is held to"
        ) {
            try await waitUntil(
                "a deadline the product is held to", timeout: .seconds(5), budget: .wallTime,
                clock: clock
            ) { await clock.sleeps >= 5 }
        }

        #expect(await clock.sleeps == 3, "the wait ended at the stall and did not go on past it")
    }

    /// The two lease-heartbeat waits are the wall-clock kind.
    ///
    /// Their `timeout:` is the deadline the lease contract gives a heartbeat, and a wait that
    /// compensates stretches it to the ceiling. Nothing but the call site says which they are,
    /// so this reads it: every `waitUntil` in that file that is given `heartbeatBudget` must
    /// also be given `budget: .wallTime`. The count is pinned so that renaming the constant
    /// fails here, loudly, instead of leaving a scan with nothing to find.
    ///
    /// **Mutation:** delete `, budget: .wallTime` from either call in
    /// `LeaseHeartbeatStarvationTests.swift`. Run: red, quoting the call.
    @Test("The lease heartbeat's two deadline waits are held to the wall clock")
    func theHeartbeatBudgetWaitsAreWallClock() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("LeaseHeartbeatStarvationTests.swift")
        let code = SeamScanner.strippingComments(try String(contentsOf: url, encoding: .utf8))

        var calls: [String] = []
        var cursor = code.startIndex
        while let found = code.range(of: "waitUntil(", range: cursor..<code.endIndex) {
            let open = code.index(before: found.upperBound)
            guard let close = SeamScanner.closingParenthesis(in: code, openingAt: open) else {
                break
            }
            calls.append(String(code[found.lowerBound...close]))
            cursor = close
        }
        let deadlines = calls.filter { $0.contains("heartbeatBudget") }

        #expect(
            deadlines.count == 2,
            "found \(deadlines.count) waits on heartbeatBudget, not the two this guard names")
        for call in deadlines {
            #expect(
                call.filter { !$0.isWhitespace }.contains("budget:.wallTime"),
                "a wait on the heartbeat deadline is not a wall-clock wait: \(call)")
        }
    }

    // MARK: - A pass that compensated

    /// A pass that compensated more than a second says so, because nothing else would.
    ///
    /// Compensation cannot tell a runner stall from a slow condition, so a condition that
    /// regressed from milliseconds to seconds would pass, silently, for as long as it stayed
    /// under the budget. The note is the only trace; it goes to a sink, which is standard
    /// error in the suites, and never to `Issue`, since the test passed.
    ///
    /// **Mutation:** change `where compensated > StallTolerantWait.noteThreshold` to
    /// `where false` in the injectable `waitUntil`. Run: red.
    @Test("A pass that compensated more than a second writes a note")
    func aPassThatCompensatedALotSaysSo() async throws {
        let clock = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(27_300) : .zero })

        let written = try await waitCollectingNotes("an event the stall delayed", on: clock) {
            await clock.sleeps >= 5
        }

        #expect(written.count == 1)
        let note = written.first ?? ""
        #expect(note.contains("compensating 27.3 s of runner stall"), "\(note)")
        #expect(note.contains("for: an event the stall delayed"), "\(note)")
        #expect(note.contains("the condition is slow"), "the trade-off was left out: \(note)")
    }

    /// A pass that compensated nothing, or a stall under a second, stays quiet.
    ///
    /// **Mutation:** change the same `where` to `where compensated > .zero`. Run: red — the
    /// 600 ms stall is noted.
    @Test("A pass with no stall, or a short one, writes nothing")
    func aPassWithoutAMaterialStallIsQuiet() async throws {
        let quiet = VirtualWaitClock()
        let short = VirtualWaitClock(lateness: { $0 == 3 ? .milliseconds(600) : .zero })

        let fromQuiet = try await waitCollectingNotes("no stall at all", on: quiet) {
            await quiet.sleeps >= 5
        }
        let fromShort = try await waitCollectingNotes("a short stall", on: short) {
            await short.sleeps >= 5
        }

        #expect(fromQuiet.isEmpty && fromShort.isEmpty, "\(fromQuiet + fromShort)")
    }

    // MARK: - A fanctl deadline on the wall clock

    /// `FanctlResetTests.unhurried` leaves a one-minute limit room, should it ever be counted on
    /// the wall clock ([#581](https://github.com/blamechris/Aeolus/issues/581), item 8).
    ///
    /// Nothing counts it there today: the suites that take it pass `.harness`, and a request
    /// nothing answers fails when `ClockBackstop` runs it out. `emitted(over:waiting:counting:)`
    /// has no default clock, so a caller that chose `.wall` would be deliberate, and this is what
    /// it would be held to. Each verb's deadline plus 30 s, the stall #439's CI runner showed
    /// before a suite's first request went out, stays under the 60 s of a one-minute limit
    /// (restated, as a suite's trait cannot be read). It is the guard
    /// `theOneMinuteSuitesBackstopFitsInsideTheirTimeLimit` replaced (#590), for the one
    /// configuration that replacement does not cover.
    ///
    /// **Mutation:** set `unhurried`'s `gatedVerb` to `.seconds(55)`. Run: red on the first
    /// expectation. **Mutation:** set its `panicVerb` to `.seconds(60)`. Run: red on the second.
    @Test("The fanctl suites' deadlines leave 30 s under a one-minute limit on the wall clock")
    func unhurriedFitsAOneMinuteLimitOnTheWallClock() {
        let unhurried = FanctlResetTests.unhurried
        let margin = Duration.seconds(30)
        #expect(unhurried.gatedVerb + margin < .seconds(60))
        #expect(unhurried.panicVerb + margin < .seconds(60))
    }
}
