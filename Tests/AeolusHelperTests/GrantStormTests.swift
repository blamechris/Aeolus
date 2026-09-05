import AeolusXPC
import SMCCore
import Testing

@testable import AeolusHelper

/// [#134](https://github.com/blamechris/Aeolus/issues/134) end to end: a client storming
/// `acquireLease` cannot push `docs/SAFETY.md` § 3's cycle down the queue.
///
/// ## Why this is not a cache test
///
/// `CriticalTemperatureCacheTests` asserts the four properties the cache promises. None of
/// them says anything about `SMCReadScheduler`, and the defect #134 is about lives entirely
/// in the scheduler's queue: within `.supervisor` it is FIFO, so *N* outstanding reads admit
/// the last `N + (N - 1) / maxConsecutiveOvertakes` turns after it queues, and the § 3 cycle
/// is one of those *N* with no standing among them. Cache the reads and the count falls; the
/// only way to *see* that it falls is to put the real scheduler underneath and count turns
/// at the provider.
///
/// So the wiring here is the shipped wiring: `GatedSensorProvider` → the real
/// `SMCReadScheduler` → the real `SMCFanControlPlane` → the real
/// `CuratedCriticalTemperatures` → the real `CriticalTemperatureCache`, with the real
/// `LeaseAuthority` and the real `ThermalEmergency` above it. The only doubles are the
/// provider — whose timing the test owns, so nothing depends on how fast the machine running
/// it is — and the lease core's enumeration and restorer, neither of which touches the SMC.
///
/// ## Why turns are counted rather than reads identified
///
/// The grant path and the cycle read the **same 34 curated keys**, because in the daemon they
/// share one `CuratedCriticalTemperatures` over one `CriticalSensorSet` — and
/// `CriticalSensorSet`'s initialiser is private precisely so no test can mint a distinguishing
/// set. Two turns in the provider's trace are therefore indistinguishable by content, and the
/// trace is read by *position* instead: the cycle is the last read issued, so the number of
/// turns that reached the provider by the time it completes is its index plus one.
///
/// `.timeLimit` for `SchedulerTurnLifecycleTests`'s reason: a scheduler that stops granting
/// turns makes a task join hang, and a green suite must mean the tests ran.
@Suite("A grant storm against the safety cycle", .timeLimit(.minutes(1)))
struct GrantStormTests {

    /// The number of concurrent `acquireLease` calls, from #134's own worst case.
    ///
    /// Twelve is the N the issue derives its 17-turn figure from. It is not a bound on
    /// anything — a client can retry faster — which is exactly why the answer had to be
    /// coalescing rather than a bigger number somewhere.
    private static let stormSize = 12

    /// **Acceptance criterion 1**, and the whole of #134 in one test.
    ///
    /// The shape, step by step, because each step is load-bearing:
    ///
    /// 1. The provider holds every subset read, so nothing completes until this test says so
    ///    and the queue state is a fact rather than a race.
    /// 2. Twelve `acquireLease` calls are started. Each reaches `refuseIfBlind`, which proves
    ///    sightedness through the cache. The first finds it cold and issues one real read —
    ///    which takes the connection and parks in the provider. The other eleven join that
    ///    flight and take **no turn at all**.
    /// 3. Only then is § 3's cycle started, so FIFO puts it behind whatever the storm queued.
    /// 4. `queuedTurns(at: .supervisor)` is sampled while everything is held. Coalesced, the
    ///    only supervisor turn queued is the cycle's: **at most one**. Uncoalesced it is
    ///    twelve.
    /// 5. The gate is opened and the cycle is awaited. The cycle's read is the last one
    ///    issued, so `provider.turns.count` when it finishes is its index plus one — and the
    ///    ruling's bound is index ≤ 3.
    ///
    /// The wait at step 3 is on `coalescedSightings`, not on a timer and not on a fixed
    /// number of yields: it is the one fact that says every one of the twelve has arrived and
    /// none of them will ever queue a turn. Under the mutation it never reaches eleven, so
    /// the wait records an issue and the test goes on to fail the counts as well — three
    /// failures for one edit.
    ///
    /// **Mutation:** replace `sighting()`'s body with a direct
    /// `try await source.readCriticalTemperatures()` — #134's "today's code". Run: red on the
    /// coalescing wait, red on `queuedTurns` (12, not ≤ 1), and red on the cycle's index
    /// (12, not ≤ 3).
    @Test("The safety cycle is not delayed by a grant storm")
    func theSafetyCycleIsNotDelayedByAGrantStorm() async throws {
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider)
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: InertSMCConnection())
        let telemetry = CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
        let sightings = CriticalTemperatureCache(source: telemetry)
        let latch = ThermalEmergencyLatch()

        // `writeCapability` is a scripted plane rather than `plane`, because
        // `SMCFanControlPlane` answers `.notBuilt` and `acquireLease` refuses on that
        // *before* it proves sightedness — so every grant would return without reading and
        // the storm would be no storm at all.
        let leases = LeaseFixture.authority(
            writeCapability: LeaseFixture.writePathBuilt(),
            telemetry: sightings,
            thermalEmergency: latch)
        let emergency = ThermalEmergency(
            telemetry: telemetry,
            sightings: sightings,
            writer: SafetyActorWriter(plane: plane, level: .thermalEmergency),
            leases: leases,
            latch: latch)

        let storm = (0..<Self.stormSize).map { _ in
            observing {
                try await leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
            }
        }
        let coalesced = await yieldUntil("every grant to share the one read") {
            await sightings.coalescedSightings == Self.stormSize - 1
        }
        let readsIssued = await sightings.readsIssued
        #expect(
            coalesced,
            """
            the storm did not coalesce: \(readsIssued) reads issued for \(Self.stormSize) \
            grants. Every one of them is a `.supervisor` turn queued ahead of § 3's cycle.
            """)

        // § 3's cycle, started last so that FIFO gives it the worst place in line the storm
        // can produce.
        let cycle = observing { await emergency.cycle() }
        _ = await yieldUntil("the safety cycle to queue behind the storm") {
            await scheduler.queuedTurns(at: .supervisor) >= 1
        }

        let queued = await scheduler.queuedTurns(at: .supervisor)
        #expect(
            queued <= 1,
            """
            \(queued) supervisor turns are queued. § 3's cycle should be behind at most one \
            — the single coalesced grant-time read.
            """)

        await provider.releaseEveryTurn()
        try await finished("the safety cycle", cycle)
        for (index, grant) in storm.enumerated() {
            // Waited on rather than joined: one grant is granted and eleven are refused
            // `.leaseHeldByAnotherClient`, so the *values* are not the point and joining
            // would rethrow eleven expected refusals. What matters is that none is still
            // parked inside the cache, because the trace is read below and a grant that
            // arrived late would still be adding to it.
            await yieldUntil("grant \(index) to complete") { await grant.isFinished.isSet }
        }

        // The cycle is the last read issued, so its position in the trace is the number of
        // turns that reached the provider before it. Two, coalesced: one grant-time read and
        // the cycle's own.
        let turns = await provider.turns
        #expect(
            turns.count <= 4,
            """
            the safety cycle's read landed at index \(turns.count - 1); the ruling's bound \
            is 3. Trace: \(turns.map(\.count)) keys per turn.
            """)
        #expect(
            turns.count == 2,
            "coalesced, a twelve-grant storm plus one cycle is exactly two supervisor turns")
        #expect(await provider.peakConcurrentTurns == 1, "the connection was shared")
    }
}
