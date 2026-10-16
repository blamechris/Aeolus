import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The snapshot states § 3's blindness as the grant does: the ladder's step 12
/// ([#269](https://github.com/blamechris/Aeolus/issues/269)).
///
/// The grant asks `SightednessProving.sighting()` before every per-fan step and refuses
/// `.noThermalTelemetry` when it fails. The snapshot asks the same cache once, on a `.built`
/// seam, and states the refusal last, over `.available` and `.boundsImplausible` only: `SafeState`
/// reads `.noThermalTelemetry` as silent, so stating it over a fan's own pending or durable reason
/// would let `fanctl auto` exit 0 about that fan. Where the two part, both refuse — the documented
/// exception to the ladder's rule, and `FanctlAutoUnreadModeTests` is what it is for.
///
/// § 3 goes blind on the firmware's own stage, `AvailabilityFixture.sightless`: every fan read
/// answers and no critical temperature does, so the curated read throws while the snapshot still
/// reads each fan. The supervisors are not started, so nothing records a sighting but the reads
/// under test.
@Suite("The snapshot states the grant's blindness where it may", .timeLimit(.minutes(1)))
struct BlindAvailabilityTests {

    private typealias Fixture = AvailabilityFixture
    private typealias Reason = ManualControlAvailability.Reason

    /// How many curated-set reads the firmware has been asked for.
    private static func curatedReads(on firmware: ScriptedControlPlane) async -> Int {
        await firmware.attempts.filter {
            if case .readCriticalTemperatures = $0 { return true }
            return false
        }.count
    }

    // MARK: - The rung

    /// On a blind machine, a fan nothing else refuses reads `.noThermalTelemetry`, as the grant
    /// refuses it.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.restatingAvailability(of:observedMode:given:
    /// reconciliation:blind:)`, return `restating(fan, as: answer)`. Run: red — the snapshot says
    /// `.available`.
    @Test("A fan nothing else refuses reads the grant's blindness on a blind machine")
    func aBlindMachineReadsNoThermalTelemetry() async throws {
        let helper = Fixture.composed(afterwards: [Fixture.sightless()])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .noThermalTelemetry, "§ 3 can see, so nothing here is about blindness")
        #expect(
            shown == thrown,
            """
            the snapshot says \(shown) while every grant is refused \(thrown): a client is \
            offered control on a machine nothing is watching.
            """)
    }

    /// A blind machine's fan with implausible bounds reads `.noThermalTelemetry`, as the grant
    /// refuses it: the grant asks blindness before its bounds read, and step 12 re-states step 8,
    /// which `fanctl auto` reads as silent too. The firmware scripts `F0Mx` once, for both sides.
    ///
    /// **Mutation:** in `restatingAvailability`, make `silent` `answer == .available`. Run: red —
    /// the snapshot says `.boundsImplausible`.
    @Test("A blind machine's fan with implausible bounds reads the grant's blindness")
    func blindnessOutranksImplausibleBounds() async throws {
        let helper = Fixture.composed(
            afterwards: [Fixture.sightless(maximumReads: [0: Fixture.byteSwappedMaximum])])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        #expect(
            try await helper.plane.firmwareBound(.maximum, ofFan: 0) == Fixture.byteSwappedBound,
            "fan 0's maximum reads plausible, so step 8 has nothing to answer")

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .noThermalTelemetry)
        #expect(shown == thrown, "the snapshot says \(shown) where the grant says \(thrown)")
    }

    // MARK: - Where the two part

    /// What a blind machine's fan carries beside the blindness.
    enum OwnReason: String, CaseIterable, Sendable {
        /// Step 5: the fan's `F<n>Md` does not answer — pending.
        case unread
        /// Step 1: the firmware refused every restore of the fan — durable.
        case abandoned
        /// Step 11: § 4's seal stands — pending, and machine-wide.
        case sleepSeal
    }

    /// On a blind machine, a fan whose mode will not read, one whose handback was abandoned, and
    /// any fan under § 4's seal keep their own reason in the snapshot while the grant refuses
    /// `.noThermalTelemetry`. Both refuse; the reasons part, by the rule's one exception, and
    /// `SafeState` reads the snapshot's as pending or durable where it would read the grant's as
    /// silent.
    ///
    /// The abandoned fan's lease is taken while § 3 can see, and the clock then ages that sighting
    /// past the cache's one-period bound, so both sides read the machine blind afresh.
    ///
    /// **Mutation:** in `restatingAvailability`, make `silent` `answer !=
    /// .unavailable(.writePathNotBuilt)` — the rung in strict grant order, below step 6 only. Run:
    /// red on all three — the snapshot says `.noThermalTelemetry`.
    @Test(
        "A blind machine's fan keeps its own pending or durable reason, and both refuse",
        arguments: OwnReason.allCases)
    func aFansOwnReasonOutranksBlindness(_ own: OwnReason) async throws {
        let refused = Fixture.firmwareRefusesTheModeWrite
        let clock = TestClock()
        let helper = Fixture.composed(
            writes: own == .abandoned ? refused : .honoured, clock: clock,
            afterwards: [
                Fixture.sightless(
                    writes: own == .abandoned ? refused : .honoured,
                    unreadableModes: own == .unread ? [0] : [])
            ])
        await helper.bindSafetyRegistries()
        let expected: Reason
        switch own {
        case .unread:
            expected = .supervisorBlind
        case .abandoned:
            try await Fixture.acquireAndRelease(fanAt: 0, in: helper)
            #expect(await helper.leases.fansWithAbandonedHandbacks == [0])
            expected = .restoreToAutomaticFailed
        case .sleepSeal:
            await helper.leases.sealForSleep(generation: 1)
            expected = .systemSleeping
        }
        await helper.plane.advance()
        clock.advance(by: .seconds(2))

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .noThermalTelemetry, "§ 3 can see, so the reasons cannot part here")
        #expect(
            shown == expected,
            """
            the snapshot says \(shown) about a fan whose own reason is \(expected): a refusal \
            fanctl auto reads as silent was stated over one it would have waited on.
            """)
    }

    // MARK: - What it costs

    /// A snapshot and a grant on a cold, blind machine cost one curated-set read between them: the
    /// snapshot's check is the cache the lease core proves against, so its failure is the grant's
    /// evidence.
    ///
    /// **Mutation:** in `HelperComposition`, hand the authority a cache of its own —
    /// `telemetry: CriticalTemperatureCache(source: telemetry, clock: clock)`. Run: red here on
    /// the read count, and in `HelperCompositionTests.onlyOneSightingCacheIsEverBuilt`.
    @Test("A snapshot and a grant on a cold, blind machine read the curated set once")
    func theSnapshotAndTheGrantShareOneSighting() async throws {
        let helper = Fixture.composed(afterwards: [Fixture.sightless()])
        await helper.bindSafetyRegistries()
        await helper.plane.advance()
        let before = await Self.curatedReads(on: helper.plane)

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        #expect(shown == .noThermalTelemetry && thrown == .noThermalTelemetry)
        let reads = await Self.curatedReads(on: helper.plane) - before
        #expect(
            reads == 1,
            "a snapshot and a grant read the curated set \(reads) times: two caches, or none")
    }

    /// On a seam that cannot write the snapshot asks § 3 nothing: no sighting, served or read,
    /// across several snapshots, so every build on `main` keeps its read path as it was.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.isBlind()`, delete the
    /// `writeCapability.writeCapability == .built` guard. Run: red on both counts.
    @Test("On a seam that cannot write, the snapshot asks the sightings cache nothing")
    func aSeamThatCannotWriteAsksNothing() async throws {
        let firmware = Fixture.firmware(fanCount: 1, writes: .honoured)
        let helper = Fixture.composed(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            provider: PlaneBackedProvider(over: firmware, fanCount: 1))

        for _ in 0..<3 {
            let snapshot = try await helper.authority.snapshot()
            #expect(
                try Fixture.availability(ofFanAt: 0, in: snapshot)
                    == .unavailable(.writePathNotBuilt))
        }

        let asked = await helper.sightings.readsIssued + helper.sightings.coalescedSightings
        #expect(asked == 0, "the snapshot asked the sightings cache \(asked) times on .notBuilt")
        #expect(await Self.curatedReads(on: firmware) == 0, "the snapshot read the curated set")
    }

    /// A snapshot cancelled while its sighting is parked throws, rather than reporting the machine
    /// blind: a caller that went away says nothing about the sensors.
    ///
    /// **Mutation:** in `isBlind()`, delete `if error is CancellationError { throw error }`. Run:
    /// red — the snapshot returns, stating `.noThermalTelemetry`.
    @Test("A snapshot cancelled while its sighting is parked throws CancellationError")
    func aCancelledSightingIsNotBlindness() async throws {
        let helper = Fixture.composed()
        let sighting = ParkedSighting()
        let authority = SupervisedFanAuthority(
            reading: helper.reading, leases: helper.leases, reconciliation: helper.reconciliation,
            keystone: helper.plane, writeCapability: helper.plane, telemetry: sighting,
            log: Fixture.helperLog)

        let snapshot = Task { try await authority.snapshot() }
        await yieldUntil("the snapshot's sighting to park") { await sighting.parked == 1 }
        snapshot.cancel()

        await #expect(throws: CancellationError.self) { _ = try await snapshot.value }
    }

    /// A blind machine polled at 1 Hz adds no log line per snapshot: the check logs nothing of its
    /// own, and the curated read's failure is not a degradation the memo reports.
    ///
    /// Every log the snapshot path can reach records here, and the clock advances one cache period
    /// per poll, so the cache serves the blindness and re-reads it in turn.
    ///
    /// **Mutation:** in `isBlind()`'s `catch`, log the blindness as `refuseIfBlind` does — `log
    /// .sensorRefreshFailed(reason: String(describing: error))` before `return true`. Run: red.
    @Test("A blind machine polled at 1 Hz adds no log line per snapshot")
    func aBlindMachinePolledAtOneHertzLogsNothingPerSnapshot() async throws {
        let lines = LineCount()
        let clock = TestClock()
        let firmware = Fixture.firmware(
            fanCount: 1, writes: .honoured, afterwards: [Fixture.sightless()])
        let helper = HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: HelperLog(recording: { _, _ in lines.add() }),
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { _, _ in lines.add() }),
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        await helper.bindSafetyRegistries()
        await firmware.advance()

        _ = try await helper.authority.snapshot()
        let afterFirst = lines.count
        for _ in 0..<5 {
            clock.advance(by: .seconds(1))
            let snapshot = try await helper.authority.snapshot()
            #expect(
                try Fixture.availability(ofFanAt: 0, in: snapshot)
                    == .unavailable(.noThermalTelemetry), "the machine is not blind")
        }

        #expect(await helper.sightings.readsIssued > 1, "the cache never read the machine again")
        #expect(
            lines.count == afterFirst,
            "\(lines.count - afterFirst) lines were logged across five snapshots of a blind machine"
        )
    }
}

/// A `SightednessProving` whose every `sighting()` parks until it is cancelled, and then throws
/// `CancellationError`. A continuation, so nothing blocks a thread.
private actor ParkedSighting: SightednessProving {
    private var waiters: [CheckedContinuation<CriticalTemperatureReport, any Error>] = []

    /// Sightings parked right now.
    var parked: Int { waiters.count }

    func sighting() async throws -> CriticalTemperatureReport {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func cancelAll() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(throwing: CancellationError()) }
    }
}

/// How many lines every recording log has been handed. `NSLock` rather than an actor, so a log's
/// synchronous sink can count without an `await`, as `RecordedLog` does.
private final class LineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var lines = 0

    func add() { lock.withLock { lines += 1 } }

    var count: Int { lock.withLock { lines } }
}
