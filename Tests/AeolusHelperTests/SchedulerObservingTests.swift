import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The hook itself: every kind of thing `SMCReadScheduler` can report is actually reported.
///
/// ## What this suite is guarding against
///
/// A seam that nobody consumes yet. `SchedulerObserving` exists for
/// [#133](https://github.com/blamechris/Aeolus/issues/133) and
/// [#135](https://github.com/blamechris/Aeolus/issues/135), which will fill in emission
/// policy against it; today only `ConnectionHealth` listens, and it listens to two of the
/// seven kinds. The other five have no consumer at all, which is exactly the condition under
/// which an emission can be deleted, mis-wired, or never written, with nothing red.
///
/// So the assertion is *exhaustive by construction*: `SchedulerEvent.Kind` is `CaseIterable`,
/// and the scripted run below must produce every one of its cases. A case added without an
/// emission fails here; an emission deleted from the scheduler fails here.
///
/// ## Why one scripted run and not seven tests
///
/// Because the interesting kinds are the scheduling ones, and they only happen in
/// combination: an overtake needs a supervisor read queued behind a snapshot that is already
/// waiting, and a spent quota needs enough supervisor reads to spend it. Splitting those into
/// separate fixtures would mean writing the same interleaving three times.
///
/// `.timeLimit` for `SMCReadSchedulerTests`' reason: a scheduler that stops granting turns
/// hangs a join, and a green suite must mean the tests ran.
@Suite("Scheduler observing", .timeLimit(.minutes(1)))
struct SchedulerObservingTests {

    private static func snapshotKeys(_ count: Int) -> [String] {
        (0..<count).map { "S\($0)" }
    }

    /// **The exhaustiveness assertion.**
    ///
    /// The script, in order:
    ///
    /// 1. A three-turn snapshot is put on the connection and held at the provider. That is
    ///    `turnGranted` on the fast path.
    /// 2. A second snapshot is queued behind it — `waiterParked`, and the thing an overtake
    ///    needs in order to be overtaking *something*.
    /// 3. Three supervisor reads are queued. The first two are admitted ahead of the waiting
    ///    snapshot — `overtakeTaken` — and the third is not, because the quota is spent:
    ///    `quotaExhausted`.
    /// 4. The turns are released and everything drains, which yields `turnEnded` many times
    ///    and `wholeReadSucceeded` per completed read.
    /// 5. A read on a second scheduler, over a provider that throws, gives `wholeReadFailed`.
    ///    A second scheduler rather than a failing turn in the run above, because which
    ///    ordinal a failing turn lands on depends on the admission order the run is *testing*
    ///    — so it would be a fixture whose correctness depended on the thing under test. The
    ///    observer is the subject here, and it hears both schedulers.
    ///
    /// **Mutation:** delete any one `report(…)` call from `SMCReadScheduler` — the
    /// `overtakeTaken` line in `nextTurn()` is the least obviously load-bearing, so it is the
    /// one worth trying. Run: red here, naming the kind that went missing, and green
    /// everywhere else in the repository.
    @Test("A scripted run emits every kind of scheduler event")
    func everyEventKindIsEmittedInAScriptedRun() async throws {
        let observer = RecordingSchedulerObserver()
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider, observer: observer)

        let firstSnapshot = observing {
            try await scheduler.read(
                keys: Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 3), at: .snapshot)
        }
        await yieldUntil("the first snapshot turn to reach the provider") {
            await provider.turns.count == 1
        }

        let secondSnapshot = observing {
            try await scheduler.read(keys: ["Q0"], at: .snapshot)
        }
        await yieldUntil("a second snapshot to be queued behind it") {
            await scheduler.queuedTurns(at: .snapshot) == 1
        }

        // Three, because two spend the quota and the third is what makes it *exhausted*
        // rather than merely spent — `quotaExhausted` is reported only when a supervisor
        // turn was actually held back.
        let supervisorReads = (0..<3).map { index in
            observing { try await scheduler.read(keys: ["T\(index)"], at: .supervisor) }
        }
        await yieldUntil("all three supervisor reads to be queued") {
            await scheduler.queuedTurns(at: .supervisor) == 3
        }

        await provider.releaseEveryTurn()
        _ = try await finished("the three-turn snapshot", firstSnapshot)
        _ = try await finished("the second snapshot", secondSnapshot)
        for (index, read) in supervisorReads.enumerated() {
            _ = try await finished("supervisor read \(index)", read)
        }

        // The failure half, from a read that really fails rather than a synthesised event.
        let failing = SMCReadScheduler(provider: ThrowOnceProvider(), observer: observer)
        await #expect(throws: (any Error).self) {
            try await failing.read(keys: ["TPD0"], at: .supervisor)
        }

        let seen = Set(observer.events.map(\.kind))
        let missing = Set(SchedulerEvent.Kind.allCases).subtracting(seen).map(
            String.init(describing:))
        #expect(
            missing.isEmpty,
            """
            \(missing.sorted()) was never reported in a run that produces every one of them. \
            Either the scheduler stopped emitting it, or a case was added to SchedulerEvent \
            without the line that emits it — and a case nothing emits is a seam #133 and \
            #135 will build on and never hear from.
            """)
    }

    /// A `turnGranted` is reported for every turn actually granted, and never for one that
    /// was not.
    ///
    /// The pairing with `turnEnded` is what makes the stream usable for latency at all: an
    /// observer that saw one of the two would compute a wait against a boundary that never
    /// happened. Multi-turn reads make this non-trivial — a three-turn read is three grants
    /// and three ends, not one of each.
    ///
    /// **Mutation:** delete `report(.turnEnded(priority: priority))` from `yieldTurn(at:)`.
    /// Run: red — three grants against one end.
    @Test("Every granted turn is matched by an ended one")
    func grantsAndEndsAreBalanced() async throws {
        let observer = RecordingSchedulerObserver()
        let provider = GatedSensorProvider()
        let scheduler = SMCReadScheduler(provider: provider, observer: observer)

        _ = try await scheduler.read(
            keys: Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 3), at: .snapshot)

        let granted = observer.events.filter { $0.kind == .turnGranted }.count
        let ended = observer.events.filter { $0.kind == .turnEnded }.count
        #expect(granted == 3, "a three-turn read took \(granted) turns")
        #expect(granted == ended, "\(granted) turns were granted and \(ended) ended")
    }

    /// A scheduler with no observer takes exactly the same path and reports into nothing.
    ///
    /// The hook must not change scheduling, and "must not" is cheap to say — the whole suite
    /// of ordering tests in `SMCReadSchedulerTests` runs without an observer, so this asserts
    /// the other half: that adding one changes no outcome.
    @Test("The observer changes nothing about what a read returns")
    func observingChangesNothing() async throws {
        let observed = SMCReadScheduler(
            provider: GatedSensorProvider(), observer: RecordingSchedulerObserver())
        let unobserved = SMCReadScheduler(provider: GatedSensorProvider())

        let keys = Self.snapshotKeys(SMCReadScheduler.maxKeysPerTurn * 2 + 1)
        let withObserver = try await observed.read(keys: keys, at: .snapshot)
        let without = try await unobserved.read(keys: keys, at: .snapshot)

        #expect(withObserver.map(\.key) == without.map(\.key))
        #expect(withObserver.count == keys.count)
    }

    /// The exclusive turn is an ordinary turn as far as the hook is concerned — granted at
    /// `.supervisor`, and ended.
    ///
    /// Worth its own assertion because `withExclusiveAccess(_:)` is the one turn-taking path
    /// that is not a read, so it has no `wholeReadSucceeded` to stand in for it. A recycle
    /// that took a turn and reported nothing would be invisible to #133's latency picture
    /// while being one of the few things that can hold the connection for a long time.
    @Test("An exclusive turn is reported like any other")
    func anExclusiveTurnIsReported() async throws {
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(provider: GatedSensorProvider(), observer: observer)

        await scheduler.withExclusiveAccess {}

        let granted = observer.events.compactMap { event -> SMCReadPriority? in
            guard case .turnGranted(let priority, _) = event else { return nil }
            return priority
        }
        #expect(granted == [.supervisor])
        #expect(observer.events.contains { $0.kind == .turnEnded })
    }
}

// MARK: - Doubles

/// Keeps every event, in order.
///
/// A `final class` with a lock rather than an actor, because `SchedulerObserving` is
/// synchronous by design — the scheduler reports from inside its own isolation, which is what
/// makes the stream ordered — so a conformer cannot `await`. `TestClock` in
/// `LeaseTestDoubles` is the same shape for the same reason.
///
/// The lock is not decoration even though every call arrives from one actor: the *reads*
/// happen from the test's task, which is not that actor.
final class RecordingSchedulerObserver: SchedulerObserving, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [SchedulerEvent] = []

    var events: [SchedulerEvent] {
        lock.withLock { recorded }
    }

    func schedulerDidObserve(_ event: SchedulerEvent) {
        lock.withLock { recorded.append(event) }
    }
}
