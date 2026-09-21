import AeolusXPC
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What happens **inside** the single-flight window, which is the one interval
/// `CriticalTemperatureCacheTests` cannot reach.
///
/// Every property in that suite is about a cache at rest: something is recorded, or nothing
/// is, and then a caller arrives. The first two defects below live in the gap between a flight
/// starting and its caller resuming — a gap in which § 3's cycle can record, and in which the
/// flight's own error reaches callers that never issued it. Neither is observable from a test
/// that lets a read complete before doing anything else, which is why they were both invisible
/// to a suite that already had five tests on this actor.
///
/// Two of the four tests here no longer sit inside that gap, and the thesis is amended rather
/// than left standing: `aFlightsOutcomeLandsWhenNothingSupersededIt` exercises the same guard
/// with the gate already open, because the record it needs to be *older* than the flight
/// cannot be made during one. They live here because the mechanism is
/// `record(_:since:)`, not because the interleaving is.
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

    /// § 3's cadence, named from the supervisor that runs it rather than from the bound
    /// under test.
    ///
    /// `CriticalTemperatureCacheTests.oneCyclePeriod`'s argument, and it is not a style
    /// point: an advance written against `CriticalTemperatureCache.defaultMaxAge` moves
    /// *with* a mutation of that constant, so the ageing still happens and the suite stays
    /// green while the grant path serves readings many cycles old.
    ///
    /// Duplicated from that suite rather than shared, deliberately and for the same reason
    /// `strippingComments` is duplicated in `HelperCompositionTests`: a single definition
    /// reachable from both files is one edit away from being pointed at `defaultMaxAge` for
    /// both, which is the mutation this constant exists to survive. Two independent spellings
    /// of the cadence is the property, not an oversight.
    private static var oneCyclePeriod: Duration {
        ThermalSupervisor<ScriptedControlPlane>.defaultInterval
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
    /// ## The clock advance is what makes `startedAt`'s *placement* an assertion
    ///
    /// The guard compares against the instant the flight **started**, and the doc block on
    /// `record(_:since:)` says why that is the only instant the actor knows
    /// the flight to be no fresher than. Nothing pinned it. On a frozen `TestClock` the
    /// flight's start and the caller's resume are the same value, so moving the
    /// `let startedAt = beganReading()` stamp down to the `record` call left the repository green
    /// — while in the daemon it makes the guard a no-op, because every record the cycle made
    /// during the flight is then strictly *older* than a stamp taken after it.
    ///
    /// Advancing one millisecond after § 3's record separates the two placements: the cycle's
    /// blindness now lands strictly before the resume and at the same instant as the start, so
    /// `>=` still holds for the start and fails for the resume. One millisecond, because the
    /// blindness must stay well inside `maxAge` — this test is about the comparison, and
    /// `aStaleSightingIsNotServed` owns the age bound.
    ///
    /// **Mutation (M8):** drop the guard — call the private store directly on the success
    /// path of `sighting()`, as it was written before this. Run: red, because the second grant is
    /// handed a reading and § 3's blindness is gone.
    ///
    /// **Mutation (M9):** move `let startedAt = beganReading()` from above the flight to
    /// immediately before the `record(.sighted(...), since:)` call. Run: red here, and green
    /// everywhere else in the repository — which is what this advance is for.
    @Test("A flight does not overwrite what § 3 recorded while it was away")
    func aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        let clock = TestClock()
        let cache = CriticalTemperatureCache(source: source, clock: clock)

        // A cold cache: this grant issues a real read, which parks in the gated source.
        let grant = observing { try await cache.sighting() }
        let started = await yieldUntil("the grant to reach the source") {
            await source.reads == 1
        }
        #expect(started, "the grant never issued the read this scenario interleaves with")

        // § 3's cycle, mid-flight: the SMC has stopped answering.
        await cache.recordAsASetupStep(
            .blind(FanControlPlaneError.readFailed(detail: "stale port")))

        // See the doc block: this is what makes the flight's *start* the thing being
        // compared against, rather than the instant its caller happens to resume at.
        clock.advance(by: .milliseconds(1))

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

    // MARK: - The other direction of the same comparison

    /// **Nothing** landed while the flight was away, so its outcome is what the cache holds.
    ///
    /// `aFlightDoesNotOverwriteWhatWasRecordedWhileItWasAway` pins the `>=` side of
    /// `record(_:since:)` — a record stamped at or after `startedAt` wins.
    /// Nothing pinned the other side, and the whole guard survived being rewritten as
    /// `if recorded != nil { return }`: "a newer record wins" becomes "any record wins", and
    /// a flight that finishes on an otherwise-idle cache can never land its outcome once
    /// anything has ever been recorded. The doc block above the guard argues for the
    /// comparison at length; until this test the suite did not exercise the argument.
    ///
    /// The older record has to be **aged out**, or `sighting()` would serve it and never
    /// start the flight this is about — which is why the discriminator is the call *after*
    /// the flight rather than the flight's own return value. With the comparison intact the
    /// flight's reading is in the cache and that call is served from it; with the guard
    /// mutated the cache still holds the expired blindness and the call reads the machine
    /// again.
    ///
    /// [#203](https://github.com/blamechris/Aeolus/issues/203) asked for the record to land
    /// *while the flight is in flight*, and that form is unconstructible rather than merely
    /// awkward: `record(_:)` stamps with `clock.now`, so under a monotonic clock anything
    /// landing during a flight is necessarily at or after `startedAt` and takes the `>=`
    /// branch — which is the sibling test above. An aged-out leftover is the only reachable
    /// record strictly older than a flight's start, so this test opens the gate first and is
    /// the weaker suite member for it. Said here so the next reader need not re-derive it.
    ///
    /// **Mutation:** `if recorded != nil { return }` in
    /// `record(_:since:)`. Run: red — `source.reads` is 2, `readsIssued` is
    /// 2, and nothing coalesced.
    @Test("A flight's outcome lands when nothing newer arrived while it was away")
    func aFlightsOutcomeLandsWhenNothingSupersededIt() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        await source.open()
        let clock = TestClock()
        let cache = CriticalTemperatureCache(source: source, clock: clock)

        // Older than any flight below, and aged out so it cannot be served in place of one.
        await cache.recordAsASetupStep(
            .blind(FanControlPlaneError.readFailed(detail: "stale port")))
        clock.advance(by: Self.oneCyclePeriod + .milliseconds(1))

        let served = try await cache.sighting()
        #expect(served.readings.isEmpty == false)
        #expect(await source.reads == 1, "the expired blindness was served instead of re-read")

        // The flight's own reading is what the cache holds now, so this takes no turn.
        let afterwards = try await cache.sighting()
        #expect(afterwards.readings.map(\.celsius) == served.readings.map(\.celsius))
        #expect(
            await source.reads == 1,
            "the flight's outcome was dropped, so the next grant read the machine again")
        #expect(await cache.readsIssued == 1)
        #expect(await cache.coalescedSightings == 1)
    }

    // MARK: - A flight's blindness is not superseded

    /// A flight **fails** while § 3 records a sighting, and the failure is what the next
    /// grant is served.
    ///
    /// The mirror of the guard's intended direction, and the one it got wrong.
    /// [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) names one unsafe
    /// direction — a **sighting** overwriting a **blindness** — and the guard that stops it
    /// shielded a flight's `.blind` too. A failed read was then discarded in favour of an
    /// older success, so the next grant proved sightedness from a reading the machine had
    /// since refused to repeat, and the cache was written only on success:
    /// [#134](https://github.com/blamechris/Aeolus/issues/134)'s storm one seam in from
    /// where ADR 0010 names it.
    ///
    /// The instants are the daemon's rather than a contrivance. The private store stamps with
    /// `clock.now`, so a cycle recording during a flight stamps at or after the instant that
    /// flight was started at — exactly the condition the guard tested.
    ///
    /// `ThrowOnceCriticalTemperatures` recovers on its second read, so the two outcomes are
    /// unambiguous: the remembered blindness **throws** without reading, while a cache that
    /// dropped it hands back § 3's 44 °C. `source.reads` is 1 either way, which is why the
    /// throw is the discriminator and not the read count.
    ///
    /// **Mutation:** fold `.blind` into the compared branch of
    /// `CriticalTemperatureCache.record(_:since:)` — delete `case .blind: record(sighting)`
    /// and let the `switch` compare both outcomes against `start`. That is where the bypass
    /// lives since [#280](https://github.com/blamechris/Aeolus/issues/280) moved it off the
    /// callers; before that it was this `catch` calling an unguarded `record(_:)`. Run: red
    /// — the second grant is handed a reading on a helper whose last real read of the
    /// machine failed.
    @Test("A flight's blindness is recorded even when a sighting landed while it was away")
    func aFlightsBlindnessIsRecordedEvenWhenASightingLanded() async throws {
        let source = GatedCriticalTemperatures(
            ThrowOnceCriticalTemperatures(
                FanControlPlaneError.readFailed(detail: "stale port"),
                then: try Self.report(celsius: 44)))
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        let grant = observing { try await cache.sighting() }
        let started = await yieldUntil("the grant to reach the source") {
            await source.reads == 1
        }
        #expect(started, "the grant never issued the read this scenario interleaves with")

        // § 3's cycle, mid-flight: the machine answered *it*.
        await cache.recordAsASetupStep(.sighted(try Self.report(celsius: 44)))

        await source.open()
        await #expect(throws: FanControlPlaneError.self) {
            _ = try await finished("the grant", grant)
        }

        await #expect(throws: FanControlPlaneError.self) { _ = try await cache.sighting() }
        #expect(
            await source.reads == 1, "the remembered blindness cost a read of its own anyway")
        #expect(await cache.readsIssued == 1)
        #expect(await cache.coalescedSightings == 1)
    }
}
