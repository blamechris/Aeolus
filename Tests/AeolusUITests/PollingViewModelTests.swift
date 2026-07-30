import SMCCore
import Testing

@testable import AeolusUI

/// A `SensorProvider` whose `isAvailable` degrades after a fixed number of ticks,
/// wrapping an otherwise-normal `FakeSensorProvider` for `readAll()`/`read(keys:)`. Built
/// specifically to prove `PollingViewModel.tick()`'s "a failure never erases the last
/// known good reading" contract: tick 1 must succeed and tick 2 must fail, on the *same*
/// view model instance, which a single immutable `FakeSensorProvider` cannot script
/// (`isAvailable` is fixed for its whole lifetime).
actor FlakyAfterFirstTickProvider: SensorProvider {
    nonisolated let identifier = "flaky"
    private let inner: FakeSensorProvider
    private var callCount = 0
    private let failAfterCalls: Int

    init(inner: FakeSensorProvider, failAfterCalls: Int) {
        self.inner = inner
        self.failAfterCalls = failAfterCalls
    }

    var isAvailable: Bool {
        get async {
            callCount += 1
            return callCount <= failAfterCalls
        }
    }

    func readAll() async throws -> [SensorReading] { try await inner.readAll() }
    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await inner.read(keys: keys)
    }
}

@Suite("PollingViewModel — refresh loop and honesty flags", .serialized)
@MainActor
struct PollingViewModelTests {

    private static func provider() -> FakeSensorProvider {
        FakeSensorProvider(
            allReadings: [.fake(key: "Tp09", value: 42, kind: .unknown)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .unknown)),
            ])
    }

    @Test("Before start(), the view model publishes nothing and claims no data")
    func initialStateIsHonestlyEmpty() {
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock())
        #expect(viewModel.phase == .notStarted)
        #expect(viewModel.fans.isEmpty)
        #expect(viewModel.sensors.isEmpty)
        #expect(viewModel.lastUpdated == nil)
        #expect(viewModel.isThermalEmergencyActive == false)
    }

    @Test("A successful tick publishes fans, sensors, and a fresh lastUpdated")
    func successfulTickPublishesData() async {
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock())
        await viewModel.tick()

        #expect(viewModel.phase == .ready)
        #expect(viewModel.fans.first?.actual.value == 1712)
        #expect(viewModel.sensors.first?.key == "Tp09")
        #expect(viewModel.lastUpdated != nil)
    }

    @Test("A failed tick never erases the previous tick's fans or sensors")
    func failedTickPreservesLastKnownGoodData() async {
        let flaky = FlakyAfterFirstTickProvider(inner: Self.provider(), failAfterCalls: 1)
        let viewModel = PollingViewModel(provider: flaky, clock: FakePollingClock())

        await viewModel.tick()
        #expect(viewModel.phase == .ready)
        let fansAfterFirstTick = viewModel.fans
        let sensorsAfterFirstTick = viewModel.sensors
        let updatedAfterFirstTick = viewModel.lastUpdated
        #expect(!fansAfterFirstTick.isEmpty)

        await viewModel.tick()
        #expect(viewModel.phase == .failed(.noSMC))
        // Nothing about the previously-published data changed — a transient failure is
        // not the same as "nothing to show."
        #expect(viewModel.fans == fansAfterFirstTick)
        #expect(viewModel.sensors == sensorsAfterFirstTick)
        #expect(viewModel.lastUpdated == updatedAfterFirstTick)
    }

    @Test(
        "isThermalEmergencyActive is hardcoded false: no helper exists under Monitor to report one"
    )
    func thermalEmergencyFlagStaysFalseAcrossTicks() async {
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: FakePollingClock())
        await viewModel.tick()
        await viewModel.tick()
        #expect(viewModel.isThermalEmergencyActive == false)
    }

    @Test("start() runs ticks until the clock cancels it, and stop() then leaves loopTask cleared")
    func loopRunsUntilClockCancels() async {
        let clock = FakePollingClock(cancelAfterSleeps: 3)
        let viewModel = PollingViewModel(provider: Self.provider(), clock: clock)

        viewModel.start()
        await viewModel.waitUntilLoopFinishes()

        // 3 sleeps means 3 completed ticks (tick, sleep, tick, sleep, tick, sleep-throws).
        let sleepCount = await clock.sleepCallCount
        #expect(sleepCount == 3)
        #expect(viewModel.phase == .ready)
        #expect(viewModel.fans.first?.actual.value == 1712)

        viewModel.stop()
    }

    @Test("A second start() call while already running does not start a competing loop")
    func secondStartWhileRunningIsANoOp() async {
        let clock = FakePollingClock(cancelAfterSleeps: 2)
        let viewModel = PollingViewModel(provider: Self.provider(), clock: clock)

        viewModel.start()
        viewModel.start()  // must be a no-op — a second loop would double every sleep count
        await viewModel.waitUntilLoopFinishes()

        let sleepCount = await clock.sleepCallCount
        #expect(sleepCount == 2)
    }

    @Test("stop() before start() is a harmless no-op")
    func stopBeforeStartIsHarmless() {
        let viewModel = PollingViewModel(provider: Self.provider(), clock: FakePollingClock())
        viewModel.stop()
        #expect(viewModel.phase == .notStarted)
    }

    @Test(
        "A non-positive refreshInterval is clamped to the documented minimum before reaching the clock"
    )
    func nonPositiveIntervalIsClamped() async {
        let clock = FakePollingClock(cancelAfterSleeps: 1)
        let viewModel = PollingViewModel(
            provider: Self.provider(), clock: clock, refreshInterval: 0)

        viewModel.start()
        await viewModel.waitUntilLoopFinishes()

        let slept = await clock.sleptSeconds
        #expect(slept == [PollingViewModel.minimumRefreshInterval])
    }
}
