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
/// policy against it; today only `ConnectionHealth` listens, and it listens to three of the
/// eight kinds. The other five have no consumer at all, which is exactly the condition under
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
    ///    observer is the subject here, and it hears every scheduler.
    /// 6. A read on a third scheduler, over a provider that answers every key `.unknownKey`,
    ///    gives `wholeReadAbsentOnly` — ruling D25's neutral third.
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

        // The neutral third: a request made entirely of keys this machine lacks.
        let absent = SMCReadScheduler(
            provider: OutcomeScriptedProvider { .failure(.unknownKey($0)) }, observer: observer)
        _ = try await absent.read(keys: ["FNum"], at: .snapshot)

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

    // MARK: - What counts as a whole read having failed

    /// **The rule ruling D21 put in the scheduler, and the half that was missing entirely.**
    ///
    /// A request in which no key produced a value, for a reason that is not "this machine
    /// does not have that key", is the connection failing to answer — and it reaches the
    /// scheduler as a **normal return**, not a throw. That is #68's actual shape:
    /// `SMCConnection.open()` returns from its own `guard` on a stale-but-non-zero handle and
    /// `SMCConnection.read(keys:)` does not throw at all.
    ///
    /// The provider here therefore never throws, which is the whole point of it — a double
    /// that threw would agree with the version of `read(keys:at:)` this replaces.
    ///
    /// **Mutation:** in `SMCReadScheduler.read(keys:at:)`, replace the
    /// `wholeReadEvent(for:at:)` report with `.wholeReadSucceeded` whenever nothing threw.
    /// Run: red here, and red on `ConnectionRecoveryTests.theStaleHandleCaseReachesAReconnect`.
    @Test("A request in which no key produced a value is a whole-read failure")
    func aRequestThatProducesNothingIsAWholeReadFailure() async throws {
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(
            provider: OutcomeScriptedProvider {
                .failure(.readFailed(reason: "the SMC did not answer \($0)"))
            },
            observer: observer)

        let outcomes = try await scheduler.read(keys: ["TC0P", "TC1P"], at: .snapshot)

        #expect(outcomes.count == 2, "the request answered per key, as it must")
        #expect(Self.count(of: .wholeReadFailed, in: observer) == 1)
        #expect(
            Self.count(of: .wholeReadSucceeded, in: observer) == 0,
            """
            a read that produced no value at all was reported as a success. Nothing then \
            counts the failure, and the helper sits blind holding nothing — #68 exactly.
            """)
    }

    /// **The false-positive guard, and — since ruling D25 — the false-*negative* guard too.**
    ///
    /// `CriticalSensorSet` deliberately asks every Mac for keys some Macs do not have, and
    /// `SMCConnection.read(keys:)` answers a key a completed walk never saw with
    /// `.keyNotFound` at zero round trips. A subset made entirely of keys this firmware lacks
    /// is therefore not the connection failing — counting it would rebuild a working
    /// connection every 1.5 s for ever, on the machines least able to afford it.
    ///
    /// It is not a success either, and for one head of #198 it was reported as one. Zero
    /// round trips means nothing in the request touched IOKit, so nothing proved the handle
    /// alive; reported as a success it reset `ConnectionHealth`'s run, and on a fanless Mac
    /// with a stale handle — where `SMCFanEnumeration`'s `FNum` read is absent-only on every
    /// snapshot — the run peaked at one for ever. Neutral is the only honest answer, and it
    /// is a third case so that an observer cannot mistake it for either of the other two.
    ///
    /// **Mutation A:** in `wholeReadEvent(for:at:)`, remove the `case .failure(.unknownKey)`
    /// arm so every failure counts. Run: red — reported as a failure.
    /// **Mutation B:** in `wholeReadEvent(for:at:)`, return `.wholeReadSucceeded` where it
    /// returns `.wholeReadAbsentOnly` — the rule at `eb91026`. Run: red — reported as a
    /// success, and red on `ConnectionRecoveryTests.theFanlessMacCaseReachesAReconnect`.
    @Test("A request whose only failures are absent keys is neither a failure nor a success")
    func absentKeysAreNeitherAFailureNorASuccess() async throws {
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(
            provider: OutcomeScriptedProvider { .failure(.unknownKey($0)) },
            observer: observer)

        _ = try await scheduler.read(keys: ["TZ99", "TZ98"], at: .supervisor)

        #expect(Self.count(of: .wholeReadAbsentOnly, in: observer) == 1)
        #expect(
            Self.count(of: .wholeReadFailed, in: observer) == 0,
            """
            keys this machine does not expose were reported as the connection failing. That \
            is a fact about the Mac, not about the handle, and reconnecting over it recycles \
            a connection that is answering perfectly.
            """)
        #expect(
            Self.count(of: .wholeReadSucceeded, in: observer) == 0,
            """
            keys this machine does not expose were reported as the connection answering. \
            Nothing in the request touched IOKit, so nothing proved the handle alive — and \
            a success resets the run a stale handle is building, which on a fanless Mac is \
            every snapshot.
            """)
    }

    /// D21 is unchanged by D25, and this is the boundary between them asserted from both
    /// sides. A request that mixes an absent key with a failure that *is* the handle's
    /// produced no value for the handle's reason — `wholeReadFailed`, so a fanless Mac's
    /// `FNum` cannot dilute a failing read it happens to share a request with. And one that
    /// mixes an absent key with a reading answered — `wholeReadSucceeded`, because a round
    /// trip came back.
    ///
    /// **Mutation:** in `wholeReadEvent(for:at:)`, return `.wholeReadAbsentOnly` whenever
    /// an absent key was seen, before the `firstFailure` guard. Run: red on the first half.
    @Test("An absent key beside a real failure is still a failure, and beside a reading a success")
    func anAbsentKeyDecidesNothingOnItsOwn() async throws {
        let failing = RecordingSchedulerObserver()
        let mixedWithFailure = SMCReadScheduler(
            provider: OutcomeScriptedProvider { key in
                key == "FNum"
                    ? .failure(.unknownKey(key))
                    : .failure(.readFailed(reason: "the SMC did not answer \(key)"))
            },
            observer: failing)
        _ = try await mixedWithFailure.read(keys: ["FNum", "TC0P"], at: .supervisor)
        #expect(
            Self.count(of: .wholeReadFailed, in: failing) == 1,
            "an absent key softened a request in which the handle failed every other key")
        #expect(Self.count(of: .wholeReadAbsentOnly, in: failing) == 0)

        let succeeding = RecordingSchedulerObserver()
        let mixedWithReading = SMCReadScheduler(
            provider: OutcomeScriptedProvider { key in
                key == "FNum" ? .failure(.unknownKey(key)) : .reading(key, 42)
            },
            observer: succeeding)
        _ = try await mixedWithReading.read(keys: ["FNum", "TC0P"], at: .supervisor)
        #expect(Self.count(of: .wholeReadSucceeded, in: succeeding) == 1)
        #expect(Self.count(of: .wholeReadAbsentOnly, in: succeeding) == 0)
    }

    /// One reading is enough. Losing thirty-three of thirty-four curated keys is a degraded
    /// cycle — `SafetyLog.degradedCycle`'s subject — and it is emphatically not the
    /// connection being gone, because the connection just answered.
    ///
    /// **Mutation:** in `wholeReadEvent(for:at:)`, return the failed event whenever *any*
    /// failure is present rather than only when nothing succeeded. Run: red.
    @Test("One readable key is enough to make the request a success")
    func oneReadingIsEnoughToSucceed() async throws {
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(
            provider: OutcomeScriptedProvider { key in
                key == "TC0P"
                    ? .reading(key, 42) : .failure(.readFailed(reason: "no answer for \(key)"))
            },
            observer: observer)

        _ = try await scheduler.read(keys: ["TC0P", "TC1P", "TC2P"], at: .supervisor)

        #expect(Self.count(of: .wholeReadSucceeded, in: observer) == 1)
        #expect(Self.count(of: .wholeReadFailed, in: observer) == 0)
    }

    private static func count(
        of kind: SchedulerEvent.Kind, in observer: RecordingSchedulerObserver
    ) -> Int {
        observer.events.filter { $0.kind == kind }.count
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
