import AeolusXPC
import SMCCore
import Testing

@testable import AeolusHelper

/// Connection scheduling: the safety cycle goes first, and the snapshot still finishes.
///
/// Every test here is **scripted, not raced**. The provider double holds each turn until
/// the test releases it, so an interleaving is something the test states rather than
/// something it hopes for, and each *condition* is waited on through
/// `yieldUntil(_:within:_:)`, which records an issue instead of spinning for ever
/// ([#109](https://github.com/blamechris/Aeolus/issues/109)).
///
/// **That is not the whole of it, and an earlier version of this paragraph said it was.**
/// Every test still joins its tasks with a bare `await task.value`, which `yieldUntil`
/// does not bound and cannot. When mutual exclusion breaks, two turns reach the provider
/// at once and one of those joins never returns — so the suite hung rather than failed,
/// which is the worst way for a safety fixture to react to its subject being broken. Two
/// things fix it, and both are load-bearing: `.timeLimit` here, on the precedent
/// `AnonymousListenerTests` set one file away for the same reason, and
/// `GatedSensorProvider.peakConcurrentTurns`, which turns the overlap itself into an
/// assertion instead of a hang.
///
/// ## The fixture's basis
///
/// The key counts below are scaled-down stand-ins for the measurement in ADR 0006 and
/// `SMCReadScheduler`: on `Mac16,5` / macOS 26.6.2 a warm snapshot refresh reads **2929
/// keys in ~0.5 s** (~0.17 ms a key) while the curated critical set is **thirty-four
/// keys**, and discovery — `readAll()` — costs **2.2 s warm and 5.9 s cold**, once. What
/// matters to these tests is only the *ratio*: a snapshot spans many turns and a safety
/// cycle spans one, so 200-odd keys against 2 reproduces the contention at a size a test
/// can assert on turn by turn. No test here depends on wall-clock time.
@Suite("SMC read scheduling", .timeLimit(.minutes(1)))
struct SMCReadSchedulerTests {

    /// Four turns at `maxKeysPerTurn` — 200 keys is three full turns and a part one — which
    /// is enough for a snapshot to be genuinely mid-flight when the supervisor arrives.
    private static func snapshotKeys(_ count: Int = 200) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    /// Named so a trace can be classified by prefix alone — `T…` is the safety cycle, `S…`
    /// is a snapshot — which is what lets an assertion talk about admission *order*.
    private static let criticalKeys = [smcKey("TPD1"), smcKey("TPD2")]

    // MARK: - The property #127 exists for

    /// The acceptance criterion, driven through the production plane rather than the
    /// scheduler's own API: a curated critical-temperature read issued while a snapshot is
    /// on the connection is served next, not after the snapshot finishes.
    ///
    /// **Mutation:** change `SMCFanControlPlane`'s `at: .supervisor` to `at: .snapshot`.
    /// Every read still succeeds and every other test in the suite stays green; this one
    /// goes red on the ordering assertion itself, because the cycle takes its place in the
    /// snapshot queue behind a snapshot turn that was already waiting. That is the whole
    /// defect — a safety read that is *small* is still a safety read that waits, on a
    /// connection that grants no turns.
    ///
    /// **A second snapshot is queued on purpose, and the test is weak without it.** With
    /// only one snapshot in flight nothing is waiting behind it, so a cycle demoted to
    /// snapshot priority would still be first out of the queue by plain FIFO and the
    /// mutation would survive every assertion below. Something must already be waiting for
    /// "goes first" to mean anything at all. The wait below is deliberately blind to
    /// priority for the same reason: if it counted only supervisor turns it would be the
    /// assertion catching the mutation, and the ordering claim would go untested.
    @Test("The safety cycle overtakes a snapshot already on the connection")
    func theSafetyCycleOvertakesAnInFlightSnapshot() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let plane = SMCFanControlPlane(scheduler: scheduler)
        let firstKeys = Self.snapshotKeys()
        let secondKeys = ["Q0", "Q1"]

        let first = Task { try await scheduler.read(keys: firstKeys, at: .snapshot) }
        await yieldUntil("the first snapshot turn to reach the provider") {
            await provider.turns.count == 1
        }

        let second = Task { try await scheduler.read(keys: secondKeys, at: .snapshot) }
        await yieldUntil("a second snapshot to be queued behind it") {
            await scheduler.queuedTurns(at: .snapshot) == 1
        }

        let cycle = Task { try await plane.readCriticalTemperatures(Self.criticalKeys) }
        await yieldUntil("the safety cycle to be queued") {
            let supervisor = await scheduler.queuedTurns(at: .supervisor)
            let snapshot = await scheduler.queuedTurns(at: .snapshot)
            return supervisor + snapshot == 2
        }

        // The in-flight turn ends here. Who the scheduler admits next is the issue.
        await provider.releaseOneTurn()
        await yieldUntil("a second turn to reach the provider") {
            await provider.turns.count == 2
        }

        #expect(await provider.turns[1] == Self.criticalKeys.map(\.rawValue))

        await provider.releaseEveryTurn()
        #expect(try await cycle.value.readings.count == Self.criticalKeys.count)
        #expect(try await first.value.count == firstKeys.count)
        #expect(try await second.value.count == secondKeys.count)
    }

    /// The same ordering, asserted against the scheduler itself so the policy is pinned
    /// independently of who is wired to it.
    ///
    /// **Mutation:** delete the overtake branch from `SMCReadScheduler.nextTurn()` — the
    /// `if !supervisorWaiters.isEmpty, consecutiveOvertakes < …` clause. What is left is a
    /// plain two-queue FIFO that compiles and reads every key correctly, and it puts the
    /// supervisor back behind the snapshot. Run: **four** tests go red — this one, the
    /// plane's, `snapshotStarvationIsBounded`, and
    /// `SchedulerTurnLifecycleTests.theSupervisorBoundIsPerOutstandingRead` — while the
    /// read-correctness and turn-release tests stay green. (An earlier draft of this list
    /// said "the turn-lifecycle tests stay green" while naming one of them as failing; they
    /// are in `SchedulerTurnLifecycleTests`, and one of them does fail.) Four at once is the
    /// right answer, not a lack of discrimination: strict priority is the one property all
    /// four depend on, and a mutation that removed it while only one noticed would mean three
    /// of them were not testing what they claim.
    @Test("A queued supervisor turn is admitted ahead of a queued snapshot turn")
    func aSupervisorTurnIsAdmittedFirst() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let snapshotKeys = Self.snapshotKeys()
        let supervisorKeys = ["TPD1", "TPD2"]

        let snapshot = Task { try await scheduler.read(keys: snapshotKeys, at: .snapshot) }
        await yieldUntil("the first snapshot turn to reach the provider") {
            await provider.turns.count == 1
        }

        let supervised = Task {
            try await scheduler.read(keys: supervisorKeys, at: .supervisor)
        }
        await yieldUntil("the supervisor read to be queued") {
            await scheduler.queuedTurns(at: .supervisor) == 1
        }

        await provider.releaseOneTurn()
        await yieldUntil("a second turn to reach the provider") {
            await provider.turns.count == 2
        }

        #expect(await provider.turns[1] == supervisorKeys)

        await provider.releaseEveryTurn()
        #expect(try await supervised.value.count == supervisorKeys.count)
        #expect(try await snapshot.value.count == snapshotKeys.count)
    }

    // MARK: - The bound in the other direction

    /// `CLAUDE.md` rule 6's side of the trade: a client that never receives a snapshot is a
    /// UI reporting nothing. A wall of supervisor reads may overtake, but only
    /// `maxConsecutiveOvertakes` times before the snapshot is admitted regardless.
    ///
    /// Twelve supervisor reads are queued behind an in-flight snapshot turn and then
    /// everything is released at once, so the trace that reaches the provider *is* the
    /// scheduler's admission order. The gaps between consecutive snapshot turns are
    /// therefore exactly the overtakes the snapshot suffered.
    ///
    /// **Mutation:** delete `consecutiveOvertakes < Self.maxConsecutiveOvertakes` from
    /// `nextTurn()`'s overtake branch, leaving the constant where it is. Run: all twelve
    /// supervisor turns run between the snapshot's first and second turns, the gap is
    /// reported as 12 against a bound of 2, and this is the only test that goes red —
    /// `theSafetyCycleOvertakesAnInFlightSnapshot` stays green, which is the point of
    /// having both.
    ///
    /// **Second mutation, and the one worth the fixture:** in `yieldTurn(at:)`, admit
    /// before enqueueing — insert an `admitNext()` above the `withCheckedContinuation`.
    /// Priority still works, every read still succeeds, the quota is still there and still
    /// spends. Run: every gap becomes **3**, because a snapshot between turns is briefly
    /// absent from the queue and the admission that overtakes it is scored as overtaking
    /// nobody. A bound that silently means one more than it says is what this assertion is
    /// really for, and no test of ordering alone can see it.
    @Test("A wall of supervisor reads cannot starve a snapshot past the stated quota")
    func snapshotStarvationIsBounded() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        // Exactly four turns, so the trace has three gaps to inspect.
        let snapshotKeys = Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 4)
        let supervisorReads = 12

        let snapshot = Task { try await scheduler.read(keys: snapshotKeys, at: .snapshot) }
        await yieldUntil("the first snapshot turn to reach the provider") {
            await provider.turns.count == 1
        }

        let supervised = (0..<supervisorReads).map { index in
            Task { try await scheduler.read(keys: ["T\(index)"], at: .supervisor) }
        }
        await yieldUntil("every supervisor read to be queued") {
            await scheduler.queuedTurns(at: .supervisor) == supervisorReads
        }

        await provider.releaseEveryTurn()
        let outcomes = try await snapshot.value
        for read in supervised { _ = try await read.value }

        #expect(outcomes.map(\.key) == snapshotKeys, "the snapshot did not complete")

        let turns = await provider.turns
        let snapshotTurns = turns.indices.filter { turns[$0][0].hasPrefix("S") }
        #expect(snapshotTurns.count == 4)

        let gaps = zip(snapshotTurns, snapshotTurns.dropFirst()).map { $1 - $0 - 1 }
        let bound = SMCReadScheduler.maxConsecutiveOvertakes
        for gap in gaps {
            #expect(gap <= bound, "a snapshot turn was overtaken \(gap) times, bound \(bound)")
        }
        // And the quota is actually being spent. Without this, a scheduler that never
        // overtook at all would satisfy the bound above while failing the whole issue.
        #expect(
            gaps.allSatisfy { $0 == bound },
            "with twelve reads queued every gap should spend the full quota, saw \(gaps)")
    }

    // MARK: - Turns

    /// A read longer than one turn is split, and the split is invisible to the caller:
    /// `SensorProvider.read(keys:)` promises one outcome per requested key, in the order
    /// requested, duplicates included, and concatenating consecutive slices preserves all
    /// three.
    ///
    /// **Mutation:** make `turns(over:)` return the whole key list as one slice. Run: **four**
    /// tests red across the three scheduler suites — this one on the turn count, plus three
    /// that need a read to span more than one turn. That is the useful part: a scheduler
    /// that never splits grants the connection for a whole ~2929-key refresh and undoes the
    /// entire issue while every ordering test still passes.
    ///
    /// It reported "three" for one commit, and reported nothing at all for the commit before
    /// that — the soak test's drain loop waited on the *expected* turn count, so a mutation
    /// producing fewer spun it at ~158% CPU past every time limit. A mutation ledger is only
    /// worth the runs behind it.
    @Test("A long read is split into bounded turns without disturbing its answer")
    func aLongReadIsSplitIntoBoundedTurns() async throws {
        let provider = GatedSensorProvider()
        let scheduler = SMCReadScheduler(provider: provider)
        // A duplicate on the end, because the contract keeps those too.
        let keys = Self.snapshotKeys() + ["S0"]

        let outcomes = try await scheduler.read(keys: keys, at: .snapshot)

        #expect(outcomes.map(\.key) == keys)
        let turns = await provider.turns
        #expect(turns.count == 4, "201 keys should be four turns at 64")
        #expect(turns.allSatisfy { $0.count <= SMCReadScheduler.maxKeysPerTurn })
        #expect(turns.flatMap { $0 } == keys)
        #expect(await provider.readAllCount == 0, "a subset read reached readAll()")
    }

    @Test("An empty request takes no turn and asks the provider nothing")
    func anEmptyRequestTakesNoTurn() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)

        #expect(try await scheduler.read(keys: [], at: .snapshot).isEmpty)
        #expect(await provider.turns.isEmpty)
    }

    // MARK: - Discovery is not a turn

    /// The sharpest decision in `SMCReadScheduler`, asserted rather than asserted about.
    ///
    /// `readAll()` cannot be split from here — the index walk belongs to
    /// `SMCSensorProvider` — so holding a turn for it would lock the supervisor out for a
    /// **guaranteed** 2.2 s warm, 5.9 s cold. That is worse than the contention being
    /// fixed, so discovery takes no turn at all.
    ///
    /// **Mutation:** give `SMCReadScheduler.readAll()` a turn — `await takeTurn(at:
    /// .snapshot)` with `defer { endTurn() }`. The supervisor read below then queues behind
    /// held discovery, `yieldUntil` runs out and records an issue, and the test still
    /// terminates rather than hanging, because releasing discovery ends the turn.
    @Test("Discovery takes no turn, so the safety cycle is not locked out behind it")
    func discoveryTakesNoTurn() async throws {
        let provider = GatedSensorProvider(holdingReadAll: true)
        let scheduler = SMCReadScheduler(provider: provider)

        let discovery = Task { try await scheduler.readAll() }
        await yieldUntil("discovery to reach the provider") {
            await provider.readAllIsInFlight
        }

        let discoveryDone = CompletionFlag()
        let supervised = Task {
            _ = try await scheduler.read(keys: ["TPD1"], at: .supervisor)
            await discoveryDone.mark()
        }
        await yieldUntil("the safety cycle to complete while discovery is still running") {
            await discoveryDone.isSet
        }

        await provider.releaseReadAll()
        _ = try await discovery.value
        try await supervised.value
    }

    // MARK: - The contract this does not touch

    /// Scheduling is entirely inside the helper: no DTO, no selector and no wire field
    /// changed, so a client built against v1 is unaffected by any of it.
    @Test("AeolusXPCVersion is unchanged by connection scheduling")
    func theXPCVersionIsUnchanged() {
        // Pins the constant, which is the only way to assert "unchanged" without a stored
        // baseline — #127's acceptance criteria ask for exactly that. A legitimate bump to 2
        // is therefore expected to turn this red: the reader should confirm the protocol
        // really did change and move the number, not reach for the scheduler.
        #expect(AeolusXPCVersion.current == 1)
    }
}
