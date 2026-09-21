import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// [#205](https://github.com/blamechris/Aeolus/issues/205): a discovery walk reports how it
/// ended, `ConnectionHealth` counts that as one outcome in the same run as every other read,
/// and a walk that never returns raises an alarm rather than going unnoticed.
@Suite("Discovery walk reporting", .timeLimit(.minutes(1)))
struct DiscoveryWalkReportingTests {

    private static func failure() -> SchedulerEvent {
        .wholeReadFailed(priority: .snapshot, detail: "the SMC did not answer")
    }

    private static func drive(_ health: ConnectionHealth, _ events: [SchedulerEvent]) async {
        let target = await health.observedOutcomes + events.count
        for event in events { health.schedulerDidObserve(event) }
        await yieldUntil("every event to be handled") {
            await health.observedOutcomes == target
        }
    }

    private static func health() -> ConnectionHealth {
        ConnectionHealth(clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
    }

    // MARK: - The scheduler reports it

    /// **Mutation:** in `SMCReadScheduler.readAll()`, delete either `report(...)` line.
    /// Run: red — that half of the pair is missing.
    @Test("A walk reports one outcome, whether it returns or throws")
    func aWalkReportsHowItEnded() async throws {
        let observer = RecordingSchedulerObserver()
        let returning = SMCReadScheduler(
            provider: fanProvider(
                fanCount: 0,
                allReadings: [.fake(key: "TC0P", value: 44), .fake(key: "TG0P", value: 41)]),
            observer: observer)
        _ = try await returning.readAll()

        let throwing = SMCReadScheduler(
            provider: fanProvider(
                fanCount: 0,
                readAllErrors: [FakeProviderError(description: "#KEY did not answer")]),
            observer: observer)
        await #expect(throws: (any Error).self) { _ = try await throwing.readAll() }

        let walks = observer.events.filter { $0.kind == .discoveryWalkEnded }
        #expect(walks.count == 2, "two walks ran and \(walks.count) reported ending")
        #expect(walks.first == .discoveryWalkEnded(.returned(readings: 2)))
        guard case .discoveryWalkEnded(.threw) = walks.last else {
            Issue.record("a walk that threw reported \(String(describing: walks.last))")
            return
        }
    }

    // MARK: - ConnectionHealth counts it

    /// The case #205 opens with: a walk failing on a machine whose SMC is already gone.
    ///
    /// **Mutation:** in `ConnectionHealth.handle(_:recovering:)`, replace the body of the
    /// catch-all `case .discoveryWalkEnded:` with `break`. Run: red — no reconnect.
    @Test("A walk that throws is one failure in the same run as subset reads")
    func aThrownWalkJoinsTheRun() async throws {
        let recovery = RecordingReconnector()
        let health = Self.health()
        await health.start(recovering: recovery)

        await Self.drive(
            health,
            [Self.failure(), Self.failure(), .discoveryWalkEnded(.threw(detail: "#KEY failed"))])

        let attempts = await recovery.attempts
        #expect(
            attempts == 1,
            """
            Two subset-read failures and a walk that threw reconnected \
            \(attempts) time(s). The walk is a read of the same handle, so it \
            is the third failure in the run — before #205 it was counted by nothing.
            """)
        await health.stop()
    }

    /// A walk that returns normally with nothing in it is the handle failing, not an absent
    /// key: the walk only asks for keys the machine declared.
    ///
    /// **Mutation:** delete `where readings > 0` from the reset case. Run: red — the empty
    /// walk resets the run instead of completing it.
    @Test("A walk that returns no readings is a failure, not a reset")
    func anEmptyWalkIsAFailure() async throws {
        let recovery = RecordingReconnector()
        let health = Self.health()
        await health.start(recovering: recovery)

        await Self.drive(
            health, [Self.failure(), Self.failure(), .discoveryWalkEnded(.returned(readings: 0))])

        #expect(await recovery.attempts == 1, "an empty walk did not count towards the run")
        await health.stop()
    }

    /// A walk with readings in it proves the handle answered, exactly as one real value
    /// does for a subset read (ruling D25).
    ///
    /// **Mutation:** delete the `case .discoveryWalkEnded(.returned(let readings)) where
    /// readings > 0:` arm, so every walk falls to the failure arm. Run: red.
    @Test("A walk that returns readings resets the run")
    func aWalkWithReadingsResets() async throws {
        let recovery = RecordingReconnector()
        let health = Self.health()
        await health.start(recovering: recovery)

        await Self.drive(
            health,
            [
                Self.failure(), Self.failure(), .discoveryWalkEnded(.returned(readings: 2_930)),
                Self.failure(), Self.failure(),
            ])

        #expect(
            await recovery.attempts == 0,
            "two short runs either side of a walk that returned 2930 readings were counted as one")
        await health.stop()
    }

    // MARK: - The overrun alarm

    private static func authority(
        over provider: GatedSensorProvider, clock: GatedClock
    ) -> ReadOnlyFanAuthority {
        ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: HelperRestorerTests.helperLog,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            writeCapability: LeaseFixture.writePathNotBuilt(),
            clock: clock)
    }

    /// A walk that has not returned when the alarm's sleep ends is reported, and left alone.
    ///
    /// **Mutation:** in `walkEveryKey()`, delete `await self.discoveryWalkOverran()`. Run:
    /// red — the wait for the overrun count gives up.
    @Test("A walk still running at the alarm is reported and not cancelled")
    func aWedgedWalkRaisesTheAlarm() async throws {
        let provider = GatedSensorProvider(holdingReadAll: true)
        let clock = GatedClock()
        let authority = Self.authority(over: provider, clock: clock)

        let snapshot = Task { try? await authority.snapshot() }
        #expect(
            await yieldUntil("the walk to be in flight with its alarm sleeping") {
                let parked = await clock.waiting
                return await provider.readAllIsInFlight && parked == 1
            })

        await clock.release()
        #expect(
            await yieldUntil("the overrun to be reported") {
                await authority.discoveryWalkOverruns == 1
            },
            "a walk still in flight when the alarm woke was not reported")
        #expect(
            await provider.readAllIsInFlight,
            "the alarm ended the walk — it must only report it; see SMCReadScheduler.readAll()")

        await provider.releaseReadAll()
        _ = await snapshot.value
    }

    /// A walk that returned before the alarm woke is not reported.
    ///
    /// `GatedClock` does not honour cancellation, so the alarm's sleep is still parked
    /// after the walk ends and is woken by `release()` — which is exactly what makes the
    /// `Task.isCancelled` check the thing under test.
    ///
    /// **Mutation:** delete `defer { alarm.cancel() }` from `walkEveryKey()`. Run: red.
    @Test("A walk that returned before the alarm woke raises nothing")
    func aFinishedWalkRaisesNothing() async throws {
        let provider = GatedSensorProvider()
        let clock = GatedClock()
        let authority = Self.authority(over: provider, clock: clock)

        _ = try? await authority.snapshot()
        #expect(
            await provider.readAllCount == 1, "the snapshot did not run the discovery walk")
        #expect(
            await yieldUntil("the alarm's sleep to park") { await clock.waiting == 1 })

        await clock.release()
        for _ in 0..<1_000 { await Task.yield() }
        #expect(
            await authority.discoveryWalkOverruns == 0,
            "a walk that had already returned was reported as overrunning")
    }

    /// The alarm sleeps until exactly `discoveryWalkOverrunAlarm` after the walk began.
    ///
    /// `GatedClock` ignores its deadline, so the two tests above would pass with the alarm set
    /// to fire at once — which in production is a false `.fault` on every walk. #290's review
    /// ran that mutation and the whole suite stayed green.
    ///
    /// **Mutation:** in `walkEveryKey()`, replace `let alarmAt = clock.now.advanced(by: …)`
    /// with `let alarmAt = clock.now`. Run: red.
    @Test("The alarm is set for the overrun figure after the walk began, not sooner")
    func theAlarmIsSetForTheOverrunFigure() async throws {
        let provider = GatedSensorProvider(holdingReadAll: true)
        let clock = DeadlineRecordingClock()
        let authority = ReadOnlyFanAuthority(
            provider: provider,
            fanMode: SnapshotFanModeReads(provider: provider),
            log: HelperRestorerTests.helperLog,
            thermalEmergency: ThermalEmergencyLatch(),
            reclamation: ReclamationLedger(),
            writeCapability: LeaseFixture.writePathNotBuilt(),
            clock: clock)

        let snapshot = Task { try? await authority.snapshot() }
        #expect(
            await yieldUntil("the alarm to be set") { await clock.deadlines.count == 1 })
        let deadlines = await clock.deadlines
        #expect(
            deadlines
                == [
                    DeadlineRecordingClock.start.advanced(
                        by: SMCReadScheduler.discoveryWalkOverrunAlarm)
                ],
            "the alarm was set for \(deadlines) rather than the overrun figure")

        await provider.releaseReadAll()
        _ = await snapshot.value
        await clock.release()
    }

    /// The figure is derived from the contended walk, and stays above every measured one.
    ///
    /// **Mutation:** set `discoveryWalkOverrunAlarm` to `longestMeasuredDiscoveryWalk * 3`
    /// — #290's first draft, 17.7 s. Run: red.
    @Test("The alarm fires only past every walk this repository has measured")
    func theAlarmClearsEveryMeasuredWalk() {
        #expect(
            SMCReadScheduler.discoveryWalkOverrunAlarm
                > SMCReadScheduler.longestContendedDiscoveryWalk,
            """
            The overrun alarm is at or below a walk measured under contention on this machine, \
            so running fanctl during the helper's first walk would raise a fault over nothing.
            """)
        #expect(
            SMCReadScheduler.longestContendedDiscoveryWalk
                >= SMCReadScheduler.longestMeasuredDiscoveryWalk)
    }

    // MARK: - An empty walk is not cached

    /// A walk that returned nothing is walked again on the next snapshot, not kept.
    ///
    /// **Mutation:** in `discoverSensorKeys()`, replace
    /// `if !discovered.isEmpty { discoveredSensors = discovered }` with
    /// `discoveredSensors = discovered`. Run: red — the second snapshot never walks.
    @Test("An empty discovery walk is not cached for the life of the daemon")
    func anEmptyWalkIsNotCached() async throws {
        let provider = GatedSensorProvider()
        let authority = Self.authority(over: provider, clock: GatedClock())

        _ = try? await authority.snapshot()
        _ = try? await authority.snapshot()

        #expect(
            await provider.readAllCount == 2,
            """
            The second snapshot did not walk again after a walk that returned nothing. That \
            walk is what a handle that died after #KEY returns, and ConnectionHealth counts it \
            as a failure — caching it keeps the machine sensorless after the rebuild succeeds.
            """)
    }
}

// MARK: - Doubles

/// A clock that records every deadline it is asked to sleep until, and parks the sleeper
/// until released — so a test can read *when* an alarm was set without it firing.
actor DeadlineRecordingClock: MonotonicClock {

    static let start = ContinuousClock.now

    private(set) var deadlines: [ContinuousClock.Instant] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var now: ContinuousClock.Instant { Self.start }

    func sleep(until deadline: ContinuousClock.Instant) async {
        deadlines.append(deadline)
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }
}
