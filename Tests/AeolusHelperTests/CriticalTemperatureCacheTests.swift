import AeolusXPC
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The four properties [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md) rests
/// on, each with the mutation that kills it.
///
/// The grant path proves sightedness from § 3's own most recent reading. That is only safe
/// if the cache is honest in four specific ways, and each of them is a way a plausible
/// implementation would be wrong:
///
/// 1. A cache with nothing to serve **reads** — it cannot answer "sighted" from an empty
///    memory, which is the `isThermalEmergencyActive: false` literal one seam over.
/// 2. A remembered **failure** refuses. Recording successes only looks tidier and puts the
///    read amplification back on precisely the machine that can least afford it.
/// 3. A reading older than one cycle period is **not** served. The age bound is the whole of
///    what makes sharing the cycle's reading defensible.
/// 4. Concurrent callers share **one** read, so a storm against a cold cache — a stopped
///    supervisor, or the first grant after launch — costs one turn rather than one per
///    caller.
///
/// `GrantStormTests` is the same claim end to end, through the real `SMCReadScheduler`, and
/// this suite is the unit-level statement of each part. Both exist because the composition
/// is where the property is delivered and this is where a broken part is diagnosable.
///
/// `.timeLimit` for `SchedulerTurnLifecycleTests`'s reason: a coalescing bug that parked a
/// caller for ever would otherwise hang rather than fail.
@Suite("§ 3's reading, shared with the grant path", .timeLimit(.minutes(1)))
struct CriticalTemperatureCacheTests {

    /// A machine whose curated keys all read a plausible idle die temperature.
    private static func sightedPlane() -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [:], stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
    }

    private static func curated(
        over plane: ScriptedControlPlane
    ) -> CuratedCriticalTemperatures<ScriptedControlPlane> {
        CuratedCriticalTemperatures(plane: plane, set: .mac16x5)
    }

    /// § 3's cadence, named from the supervisor that runs it.
    ///
    /// Deliberately **not** `CriticalTemperatureCache.defaultMaxAge`: a test that advances a
    /// clock by the constant it is checking cannot detect a change to that constant. See
    /// `aStaleSightingIsNotServed`.
    private static var oneCyclePeriod: Duration {
        ThermalSupervisor<ScriptedControlPlane>.defaultInterval
    }

    private static func report(celsius: Double) throws -> CriticalTemperatureReport {
        try CriticalTemperatureReport(
            readings: [CriticalTemperature(key: smcKey("Tp01"), celsius: celsius)],
            unreadableKeys: [])
    }

    // MARK: - A cold cache reads

    /// The control every other test here depends on, and the one that stops this type being
    /// able to pass by answering "sighted" to everything.
    ///
    /// A helper whose thermal supervisor is not running records nothing, ever — which is the
    /// state during bring-up, and the state `ThermalSupervisor.stop()` leaves behind. The
    /// grant path must then read for itself.
    ///
    /// **Mutation:** replace `sighting()`'s body with a fabricated report —
    /// `try CriticalTemperatureReport(readings: [CriticalTemperature(key: …, celsius: 44)],
    /// unreadableKeys: [])` — which is "answer sighted without evidence" written as compactly
    /// as it can be. Run: red on the reading count and the read count.
    @Test("A cold cache reads for itself rather than assuming the machine can be seen")
    func aColdCacheReads() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        await source.open()
        let cache = CriticalTemperatureCache(source: source)

        let report = try await cache.sighting()

        #expect(report.readings.count == CriticalSensorSet.mac16x5.keys.count)
        #expect(await source.reads == 1)
        #expect(await cache.readsIssued == 1)
        #expect(await cache.coalescedSightings == 0)
    }

    /// The other half of the same control: once § 3 has read, the grant path stops reading.
    ///
    /// This is the *whole* saving, stated as one assertion. Everything else in the suite is
    /// about the conditions under which it is allowed.
    ///
    /// **Mutation:** delete the unexpired-sighting branch at the top of `sighting()` — which
    /// is #134's "today's code" mutation, `sighting()` reading directly. Run: red on both
    /// counts.
    @Test("A recorded sighting is served without touching the SMC")
    func aRecordedSightingIsServedWithoutReading() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        await source.open()
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        await cache.record(.sighted(try Self.report(celsius: 44)))
        let served = try await cache.sighting()

        #expect(served.readings.map(\.celsius) == [44])
        #expect(await source.reads == 0, "a sighting § 3 already took was re-read")
        #expect(await cache.coalescedSightings == 1)
    }

    // MARK: - Failures are remembered too

    /// **Acceptance criterion 2.** A remembered failure refuses.
    ///
    /// The source here is a machine that *can* be seen, which is what makes the mutation
    /// visible: if the blind outcome is not recorded, `sighting()` falls through to a
    /// perfectly healthy read and returns. So this asserts the recording rather than the
    /// machine.
    ///
    /// It matters because a storm arrives during blindness, not instead of it: a client
    /// whose lease was revoked retries, and every retry would issue its own 34-key read on
    /// the one machine that cannot answer any of them. Serving the remembered failure
    /// refuses, which is the safe direction, so the storm is free.
    ///
    /// **Mutation:** record successes only — `guard case .sighted = sighting else { return }`
    /// at the top of `record(_:)`. Run: red, and red in
    /// `aBlindCycleLeavesTheGrantPathRefusing` below.
    @Test("A recorded blindness keeps refusing, without a read of its own")
    func aRecordedBlindnessKeepsRefusing() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        await source.open()
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        await cache.record(.blind(FanControlPlaneError.readFailed(detail: "stale port")))

        await #expect(throws: FanControlPlaneError.self) { _ = try await cache.sighting() }
        #expect(await source.reads == 0, "a remembered blindness cost a read anyway")
        #expect(await cache.coalescedSightings == 1)
    }

    /// The same property reached through `ThermalEmergency.cycle()` rather than through a
    /// hand-written `record(_:)` call.
    ///
    /// The unit test above proves the cache remembers a failure; this proves **§ 3 hands it
    /// one**. Those are different edits away from each other: deleting the
    /// `sightings.record(.blind(error))` line from the cycle's `catch` leaves the test above
    /// green, because it never goes near the cycle.
    ///
    /// **Mutation:** delete `await sightings.record(.blind(error))` from
    /// `ThermalEmergency.cycle()`'s `catch`. Run: red — the grant reads the blind machine
    /// itself, which is one wasted supervisor turn per retry.
    @Test("A blind cycle leaves the grant path refusing from its own reading")
    func aBlindCycleLeavesTheGrantPathRefusing() async throws {
        let machine = ThermalMachine(stages: [.blind()])

        await machine.emergency.cycle()

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            try await machine.acquireWithoutEngaging(fans: [0])
        }
        #expect(
            await machine.sightings.readsIssued == 0,
            "the grant issued a read of its own on a machine § 3 had just found blind")
        #expect(await machine.sightings.coalescedSightings == 1)
    }

    /// The same property on the **success** path, which is where ADR 0010's headline claim
    /// is actually delivered.
    ///
    /// `aBlindCycleLeavesTheGrantPathRefusing` above covers the cycle's `catch`. Its twin on
    /// the `do` branch — `await sightings.record(.sighted(report))` — had no test at all: an
    /// adversarial review deleted that one line and the whole suite stayed green, while it is
    /// the line that makes the grant path free in the daemon's *steady state*. Every other
    /// test in this file reaches the recording through `record(_:)` by hand, and none of them
    /// goes near `ThermalEmergency`.
    ///
    /// 44 °C is `LeaseFixture.nominalDieTemperatures`' idle band, so the cycle sees a healthy
    /// machine, records a sighting, and latches nothing.
    ///
    /// **Mutation (M2c):** delete `await sightings.record(.sighted(report))` from
    /// `ThermalEmergency.cycle()`'s `do` branch. Run: red — the grant re-reads a machine § 3
    /// had just seen, which is one supervisor turn per `acquireLease` and #134 exactly.
    @Test("A sighted cycle leaves the grant path proving from § 3's own reading")
    func aSightedCycleLeavesTheGrantPathProving() async throws {
        let machine = ThermalMachine(stages: [.at(44)])

        await machine.emergency.cycle()
        _ = try await machine.acquireWithoutEngaging(fans: [0])

        #expect(
            await machine.sightings.readsIssued == 0,
            "the grant issued a read of its own on a machine § 3 had just seen")
        #expect(await machine.sightings.coalescedSightings == 1)
        #expect(
            await machine.latch.holding == nil,
            "44 °C is an idle machine: this scenario is about the cycle's success path")
    }

    // MARK: - The age bound

    /// **Acceptance criterion 3.** A reading older than one cycle period is not served.
    ///
    /// The recorded outcome is a *blindness*, so the discriminator is unambiguous: while it
    /// is unexpired the call throws, and once it ages out the call reads a healthy machine
    /// and succeeds. A test that recorded a sighting instead could not tell "served the
    /// stale reading" from "read and got the same answer".
    ///
    /// **The advance is a § 3 cycle period, named from `ThermalSupervisor` rather than from
    /// `CriticalTemperatureCache.defaultMaxAge`, and that is the whole difference between a
    /// test of the bound and a test that cannot fail.** Written against `defaultMaxAge` it
    /// moves *with* the mutation — raise the bound to ten seconds and the advance becomes ten
    /// seconds too, the sighting still ages out, and the suite stays green while the grant
    /// path serves readings ten cycles old. Measured against the cadence the bound is
    /// supposed to describe, the same edit is red. This was found by running the mutation,
    /// not by reading the test.
    ///
    /// **Mutation:** raise `CriticalTemperatureCache.defaultMaxAge` past the cycle period —
    /// `{ .seconds(10) }`. Run: red, because the stale blindness is still being served after
    /// an advance of a little over one cycle period.
    @Test("A sighting older than one cycle period is not served")
    func aStaleSightingIsNotServed() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        await source.open()
        let clock = TestClock()
        let cache = CriticalTemperatureCache(source: source, clock: clock)

        await cache.record(.blind(FanControlPlaneError.readFailed(detail: "stale port")))
        await #expect(throws: FanControlPlaneError.self) { _ = try await cache.sighting() }
        #expect(await source.reads == 0, "the recorded blindness was not being served at all")

        clock.advance(by: Self.oneCyclePeriod + .milliseconds(1))
        let afterAgeing = try await cache.sighting()

        #expect(afterAgeing.readings.isEmpty == false)
        #expect(await source.reads == 1, "an aged-out reading was served instead of re-read")
    }

    /// The age bound is **derived** from § 3's cadence rather than restated beside it.
    ///
    /// Asserted against the source tree, because no runtime check can see the difference: a
    /// hand-written `.seconds(1)` here is equal to `ThermalSupervisor.defaultInterval` today
    /// and would pass every behavioural test in this file — right up until somebody changes
    /// the supervisor's cadence and the staleness bound silently disagrees with it. Both
    /// numbers would still look correct in isolation, which is what makes the drift
    /// invisible.
    ///
    /// **Mutation:** `static var defaultMaxAge: Duration { .seconds(1) }`. Run: red here, and
    /// green everywhere else, which is the whole point of the assertion.
    @Test("The age bound is derived from the cycle period, not a second constant")
    func theAgeBoundIsDerivedFromTheCyclePeriod() throws {
        let url = try #require(
            SeamScanner.swiftFiles().first {
                $0.lastPathComponent == "CriticalTemperatureCache.swift"
            },
            "CriticalTemperatureCache.swift was not found in Sources")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
            .filter { !$0.isWhitespace }

        // Bound to a `Bool` first: `#expect` prints its operands, and passing the `contains`
        // call directly dumps the whole scanned file into the failure — which buries the
        // message that says what broke. `HelperCompositionTests` makes the same point.
        let derivesFromTheCadence =
            code.contains("ThermalSupervisor<SMCFanControlPlane>.defaultInterval")
        #expect(
            derivesFromTheCadence,
            "the staleness bound no longer names the cycle period it is supposed to describe")
        let literals =
            code.contains(".seconds(") || code.contains(".milliseconds(")
            || code.contains(".microseconds(") || code.contains(".nanoseconds(")
        #expect(
            literals == false,
            """
            a Duration literal appeared in CriticalTemperatureCache. The age bound is one \
            § 3 cycle period and is derived from ThermalSupervisor.defaultInterval — a \
            second constant here is a staleness bound that can disagree with the cadence \
            it describes, and both would look right on their own.
            """)
    }

    // MARK: - Single flight

    /// **Acceptance criterion 4.** A stopped supervisor degrades to **one** read per storm,
    /// not one per caller.
    ///
    /// Nothing is ever recorded here, so every one of the twelve callers finds a cold cache
    /// — the state a helper is in during bring-up, and the state a stopped `ThermalSupervisor`
    /// leaves it in for the rest of the process. Without single-flight this is #134 exactly,
    /// with the cache present and buying nothing.
    ///
    /// The gate is what makes it deterministic rather than a race: every caller is inside the
    /// source (or joined to the one that is) before anything is allowed to finish, so the
    /// assertion is about the mechanism and not about which task the pool happened to run
    /// first.
    ///
    /// **Mutation:** delete the `if let joined = inFlight` branch from `sighting()`. Run:
    /// red — twelve reads, twelve outstanding at once, and the wait for the coalesced count
    /// times out.
    @Test("A cold cache serves a storm with one read, shared")
    func aColdCacheSharesOneReadAcrossAStorm() async throws {
        let plane = Self.sightedPlane()
        let source = GatedCriticalTemperatures(Self.curated(over: plane))
        let cache = CriticalTemperatureCache(source: source)

        let storm = (0..<12).map { _ in observing { try await cache.sighting() } }
        let settled = await yieldUntil("every grant to reach the cache") {
            await cache.coalescedSightings == 11
        }
        #expect(settled, "the storm never coalesced onto one read")
        #expect(await source.reads == 1, "each grant issued its own read")
        #expect(await source.peakOutstanding <= 1)

        await source.open()
        for (index, grant) in storm.enumerated() {
            let served = try await finished("grant \(index)", grant)
            #expect(served?.readings.isEmpty == false, "grant \(index) was served nothing")
        }

        #expect(await source.reads == 1, "a joiner read after the flight it joined finished")
        #expect(await cache.readsIssued == 1)
    }

    // MARK: - Cancellation

    /// A cancelled read is **not** remembered as blindness.
    ///
    /// `LeaseAuthority.refuseIfBlind` already argues that `CancellationError` is the one
    /// error that is not a statement about the machine. Remembering one here would be
    /// strictly worse than at that seam: it would be replayed as a cancellation to *other*
    /// clients, none of whom was cancelled, for up to a cycle — and `refuseIfBlind` rethrows
    /// a cancellation rather than converting it, so those clients would be told their own
    /// request was cancelled when it was not. Not recording it costs one real read on the
    /// next grant, which is the fail-safe direction.
    ///
    /// **Mutation:** delete the `guard sighting.isAboutTheMachine` line from `record(_:)`.
    /// Run: red — the second call replays the cancellation instead of reading.
    @Test("A cancelled read is not remembered as blindness")
    func aCancelledReadIsNotRemembered() async throws {
        let source = ThrowOnceCriticalTemperatures(
            CancellationError(), then: try Self.report(celsius: 44))
        let cache = CriticalTemperatureCache(source: source, clock: TestClock())

        await #expect(throws: CancellationError.self) { _ = try await cache.sighting() }

        let served = try await cache.sighting()
        #expect(served.readings.map(\.celsius) == [44])
        #expect(await source.reads == 2, "the cancellation was remembered and replayed")
    }
}

/// Telemetry that throws a given error on its first read and answers with a canned report
/// afterwards.
///
/// `ThrowingTelemetry` in `LeaseTelemetryGateTests` throws for ever, which cannot express
/// "the failure was not remembered" — the second call would fail for its own reason and say
/// nothing about the cache. This one recovers, so the second call's *success* is the
/// assertion.
actor ThrowOnceCriticalTemperatures: CriticalTemperatureSensing {

    private let failure: any Error
    private let recovery: CriticalTemperatureReport
    private(set) var reads = 0

    init(_ failure: any Error, then recovery: CriticalTemperatureReport) {
        self.failure = failure
        self.recovery = recovery
    }

    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        reads += 1
        guard reads > 1 else { throw failure }
        return recovery
    }
}
