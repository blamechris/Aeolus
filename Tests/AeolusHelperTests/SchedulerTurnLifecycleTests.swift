import SMCCore
import Testing

@testable import AeolusHelper

/// What happens to a turn when a read ends badly, and the one property every other
/// scheduler test silently assumes.
///
/// Split from `SMCReadSchedulerTests` to keep both files under the 400-line lint threshold.
/// The seam is a real one rather than an arbitrary cut: that suite is about **who goes
/// next**, and this one is about **whether the connection comes back at all** — the
/// difference between a safety cycle that is late and a helper that has stopped reading the
/// SMC for the life of the process.
///
/// Every test here exists because a review panel showed the property had no coverage: the
/// `defer` releasing a throwing read, and mutual exclusion itself, were each asserted by a
/// comment and by nothing else, and mutating either left the whole 896-test suite green.
///
/// `.timeLimit` for `SMCReadSchedulerTests`'s reason: a scheduler that stops granting turns
/// makes a task join hang, and a green suite must mean the tests ran.
@Suite("SMC read scheduling — turn lifecycle", .timeLimit(.minutes(1)))
struct SchedulerTurnLifecycleTests {

    private static func snapshotKeys(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    /// The one invariant in `SMCReadScheduler` whose failure is unrecoverable, and until
    /// this test the only thing asserting it was the comment above `defer { endTurn() }`.
    ///
    /// A turn taken and not given back wedges the helper's **only** SMC reader for the life
    /// of the process. Waiting at the gate is deliberately not cancellable, so every later
    /// read — the 1 Hz snapshot and every safety cycle — parks in `takeTurn` and never
    /// resumes. No throw, no error reply, no log line: the invisible-failure shape #127 was
    /// filed against, one level down, with `SAFETY.md` § 3 permanently blind rather than
    /// 0.5 s late.
    ///
    /// **Mutation:** hoist `endTurn()` out of the `defer` in `read(keys:at:)` and call it
    /// after the `for` loop, so a throw skips it. That is the single most likely refactor of
    /// that line. Run: **all 896 tests pass** without this one — that is what the review
    /// panel measured, three consecutive runs, hardware suite included. With this test the
    /// mutation is red.
    @Test("A read that throws still gives the connection back")
    func aThrowingReadReleasesItsTurn() async throws {
        let provider = ThrowOnceProvider()
        let scheduler = SMCReadScheduler(provider: provider)

        await #expect(throws: (any Error).self) {
            try await scheduler.read(keys: ["TPD0"], at: .supervisor)
        }

        // The turn must be free. Asserted by taking one, not by inspecting a flag: a flag
        // says what the scheduler believes, and a served read says what a caller gets.
        //
        // Started observably rather than awaited directly, because under the mutation this
        // test exists for the read never returns at all — and a bare `await` on it would
        // hang the suite for the whole `.timeLimit` instead of failing in milliseconds.
        let follow = observing { try await scheduler.read(keys: ["TPD1"], at: .supervisor) }
        let served = try await finished("the read issued after a throwing one", follow)

        #expect(served?.map(\.key) == ["TPD1"])
        #expect(await provider.requests == 2)
    }

    /// A throw part-way through a multi-turn read releases the turn too — the `defer` has to
    /// hold whether the turn came from `takeTurn` or from the last `yieldTurn`, and those
    /// are different code paths.
    @Test("A throw part-way through a multi-turn read releases the turn as well")
    func aThrowMidwayThroughAMultiTurnReadReleasesItsTurn() async throws {
        // Answers turn 1, throws on turn 2 of 3, answers everything after — so the read
        // below is testing the turn's release and not the provider's mood.
        let provider = ThrowOnLaterTurnProvider(failingTurn: 2)
        let scheduler = SMCReadScheduler(provider: provider)

        await #expect(throws: (any Error).self) {
            try await scheduler.read(
                keys: Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 3), at: .snapshot)
        }

        let follow = observing { try await scheduler.read(keys: ["TPD1"], at: .supervisor) }
        let served = try await finished("the read issued after a mid-read throw", follow)

        #expect(served?.map(\.key) == ["TPD1"])
        #expect(await provider.requests == 3, "turn 3 of the multi-turn read must not run")
    }

    // MARK: - Mutual exclusion

    /// Mutual exclusion, scripted at the one instant it can actually break.
    ///
    /// Deleting `isTurnInFlight = true` from `admitNext()` — the window `takeTurn`'s own
    /// comment warns about — leaves the flag `false` while a resumed waiter is on its way to
    /// the provider. That alone is harmless: the damage needs a **fresh arrival** during
    /// that window, and only when both queues are empty, because `takeTurn`'s fast path
    /// tests the queues too. A caller that arrives to a non-empty queue enqueues and nothing
    /// overlaps.
    ///
    /// So the sequence below is exact: one turn held at the provider, exactly one waiter
    /// behind it, the held turn released so that waiter is admitted and both queues drain,
    /// and only then a third read issued. Under the mutation the third read finds
    /// `isTurnInFlight == false` and both queues empty, barges straight past the waiter that
    /// is still inside the provider, and two turns are live at once.
    ///
    /// `soakedConcurrentReadsNeverOverlap` below does *not* catch it, and neither did this
    /// test in its first form: both start every task up front, so there is never a fresh
    /// arrival at the moment the queue empties. That is the whole lesson — a concurrency
    /// test that starts all its work at once cannot see a bug that needs work to *arrive*.
    ///
    /// **Mutation:** delete `isTurnInFlight = true` from `admitNext()`. Run: three issues
    /// here — the fresh arrival never queues, `peakConcurrentTurns` reaches 2, and a third
    /// turn reaches the provider early — and green everywhere else in the repository.
    @Test("A read arriving as the queue empties cannot barge onto a held turn")
    func aFreshArrivalCannotBargeOntoAHeldTurn() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)

        let held = observing { try await scheduler.read(keys: ["A0"], at: .snapshot) }
        await yieldUntil("the first turn to reach the provider") {
            await provider.turns.count == 1
        }

        let waiter = observing { try await scheduler.read(keys: ["B0"], at: .snapshot) }
        await yieldUntil("the second read to queue behind it") {
            await scheduler.queuedTurns(at: .snapshot) == 1
        }

        // The first turn ends; the waiter is admitted and both queues drain. This is the
        // only instant at which the mutation is reachable.
        await provider.releaseOneTurn()
        await yieldUntil("the waiter to take the connection") {
            await provider.turns.count == 2
        }

        // The fresh arrival. It must queue, not barge.
        let arrival = observing { try await scheduler.read(keys: ["C0"], at: .snapshot) }
        await yieldUntil("the fresh arrival to queue behind the held turn") {
            await scheduler.queuedTurns(at: .snapshot) == 1
        }

        #expect(
            await provider.peakConcurrentTurns == 1,
            "a read barged onto a turn that was still held; mutual exclusion is broken")
        #expect(await provider.turns.count == 2, "a third turn reached the provider early")

        await provider.releaseEveryTurn()
        try await finished("the held read", held)
        try await finished("the queued read", waiter)
        try await finished("the read that arrived last", arrival)
    }

    /// The same property under undirected load, as a soak.
    ///
    /// **This test could not fail for its first two commits**, and the reason is worth more
    /// than the test is. It built the double with `GatedSensorProvider()` — not holding — so
    /// `hold()` returned at its first line without suspending. `read(keys:)` then ran
    /// `concurrentTurns += 1`, the `max`, and `concurrentTurns -= 1` in one actor-isolated
    /// step with no suspension point in it, and an actor serialises its own calls: the
    /// counter could not be observed at 2 whatever the scheduler did. Deleting *every* line
    /// of arbitration — `takeTurn` returning immediately and `yieldTurn` doing nothing — left
    /// it green while both its siblings went red.
    ///
    /// A counter that cannot be incremented twice is not a weaker assertion than one that
    /// can; it is not an assertion. The fix is one argument: the provider must **hold**, so
    /// that a turn is genuinely parked inside `read(keys:)` while another could arrive.
    ///
    /// **Mutation:** `takeTurn` → `if true { isTurnInFlight = true; return }` and `yieldTurn`
    /// → `if true { return }`. Run: red here and in
    /// `aFreshArrivalCannotBargeOntoAHeldTurn`.
    @Test("Concurrent multi-turn reads never overlap at the provider")
    func soakedConcurrentReadsNeverOverlap() async throws {
        // Holding, so `hold()` actually suspends inside `read(keys:)` and an overlapping
        // turn has a window to be seen in. See this test's documentation.
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)

        // Enough concurrent multi-turn work that any admission bug overlaps something.
        let reads = (0..<6).map { index in
            observing {
                try await scheduler.read(
                    keys: (0..<150).map { "K\(index)-\($0)" },
                    at: index.isMultiple(of: 2) ? .snapshot : .supervisor)
            }
        }
        // Drain one turn at a time. Each release lets exactly one parked turn out, so the
        // provider is occupied for the whole run rather than waved through.
        let drain = Task {
            while await provider.turns.count < 18 {
                await provider.releaseOneTurn()
                await Task.yield()
            }
            await provider.releaseEveryTurn()
        }
        for (index, read) in reads.enumerated() {
            try await finished("concurrent read \(index)", read)
        }
        await drain.value

        #expect(
            await provider.peakConcurrentTurns == 1,
            "two turns were inside the provider at once; mutual exclusion is broken")
    }

    // MARK: - What the bound does and does not cover

    /// The supervisor-side bound, pinned as it **actually** behaves rather than as three
    /// doc comments used to claim.
    ///
    /// "A supervisor read waits at most two turns" is true of *one* outstanding supervisor
    /// read. `supervisorWaiters` is FIFO and the quota forces a snapshot turn after every
    /// `maxConsecutiveOvertakes`, so N concurrent supervisor reads make the last one wait
    /// roughly `N + N / maxConsecutiveOvertakes` turns. That is not a defect — a serial
    /// connection cannot serve two readers at once — but it is not what the prose said, and
    /// it matters: `LeaseAuthority.refuseIfBlind` already issues supervisor-priority reads
    /// off the § 3 cycle, so #103 and #126 will have several outstanding at once.
    ///
    /// This test exists so the corrected claim is backed by a measurement instead of by a
    /// second draft of the same prose.
    @Test("With several supervisor reads outstanding, the last waits longer than two turns")
    func theSupervisorBoundIsPerOutstandingRead() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let snapshotKeys = Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 4)

        let snapshot = observing { try await scheduler.read(keys: snapshotKeys, at: .snapshot) }
        await yieldUntil("the first snapshot turn to reach the provider") {
            await provider.turns.count == 1
        }

        let supervisorReads = 3
        let supervised = (0..<supervisorReads).map { index in
            observing { try await scheduler.read(keys: ["T\(index)"], at: .supervisor) }
        }
        await yieldUntil("every supervisor read to be queued") {
            await scheduler.queuedTurns(at: .supervisor) == supervisorReads
        }

        await provider.releaseEveryTurn()
        for (index, read) in supervised.enumerated() {
            try await finished("supervisor read \(index)", read)
        }
        try await finished("the snapshot", snapshot)

        let turns = await provider.turns
        let lastSupervisor = try #require(turns.lastIndex { $0[0].hasPrefix("T") })

        // Three supervisor reads queued behind one in-flight snapshot turn: the quota lets
        // two through, forces a snapshot turn, then admits the third. So the third is
        // admitted on the fifth turn overall — four turns after it queued, against the two
        // the doc claims for a lone read.
        #expect(
            lastSupervisor > SMCReadScheduler.maxConsecutiveOvertakes,
            "trace \(turns.map { $0[0] }) — expected the third read past the quota")
        #expect(turns[1][0].hasPrefix("T"), "the first supervisor read should still go first")
    }
}
