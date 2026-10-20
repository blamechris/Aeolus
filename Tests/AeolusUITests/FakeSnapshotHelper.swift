import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing
import os

@testable import AeolusUI

/// A helper whose `snapshot` replies are **parked** until the test releases them.
///
/// An actor double that answered at once would serialise every caller for free, and a "one
/// request in flight" assertion against it would pass for an implementation that sent ten.
/// This one suspends inside `snapshot()` on a continuation the test resumes, and counts how
/// many requests the helper is working on at once — `peakAtHelper` — so a second request sent
/// while the first is outstanding is a number the test can read.
///
/// **A cancelled caller leaves its request at the helper**, as `HelperClient` does: the caller
/// gets `CancellationError` at once, but the message stays in flight with its deadline running
/// (`InFlightMessages`). So a cancelled request still counts toward `peakAtHelper`, and is
/// counted in `cancellations` **synchronously**, from the cancellation handler itself — a
/// `cancel()` made inside `HelperSnapshotSource.stop()` is visible the moment `stop()` returns,
/// with nothing to wait for.
actor FakeSnapshotHelper: HelperSnapshotReading {

    struct Closed: Error, LocalizedError {
        var errorDescription: String? { "the fake helper was closed by the test" }
    }

    private var parked: [(id: Int, continuation: CheckedContinuation<SystemSnapshot, any Error>)] =
        []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var atHelper = 0
    private var isClosed = false

    /// Every `snapshot()` call this fake has seen.
    private(set) var requests = 0
    /// The most requests the helper was working on at once, cancelled ones included.
    private(set) var peakAtHelper = 0

    private let cancelled = OSAllocatedUnfairLock(initialState: 0)
    private let healthState = OSAllocatedUnfairLock(
        initialState: (
            current: HelperConnectionHealth.idle,
            subscribers: [AsyncStream<HelperConnectionHealth>.Continuation]()
        ))

    /// How many callers were cancelled while their request was parked.
    nonisolated var cancellations: Int { cancelled.withLock { $0 } }

    // MARK: - HelperSnapshotReading

    func snapshot() async throws -> SystemSnapshot {
        requests += 1
        let id = requests
        if isClosed { throw Closed() }
        atHelper += 1
        peakAtHelper = max(peakAtHelper, atHelper)
        resumeWaiters()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked.append((id: id, continuation: continuation))
            }
        } onCancel: {
            cancelled.withLock { $0 += 1 }
            Task { await self.callerWasCancelled(id) }
        }
    }

    /// Yields the current health first, as `HelperClient.healthUpdates()` does.
    nonisolated func healthUpdates() -> AsyncStream<HelperConnectionHealth> {
        let (stream, continuation) = AsyncStream.makeStream(of: HelperConnectionHealth.self)
        healthState.withLock { state in
            state.subscribers.append(continuation)
            continuation.yield(state.current)
        }
        return stream
    }

    // MARK: - What the test does

    /// Publishes a new health to every subscriber.
    nonisolated func report(_ health: HelperConnectionHealth) {
        healthState.withLock { state in
            state.current = health
            for subscriber in state.subscribers { subscriber.yield(health) }
        }
    }

    /// Answers the oldest parked request.
    func reply(with snapshot: SystemSnapshot) {
        guard let next = takeOldest() else { return }
        next.continuation.resume(returning: snapshot)
    }

    /// Fails the oldest parked request.
    func fail(with error: any Error) {
        guard let next = takeOldest() else { return }
        next.continuation.resume(throwing: error)
    }

    /// Fails every parked request and every later one: the end of a test, so that no loop is
    /// left parked on this fake.
    func close() {
        isClosed = true
        let all = parked
        parked = []
        atHelper -= all.count
        for entry in all { entry.continuation.resume(throwing: Closed()) }
    }

    /// Suspends until this fake has seen `count` requests.
    func waitForRequests(_ count: Int) async {
        guard requests < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count: count, continuation: continuation))
        }
    }

    // MARK: - Bookkeeping

    private func takeOldest() -> (
        id: Int, continuation: CheckedContinuation<SystemSnapshot, any Error>
    )? {
        guard !parked.isEmpty else {
            Issue.record("the test answered a request, and none is parked")
            return nil
        }
        atHelper -= 1
        return parked.removeFirst()
    }

    /// The caller has gone; the message has not. It stays counted in `atHelper`.
    private func callerWasCancelled(_ id: Int) {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return }
        parked.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.count <= requests }
        waiters.removeAll { $0.count <= requests }
        for waiter in ready { waiter.continuation.resume() }
    }
}

/// A `ContinuousClock`-instant clock the test moves by hand, as `SMCCoreTests`' `SteppedClock`
/// does for the round-trip monitor. `HelperSnapshotSource` only ever reads `now` from it; the
/// waits between requests are on a `PollingClock`.
final class SnapshotTestClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant

    private let base = ContinuousClock.now
    private let elapsed = OSAllocatedUnfairLock(initialState: Duration.zero)

    var now: Instant { base.advanced(by: elapsed.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by amount: Duration) {
        elapsed.withLock { $0 += amount }
    }

    /// Never called by the source. Throws rather than waiting on anything real.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// Fixtures and waits shared by the snapshot suites. Namespaced, so nothing here can shadow a
/// global helper another suite in this target declares.
enum SnapshotTestSupport {

    /// Yields the main actor until `condition` holds, for at most `turns` yields. A suspending
    /// wait, never a blocked thread and never a real clock: what it waits for is another task's
    /// next step, which only needs the actor to be let go.
    @MainActor
    static func settle(turns: Int = 10_000, until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<turns {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// A source on `helper`, with a hand-wound age clock and an instant pacing clock.
    @MainActor
    static func source(
        _ helper: FakeSnapshotHelper,
        clock: SnapshotTestClock = SnapshotTestClock(),
        pacing: FakePollingClock = FakePollingClock(),
        refreshInterval: TimeInterval = 1
    ) -> HelperSnapshotSource {
        HelperSnapshotSource(
            reader: helper, refreshInterval: refreshInterval, clock: clock, pacing: pacing)
    }

    /// A source on a helper that reports `.handshaken`, once the source has heard it.
    @MainActor
    static func handshakenSource(
        _ helper: FakeSnapshotHelper,
        clock: SnapshotTestClock = SnapshotTestClock(),
        pacing: FakePollingClock = FakePollingClock(),
        refreshInterval: TimeInterval = 1
    ) async throws -> HelperSnapshotSource {
        helper.report(.handshaken)
        let source = source(helper, clock: clock, pacing: pacing, refreshInterval: refreshInterval)
        try #require(await settle { source.health == .handshaken })
        return source
    }

    /// Stops `source`, fails whatever it is waiting for, and waits for its loop to end.
    @MainActor
    static func tearDown(_ source: HelperSnapshotSource, _ helper: FakeSnapshotHelper) async {
        source.stop()
        await helper.close()
        await source.waitUntilIdle()
    }

    static func fan(
        _ index: Int = 0,
        mode: FanControlMode = .automatic,
        availability: ManualControlAvailability = .unavailable(.writePathNotBuilt),
        reclaimed: Bool = false,
        target: Double? = nil,
        actual: Double = 2345
    ) -> FanState {
        FanState(
            index: index, actualRPM: .measured(actual), minimumRPM: .measured(1350),
            maximumRPM: .measured(5777), targetRPM: target, mode: mode,
            isReclaimedBySystem: reclaimed, manualControlAvailability: availability)
    }

    static func snapshot(
        fans: [FanState] = [fan()],
        sensors: [SensorSample] = [
            SensorSample(key: "Tp09", label: nil, labelConfidence: nil, value: 51.5, unit: .celsius)
        ],
        activeLease: Lease? = nil,
        isThermalEmergencyActive: Bool = false,
        capturedAt: Date = Date()
    ) -> SystemSnapshot {
        SystemSnapshot(
            fans: fans, sensors: sensors, activeLease: activeLease,
            isThermalEmergencyActive: isThermalEmergencyActive, capturedAt: capturedAt)
    }

    /// The snapshot `authority` licenses, or `nil` when it licenses none.
    @MainActor
    static func freshSnapshot(_ source: HelperSnapshotSource) -> SystemSnapshot? {
        guard case .fresh(let snapshot, _) = source.authority() else { return nil }
        return snapshot
    }

    /// Why `authority` licenses nothing, or `nil` when it licenses a snapshot.
    @MainActor
    static func notTracked(_ source: HelperSnapshotSource) -> ControlNotTracked? {
        guard case .notTracked(let why) = source.authority() else { return nil }
        return why
    }
}

extension HelperSnapshotSource {
    /// A source with no helper behind it, as in the `Monitor` build: for suites about the
    /// direct-read path, which never consult a helper.
    @MainActor
    static func noHelper() -> HelperSnapshotSource {
        HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
    }
}
