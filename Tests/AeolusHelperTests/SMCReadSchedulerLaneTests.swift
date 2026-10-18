import SMCCore
import Testing

@testable import AeolusHelper

/// § 3's lane through the real scheduler (ADR 0012's 2026-10-18 amendment): admitted first,
/// behind only the turn in flight, outside the overtake quota, and never two turns in a row
/// while another waiter is parked.
///
/// Scripted, not raced, as `SMCReadSchedulerTests` is: `GatedSensorProvider` holds every turn
/// until the test releases it, so the trace at the provider is the order turns were granted,
/// and every condition is waited on through `yieldUntil(_:within:_:)`.
@Suite("SMC read scheduling — § 3's lane", .timeLimit(.minutes(1)))
struct SMCReadSchedulerLaneTests {

    private static func keys(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix)\($0)" }
    }

    /// The first key of every turn the provider saw, which names the read it belonged to.
    private static func trace(_ provider: GatedSensorProvider) async -> [String] {
        await provider.turns.compactMap(\.first)
    }

    // MARK: - L1: first, behind only the turn in flight, and outside the quota

    /// A lane waiter parked **last** — behind eleven supervisor waiters and two snapshot turns —
    /// is granted the moment the 64-key slice in flight ends, and the quota around it moves as
    /// though it had not been there.
    ///
    /// The slice in flight is a supervisor read that overtook a waiting snapshot, so the quota
    /// stands at one when the lane is granted. That is what lets the trace tell all three
    /// mutations apart: unchanged, one more supervisor turn goes before the snapshot; spent,
    /// none does; reset, two do.
    ///
    /// **Mutation:** in `nextTurn()`, move the lane's `if` below the overtake branch. Run: red —
    /// `S1` is granted at the slice's end, not the lane.
    /// **Mutation:** in `nextTurn()`, `consecutiveOvertakes += 1` before returning the lane's
    /// waiter. Run: red — the snapshot is granted straight after the lane.
    /// **Mutation:** in `nextTurn()`, `consecutiveOvertakes = 0` before returning the lane's
    /// waiter. Run: red — two supervisor turns go after the lane before the snapshot.
    @Test("A lane waiter parked last is granted at the slice's end and leaves the quota alone")
    func theLaneIsGrantedNextAndLeavesTheQuotaAlone() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(provider: provider, observer: observer)
        let wall = await Self.queueTheWall(on: scheduler, at: provider)

        // The first slice ends: the 64-key supervisor read overtakes the waiting snapshots.
        await provider.releaseOneTurn()
        await yieldUntil("the 64-key supervisor slice to reach the provider") {
            await provider.turns.count == 2
        }
        #expect(await scheduler.queuedTurns(at: .supervisor) == 11)
        #expect(await scheduler.queuedTurns(at: .snapshot) == 2)

        // The lane waiter, parked last.
        let lane = observing { try await scheduler.read(keys: ["L0"], at: .thermalCycle) }
        await yieldUntil("the lane waiter to park") {
            await scheduler.queuedTurns(at: .thermalCycle) == 1
        }

        await provider.releaseEveryTurn()
        try await finished("the lane read", lane)
        for (index, read) in wall.enumerated() {
            try await finished("read \(index) of the wall", read)
        }

        let trace = await Self.trace(provider)
        #expect(
            Array(trace.prefix(5)) == ["A0", "X0", "L0", "S1", "B0"],
            "the lane was not granted at the slice's end with the quota left alone: \(trace)")
        // The whole order, so a quota the lane disturbed later than its own grant shows too.
        #expect(
            trace == [
                "A0", "X0", "L0", "S1", "B0", "S2", "S3", "A64", "S4", "S5", "A128", "S6", "S7",
                "S8", "S9", "S10", "S11",
            ],
            "trace \(trace)")
        // The lane's grant reported no overtake: the quota's own events are X0's and S1's
        // before the forced snapshot turn, and the lane's is not among them.
        let overtakes = observer.events.prefix(while: { event in
            if case .quotaExhausted = event { return false }
            return true
        }).compactMap { event -> Int? in
            if case .overtakeTaken(let consecutive) = event { return consecutive }
            return nil
        }
        #expect(overtakes == [1, 2], "overtakes before the first forced snapshot: \(overtakes)")
        #expect(await provider.peakConcurrentTurns == 1)
    }

    /// The queue the lane test parks behind: a snapshot of three slices holding the connection,
    /// then a 64-key supervisor read, eleven one-key supervisor reads and a second snapshot.
    private static func queueTheWall(
        on scheduler: SMCReadScheduler, at provider: GatedSensorProvider
    ) async -> [ObservableWork<[SensorReadOutcome]>] {
        let turn = SMCReadScheduler.maxKeysPerTurn
        var wall = [
            observing { try await scheduler.read(keys: keys("A", turn * 3), at: .snapshot) }
        ]
        await yieldUntil("the first snapshot slice to reach the provider") {
            await provider.turns.count == 1
        }
        wall.append(observing { try await scheduler.read(keys: keys("X", turn), at: .supervisor) })
        await yieldUntil("the 64-key supervisor read to queue") {
            await scheduler.queuedTurns(at: .supervisor) == 1
        }
        for index in 1...11 {
            wall.append(
                observing { try await scheduler.read(keys: ["S\(index)"], at: .supervisor) })
            await yieldUntil("supervisor read \(index) to queue") {
                await scheduler.queuedTurns(at: .supervisor) == index + 1
            }
        }
        wall.append(observing { try await scheduler.read(keys: keys("B", turn), at: .snapshot) })
        await yieldUntil("the second snapshot to queue") {
            await scheduler.queuedTurns(at: .snapshot) == 1
        }
        return wall
    }

    // MARK: - L2: never two lane turns in a row while another waiter is parked

    /// § 3 asks three times in a row — its read and two read-backs — against a supervisor reader
    /// that is always there, its next read parked before each lane turn ends. The grant log
    /// alternates: each lane turn waits for the one turn in flight and no more, and never runs
    /// twice in a row while the supervisor reader waits.
    ///
    /// It alternates because the lane holds one waiter and § 3 re-queues only after its turn
    /// was handed on: when a lane turn ends the lane is empty, so the supervisor waiter is
    /// admitted, and § 3's next request queues behind that.
    ///
    /// **Mutation:** a lane reservation — in `endTurn(at:)`, when `priority == .thermalCycle`
    /// set `laneReserved = true` and return before `admitNext()`; in `takeTurn(at:)`, admit a
    /// `.thermalCycle` arrival at once when `laneReserved`, clearing it. Run: red — the trace is
    /// `S1, L1, L2, L3, S2`.
    @Test("Three lane requests in a row alternate with a sustained supervisor reader")
    func laneTurnsAlternateWithASustainedReader() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)

        // The sustained reader: one supervisor read after another, each held at the provider.
        let reader = observing {
            for index in 1...5 {
                _ = try await scheduler.read(keys: ["S\(index)"], at: .supervisor)
            }
        }
        await yieldUntil("the reader's first turn to reach the provider") {
            await provider.turns.count == 1
        }
        // § 3: three sequential lane requests.
        let cycle = observing {
            for index in 1...3 {
                _ = try await scheduler.read(keys: ["L\(index)"], at: .thermalCycle)
            }
        }

        // Release one turn at a time. A lane turn is released only once the reader's next read
        // is parked, so a reservation has someone to pass over; a reader's turn is released
        // only once § 3's next request is parked, while § 3 still has one to make.
        for step in 1...8 {
            await yieldUntil("turn \(step) to be held at the provider") {
                await provider.parkedWaiters == 1
            }
            let held = await provider.turns.last?.first ?? ""
            if held.hasPrefix("L") {
                await yieldUntil("the reader to park behind \(held)") {
                    await scheduler.queuedTurns(at: .supervisor) == 1
                }
            } else if (await provider.turns.filter { $0.first?.hasPrefix("L") == true }.count) < 3 {
                await yieldUntil("§ 3's next request to park behind \(held)") {
                    await scheduler.queuedTurns(at: .thermalCycle) == 1
                }
            }
            await provider.releaseOneTurn()
        }
        await provider.releaseEveryTurn()
        try await finished("§ 3's three requests", cycle)
        try await finished("the sustained reader", reader)

        let trace = await Self.trace(provider)
        #expect(
            trace == ["S1", "L1", "S2", "L2", "S3", "L3", "S4", "S5"],
            "the lane took consecutive turns while the reader waited: \(trace)")
    }

    /// Why every curated set must fit one turn: a lane read longer than `maxKeysPerTurn` yields
    /// back into its own lane, and its next slice is admitted ahead of the supervisor waiter
    /// parked behind it. The lane's one-turn-in-flight bound holds per **request**, and § 3's read
    /// is one request of one turn only because `WatchdogLimitsTests.everyCuratedSetFitsOneTurn`
    /// keeps every curated set at 64 keys or fewer.
    ///
    /// **Mutation:** in `yieldTurn(at:)`, call `admitNext()` before `enqueue` (admit first). Run:
    /// red — the supervisor waiter is admitted between the lane's two slices.
    @Test("A lane read longer than one turn runs its slices back to back")
    func aLaneReadLongerThanOneTurnRunsItsSlicesBackToBack() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let turn = SMCReadScheduler.maxKeysPerTurn

        let held = observing { try await scheduler.read(keys: ["H0"], at: .snapshot) }
        await yieldUntil("the held turn to reach the provider") { await provider.turns.count == 1 }
        let long = observing {
            try await scheduler.read(keys: Self.keys("L", turn + 1), at: .thermalCycle)
        }
        await yieldUntil("the long lane read to park") {
            await scheduler.queuedTurns(at: .thermalCycle) == 1
        }
        let waiter = observing { try await scheduler.read(keys: ["S0"], at: .supervisor) }
        await yieldUntil("the supervisor waiter to park") {
            await scheduler.queuedTurns(at: .supervisor) == 1
        }

        await provider.releaseEveryTurn()
        try await finished("the held turn", held)
        try await finished("the long lane read", long)
        try await finished("the supervisor waiter", waiter)

        let trace = await Self.trace(provider)
        #expect(trace == ["H0", "L0", "L64", "S0"], "trace \(trace)")
    }
}
