import Foundation
import Testing

@testable import AeolusHelper

/// The two outwaits do not spend a runner stall
/// ([#547](https://github.com/blamechris/Aeolus/issues/547)), and still give up on work that is
/// stuck.
///
/// `finishedBeforeCeiling` and `revocationProgress` used to measure `outwaitCeiling` on the wall
/// clock, so a test process stopped for longer than that failed every wait in flight at once —
/// five `ParkingCeilingTests` in two CI runs, whose doubles had done nothing wrong. They are
/// `waitUntil` now. Each test here runs it on a `VirtualWaitClock`, for the reason
/// `StallTolerantWaitTests` gives: a 30 s stall costs microseconds and blocks no thread, where the
/// `kill -STOP` that showed the fix end to end would be the same flake as the one it replaces.
///
/// The work in each is `ObservableWork` whose flag the clock sets at a sleep the test chose, and
/// not a task the scheduler finishes whenever it likes, so the order of "the stall, then the work
/// finishing" is the clock's and cannot vary between runs.
@Suite("The outwaits do not spend a runner stall", .timeLimit(.minutes(1)))
struct OutwaitStallToleranceTests {

    /// The stall: 30 s, which is longer than the whole of `outwaitCeiling` and shorter than the
    /// 50 s cap `StallTolerantWait` puts on a wait, on the third sleep.
    private static func stalled() -> VirtualWaitClock {
        VirtualWaitClock(lateness: { $0 == 3 ? .seconds(30) : .zero })
    }

    // MARK: - A stall

    /// Work that finishes only after a stall longer than the whole budget is waited for, and its
    /// value returned, with nothing recorded.
    ///
    /// The stall lands on the third sleep; the work finishes on the fifth. An outwait that spent
    /// the stall would give up at the third sleep and fail on its final look.
    ///
    /// **Mutation:** in `outwait`, pass `budget: .wallTime` to `waitUntil`, so a late poll is
    /// spent from the budget and not added to it. Run: red, with "timed out after 30.0 s of
    /// waiting (wall-clock bound: 30.0 s of runner stall seen, not compensated)".
    @Test("finishedBeforeCeiling waits out a stall longer than its whole budget")
    func finishedBeforeCeilingWaitsOutAStall() async throws {
        let base = Self.stalled()
        let flag = CompletionFlag()
        let work = ObservableWork(task: Task { 42 }, isFinished: flag)
        var notes: [String] = []

        let value = try await finishedBeforeCeiling(
            "the stalled work", work, clock: FinishingWaitClock(base, setting: flag, atSleep: 5),
            note: { notes.append($0) })

        #expect(value == 42, "the work finished after the stall and was not waited for")
        #expect(await base.elapsed > .seconds(30), "the stall really happened on the clock")
        #expect(notes.count == 1, "a wait that rode out 30 s of stall said nothing: \(notes)")
    }

    /// The same for the revocation poll, which is the other wait `outwaitCeiling` bounds.
    ///
    /// **Mutation:** the one above; both outwaits are held to `outwait`'s budget.
    @Test("revocationProgress waits out a stall longer than its whole budget")
    func revocationProgressWaitsOutAStall() async throws {
        let base = Self.stalled()
        let flag = CompletionFlag()
        let work = ObservableWork(task: Task { 42 }, isFinished: flag)
        var notes: [String] = []

        let progress = try await revocationProgress(
            of: work, outwaiting: 0, in: LeaseFixture.authority(),
            clock: FinishingWaitClock(base, setting: flag, atSleep: 5),
            note: { notes.append($0) })

        #expect(
            progress == .finished, "the revocation finished after the stall: \(progress as Any)")
        #expect(await base.elapsed > .seconds(30), "the stall really happened on the clock")
        #expect(notes.count == 1, "a wait that rode out 30 s of stall said nothing: \(notes)")
    }

    // MARK: - Work that is stuck

    /// Work whose flag is never set is given up on at `outwaitCeiling` of waiting, by name, and
    /// is **not joined** — the task here has a value, so a join would hand it back.
    ///
    /// **Mutation (1):** in `finishedBeforeCeiling`, delete `guard done else { return nil }`.
    /// Run: red on the returned value, which is 99 and not `nil`.
    /// **Mutation (2):** in `outwait`, pass `timeout: .seconds(30)`. Run: red, the message says
    /// 30.0 s and not 10.0 s.
    @Test("finishedBeforeCeiling gives up on work that never finishes, by name, without joining it")
    func finishedBeforeCeilingGivesUpOnStuckWork() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        var returned: Int? = -1

        try await expectTimeout(
            saying: "timed out after 10.0 s of waiting (plus 0.0 s of runner stall compensated)",
            "for: the wedged restore to finish: something it awaits was never resumed"
        ) {
            returned = try await finishedBeforeCeiling(
                "the wedged restore", work, clock: VirtualWaitClock())
        }

        #expect(
            returned == nil, "the outwait joined work whose flag was never set: \(returned as Any)")
    }

    /// A revocation that neither finishes nor parks is given up on at the same budget, by name
    /// and by fan, and the answer is `nil`.
    ///
    /// **Mutation:** the second above.
    @Test("revocationProgress gives up on a revocation that does neither, by name and fan")
    func revocationProgressGivesUpOnStuckWork() async throws {
        let work = ObservableWork(task: Task { 99 }, isFinished: CompletionFlag())
        var progress: RevocationProgress? = .finished

        try await expectTimeout(
            saying: "timed out after 10.0 s of waiting (plus 0.0 s of runner stall compensated)",
            "for: the revocation to finish or park on fan 3: it did neither"
        ) {
            progress = try await revocationProgress(
                of: work, outwaiting: 3, in: LeaseFixture.authority(), clock: VirtualWaitClock())
        }

        #expect(progress == nil, "a revocation that did neither was reported as \(progress as Any)")
    }
}

/// A `VirtualWaitClock` that marks `flag` once `count` sleeps have been asked for: the work an
/// outwait is for finishing at an instant the test chose on the clock, and not whenever the
/// scheduler gets to it.
struct FinishingWaitClock: WaitClock {

    private let base: VirtualWaitClock
    private let flag: CompletionFlag
    private let count: Int

    init(_ base: VirtualWaitClock, setting flag: CompletionFlag, atSleep count: Int) {
        self.base = base
        self.flag = flag
        self.count = count
    }

    func now() async -> ContinuousClock.Instant { await base.now() }

    func sleep(for interval: Duration) async throws {
        try await base.sleep(for: interval)
        if await base.sleeps >= count { await flag.mark() }
    }
}
