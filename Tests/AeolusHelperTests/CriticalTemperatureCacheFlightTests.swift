import AeolusXPC
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What happens **inside** the single-flight window, which is the one interval
/// `CriticalTemperatureCacheTests` cannot reach.
///
/// Every property in that suite is about a cache at rest: something is recorded, or nothing
/// is, and then a caller arrives. Both defects below live in the gap between a flight
/// starting and its caller resuming — a gap in which § 3's cycle can record, and in which the
/// flight's own error reaches callers that never issued it. Neither is observable from a test
/// that lets a read complete before doing anything else, which is why they were both invisible
/// to a suite that already had five tests on this actor.
///
/// The gate is what makes each one a scenario rather than a race: nothing completes until the
/// test opens it, so the interleaving is a fact rather than a hope
/// ([#109](https://github.com/blamechris/Aeolus/issues/109) is why no test here loops until it
/// happens to observe the ordering).
///
/// `.timeLimit` for `SchedulerTurnLifecycleTests`'s reason: a caller parked for ever in a
/// coalescing bug must fail rather than hang.
@Suite("Inside the cache's single-flight window", .timeLimit(.minutes(1)))
struct CriticalTemperatureCacheFlightTests {

    private static func sightedPlane() -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [:], stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
    }

    private static func curated(
        over plane: ScriptedControlPlane
    ) -> CuratedCriticalTemperatures<ScriptedControlPlane> {
        CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
    }

    private static func report(celsius: Double) throws -> CriticalTemperatureReport {
        try CriticalTemperatureReport(
            readings: [CriticalTemperature(key: smcKey("Tp01"), celsius: celsius)],
            unreadableKeys: [])
    }

    // MARK: - The flight's stamp is not evidence of its freshness

    /// A flight resumes **after** § 3 recorded a blindness, and must not overwrite it.
    ///
    /// `sighting()` stamps its own outcome with `clock.now` at the moment the caller resumes,
    /// not at the moment its read finished, and nothing orders a resumed continuation against
    /// a fresh call arriving at the same actor. So the older of two readings can be stamped as
    /// the newer one — and the direction that matters is this one: a **sighting** replacing a
    /// **blindness** grants leases on a helper that has already been found unable to see, and
    /// keeps doing so for a full `maxAge` measured from an instant the reading was never taken
    /// at. That is outside the bound ADR 0010 promises, not merely at the edge of it.
    ///
    /// The scenario is the daemon's, step for step: a client's grant finds a cold cache and
    /// starts a read; while it is in flight § 3's own cycle finds the SMC unanswerable and
    /// records it; the client's read then completes against a machine that was still readable
    /// when its turn was taken. Afterwards the helper is blind, and the next grant must be
    /// refused.
    ///
    /// `source.reads` stays at 1 either way — the discriminator is the **throw**, because a
    /// cache serving the flight's stale sighting also serves it without reading.
    ///
    /// **Mutation (M8):** drop the guard — `record(.sighted(report))` on the success path of
    /// `sighting()`, as it was written before this. Run: red, because the second grant is
    /// handed a reading and § 3's blindness is gone.
    @Test("A flight does not overwrite what § 3 recorded while it was away")
    func aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        // A cold cache: this grant issues a real read, which parks in the gated source.
        let grant = observing { try await cache.sighting() }
        let started = await yieldUntil("the grant to reach the source") {
            await source.reads == 1
        }
        #expect(started, "the grant never issued the read this scenario interleaves with")

        // § 3's cycle, mid-flight: the SMC has stopped answering.
        await cache.record(.blind(FanControlPlaneError.readFailed(detail: "stale port")))

        await source.open()
        let served = try await finished("the grant", grant)
        #expect(
            served?.readings.isEmpty == false,
            "the caller that started the flight is still handed its own reading")

        await #expect(throws: FanControlPlaneError.self) { _ = try await cache.sighting() }
        #expect(
            await source.reads == 1,
            "the blindness was not being served at all — this scenario proves nothing")
        #expect(await cache.readsIssued == 1)
        #expect(await cache.coalescedSightings == 1)
    }

    // MARK: - The residual cancellation case

    /// A joiner **is** handed the flight's `CancellationError`, and nothing is remembered.
    ///
    /// This pins the one case ADR 0010's cancellation paragraph now names as residual. The
    /// argument for not *recording* a cancellation is that it would be replayed to other
    /// clients, none of whom was cancelled — and the single-flight window is the one place
    /// where a cancellation still reaches a caller that did not issue it, because a joiner
    /// waits on the starter's task rather than on its own.
    ///
    /// It is unreachable in the daemon today, and the ADR says why: the flight is an
    /// unstructured `Task`, so a cancelled grant does not cancel it, and nothing below it
    /// throws `CancellationError` of its own — `SMCReadScheduler`'s wait for a turn is
    /// deliberately not cancellable. The value of the test is that it says what *would*
    /// happen, and would go red the day a conformer under `source` started throwing one.
    ///
    /// The second half is the part that limits the harm and is worth pinning separately:
    /// nothing is recorded, so the very next caller reads the machine for itself rather than
    /// being told for a whole cycle that its own request was cancelled.
    ///
    /// **Mutation:** delete the `guard sighting.isAboutTheMachine` line from `record(_:)` —
    /// M6's mutation, reached through the join path instead of the direct one. Run: red on the
    /// third call, which replays the cancellation instead of reading.
    @Test("A joiner receives the flight's cancellation, and the cache remembers none of it")
    func aJoinerReceivesTheFlightsCancellation() async throws {
        let source = GatedCriticalTemperatures(
            ThrowOnceCriticalTemperatures(CancellationError(), then: try Self.report(celsius: 44)))
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        let starter = observing { try await cache.sighting() }
        let reached = await yieldUntil("the starter to reach the source") {
            await source.reads == 1
        }
        #expect(reached, "the starter never issued a read for a joiner to join")

        let joiner = observing { try await cache.sighting() }
        let joined = await yieldUntil("the joiner to join the flight") {
            await cache.coalescedSightings == 1
        }
        #expect(joined, "the second caller issued its own read instead of joining")

        await source.open()
        await #expect(throws: CancellationError.self) { _ = try await finished("starter", starter) }
        await #expect(throws: CancellationError.self) { _ = try await finished("joiner", joiner) }
        #expect(await cache.readsIssued == 1, "the joiner took a turn of its own")

        // Nothing was remembered, so the next caller reads rather than being handed a
        // cancellation it never asked for.
        let afterwards = try await cache.sighting()
        #expect(afterwards.readings.map(\.celsius) == [44])
        #expect(await cache.readsIssued == 2)
    }
}
