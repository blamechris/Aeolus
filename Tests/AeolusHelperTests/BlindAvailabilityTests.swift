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
            "fan 0's maximum does not read the staged value, so step 8 has nothing to answer")

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        #expect(thrown == .noThermalTelemetry)
        #expect(shown == thrown, "the snapshot says \(shown) where the grant says \(thrown)")
    }

    // MARK: - Where the two part

    /// What a blind machine's fan carries beside the blindness: with `Handback`, one scenario for
    /// every reason other than step 8's that the ladder can state on a seam that can write.
    enum OwnReason: String, CaseIterable, Sendable {
        /// Step 5: the fan's `F<n>Md` does not answer — `.supervisorBlind`.
        case unread
        /// Step 5: another program holds the fan in manual — `.foreignManualControl`.
        case foreign
        /// Step 5: § 3 is keeping the fan, whose accepted handback the firmware discarded —
        /// `.restoreToAutomaticUnconfirmed`.
        case kept
        /// Step 1: the firmware refused every restore of the fan — `.restoreToAutomaticFailed`.
        case abandoned
        /// Step 11: § 4's seal stands — `.systemSleeping`, machine-wide.
        case sleepSeal
        /// Step 10: the machine-wide restore seal is open — `.releaseInProgress`, machine-wide.
        case machineWideSeal
    }

    /// On a blind machine, a fan step 5 refuses, one whose handback was abandoned, and any fan
    /// under either seal keep their own reason in the snapshot while the grant refuses
    /// `.noThermalTelemetry`. Both refuse; the reasons part, by the rule's one exception, and
    /// `SafeState` reads the snapshot's as pending or durable where it would read the grant's as
    /// silent.
    ///
    /// Each scenario is staged while § 3 can see, and the clock then ages any sighting past the
    /// cache's one-period bound, so both sides read the machine blind afresh.
    ///
    /// **Mutation:** in `restatingAvailability`, make `silent` `answer !=
    /// .unavailable(.writePathNotBuilt)` — the rung in strict grant order, below step 6 only. Run:
    /// red on every argument — the snapshot says `.noThermalTelemetry`. **Mutation:** add `||
    /// answer == .unavailable(r)` to `silent`, for `r` each of `.foreignManualControl`,
    /// `.restoreToAutomaticUnconfirmed` and `.releaseInProgress`. Run: red on `foreign`, `kept`
    /// and `machineWideSeal` respectively.
    @Test(
        "A blind machine's fan keeps its own pending or durable reason, and both refuse",
        arguments: OwnReason.allCases)
    func aFansOwnReasonOutranksBlindness(_ own: OwnReason) async throws {
        let writes: ScriptedControlPlane.WriteBehaviour =
            switch own {
            case .abandoned: Fixture.firmwareRefusesTheModeWrite
            case .kept: .reverted
            default: .honoured
            }
        let clock = TestClock()
        let helper = Fixture.composed(
            writes: writes, clock: clock,
            afterwards: [
                Fixture.sightless(writes: writes, unreadableModes: own == .unread ? [0] : [])
            ])
        await helper.bindSafetyRegistries()
        let (expected, lift) = try await Self.stage(own, in: helper)
        await helper.plane.advance()
        clock.advance(by: .seconds(2))

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        try await lift()
        #expect(thrown == .noThermalTelemetry, "§ 3 can see, so the reasons cannot part here")
        #expect(
            shown == expected,
            """
            the snapshot says \(shown) about a fan whose own reason is \(expected): a refusal \
            fanctl auto reads as silent was stated over one it would have waited on.
            """)
    }

    /// Puts fan 0 where `own` names, and returns the reason the snapshot must keep and what ends
    /// the scenario once both sides are read: the machine-wide seal stays open until then.
    private static func stage(
        _ own: OwnReason, in helper: HelperComposition<ScriptedControlPlane>
    ) async throws -> (expected: Reason, lift: @Sendable () async throws -> Void) {
        switch own {
        case .unread:
            return (.supervisorBlind, {})
        case .foreign:
            await helper.plane.setMode(.manual, ofFan: 0)
            return (.foreignManualControl, {})
        case .kept:
            let connection = ConnectionID()
            let lease = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: connection)
            try await HelperRestorerTests.engage(fan: 0, in: helper, under: lease.id)
            await helper.plane.setMode(.manual, ofFan: 0)
            try await helper.leases.releaseLease(id: lease.id, from: connection)
            #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
            return (.restoreToAutomaticUnconfirmed, {})
        case .abandoned:
            try await Fixture.acquireAndRelease(fanAt: 0, in: helper)
            #expect(await helper.leases.fansWithAbandonedHandbacks == [0])
            return (.restoreToAutomaticFailed, {})
        case .sleepSeal:
            await helper.leases.sealForSleep(generation: 1)
            return (.systemSleeping, {})
        case .machineWideSeal:
            let sealed = AsyncSignal()
            let lift = AsyncSignal()
            let leases = helper.leases
            let seal = observing {
                await leases.sealingGrants {
                    await sealed.signal()
                    try? await lift.wait()
                }
            }
            try await sealed.wait()
            return (
                .releaseInProgress,
                {
                    await lift.signal()
                    _ = try await finished("the seal to close", seal)
                }
            )
        }
    }

    /// Which handback register holds a blind machine's fan.
    enum Handback: String, CaseIterable, Sendable {
        /// Step 3: the fan's restore is still running — `.releaseInProgress`.
        case inFlight
        /// Step 2: § 4's budget gave up waiting for it — `.handbackUnconfirmed`.
        case unconfirmed
    }

    /// On a blind machine, a fan mid-handback, or one whose handback outlived § 4's budget, keeps
    /// the register's reason in the snapshot while the grant refuses `.noThermalTelemetry`.
    ///
    /// **Mutation:** add `|| answer == .unavailable(.handbackUnconfirmed)` to `silent`. Run: red
    /// on `unconfirmed`. **Mutation:** add `|| answer == .unavailable(.releaseInProgress)`. Run:
    /// red on `inFlight`.
    @Test(
        "A blind machine's fan in a handback register keeps the register's reason",
        arguments: Handback.allCases)
    func aHandbackOutranksBlindness(_ register: Handback) async throws {
        let clock = TestClock()
        let firmware = Fixture.firmware(
            fanCount: 1, writes: .honoured, afterwards: [Fixture.sightless()])
        let helper = Fixture.wedging(firmware: firmware, clock: clock)
        let parked = try await Fixture.parkedHandback(ofFanAt: 0, in: helper)
        if register == .unconfirmed {
            #expect(await helper.leases.recordUnconfirmedHandbacks() == [0])
        }
        await firmware.advance()
        clock.advance(by: .seconds(2))

        let (shown, thrown) = try await SleepSealAvailabilityTests.reasons(forFanAt: 0, in: helper)

        await helper.plane.release()
        await parked.value
        let expected: Reason = register == .unconfirmed ? .handbackUnconfirmed : .releaseInProgress
        #expect(thrown == .noThermalTelemetry, "§ 3 can see, so the reasons cannot part here")
        #expect(
            shown == expected,
            "the snapshot says \(shown) about a fan whose register's reason is \(expected)")
    }

    // MARK: - What it costs

    /// A snapshot and a grant on a cold, blind machine cost one curated-set read between them: the
    /// snapshot's check is the cache the lease core proves against, so its failure is the grant's
    /// evidence. The clock is frozen, so the snapshot's sighting cannot expire before the grant
    /// asks under a stalled runner, which would make the grant read again (CI run 38906841239).
    ///
    /// **Mutation:** in `HelperComposition`, hand the authority a cache of its own —
    /// `telemetry: CriticalTemperatureCache(source: telemetry, clock: clock)`. Run: red here on
    /// the read count, and in `HelperCompositionTests.onlyOneSightingCacheIsEverBuilt`.
    @Test("A snapshot and a grant on a cold, blind machine read the curated set once")
    func theSnapshotAndTheGrantShareOneSighting() async throws {
        let helper = Fixture.composed(clock: TestClock(), afterwards: [Fixture.sightless()])
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

    /// One snapshot on a seam that can write asks the sightings cache exactly once, cold or warm:
    /// a read of its own on an empty cache, a served sighting on a fresh one. The clock is frozen,
    /// so the warm sighting cannot expire under a slow runner.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.snapshot()`, add `_ = try await isBlind()` above
    /// `let blind = try await isBlind()`. Run: red on both arguments — asked twice.
    @Test(
        "One snapshot on a seam that can write asks the sightings cache once",
        arguments: [false, true])
    func aSnapshotAsksTheCacheOnce(warm: Bool) async throws {
        let helper = Fixture.composed(clock: TestClock())
        await helper.bindSafetyRegistries()
        if warm { _ = try await helper.sightings.sighting() }
        let before = await helper.sightings.readsIssued + helper.sightings.coalescedSightings

        let snapshot = try await helper.authority.snapshot()

        #expect(try Fixture.availability(ofFanAt: 0, in: snapshot) == .available)
        let asked = await helper.sightings.readsIssued + helper.sightings.coalescedSightings
        #expect(
            asked - before == 1,
            "one snapshot asked the sightings cache \(asked - before) times, not once")
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
            control: NoLevelSix(), log: Fixture.helperLog)

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
