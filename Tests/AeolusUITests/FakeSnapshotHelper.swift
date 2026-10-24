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
///
/// **Every wait here ends when the test is cancelled**, by throwing. A test that waits for a
/// request that never comes is then ended by its `.timeLimit` as a red, instead of holding
/// `swift test` open forever (#478's review, item 13).
actor FakeSnapshotHelper: HelperSnapshotReading {

    struct Closed: Error, LocalizedError {
        var errorDescription: String? { "the fake helper was closed by the test" }
    }

    private var parked: [(id: Int, continuation: CheckedContinuation<SystemSnapshot, any Error>)] =
        []
    private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    private var nextWaiter = 0
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
        resumeWaiters()
        if isClosed { throw Closed() }
        atHelper += 1
        peakAtHelper = max(peakAtHelper, atHelper)
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

    /// Suspends until this fake has seen `count` requests. Throws if the waiting test is
    /// cancelled first — by its time limit, for one — so a request that never comes is a red.
    func waitForRequests(_ count: Int) async throws {
        guard requests < count else { return }
        nextWaiter += 1
        let token = nextWaiter
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[token] = (count: count, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
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

    private func cancelWaiter(_ token: Int) {
        waiters.removeValue(forKey: token)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeWaiters() {
        for (token, waiter) in waiters where waiter.count <= requests {
            waiters.removeValue(forKey: token)
            waiter.continuation.resume()
        }
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

    /// A bounded wait on something an actor holds: yields until `condition` holds, for at most
    /// `turns` turns, and says whether it did. For a step a mutation can stop from happening,
    /// so the mutation is a red at the next line and not a minute's wait.
    @MainActor
    static func eventually(turns: Int = 10_000, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<turns {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    /// A bounded wait for the fake to have seen `count` requests.
    @MainActor
    static func requestsReach(_ count: Int, on helper: FakeSnapshotHelper) async -> Bool {
        await eventually { await helper.requests >= count }
    }

    /// A provider that would answer every direct read — one fan and one sensor — so a view
    /// model that read the SMC when it should not have would succeed at it, and only the read
    /// counts show it did.
    static func directProvider(isAvailable: Bool = true) -> FakeSensorProvider {
        FakeSensorProvider(
            isAvailable: isAvailable,
            allReadings: [.fake(key: "Tp09", value: 42, kind: .temperatureCelsius)],
            keyedResults: [
                "FNum": .success(.fake(key: "FNum", value: 1)),
                "F0Ac": .success(.fake(key: "F0Ac", value: 1712, kind: .rpm)),
                "F0Mn": .success(.fake(key: "F0Mn", value: 1200, kind: .rpm)),
                "F0Mx": .success(.fake(key: "F0Mx", value: 5312, kind: .rpm)),
                "Tp09": .success(.fake(key: "Tp09", value: 44.2, kind: .temperatureCelsius)),
            ])
    }

    /// How many reads a fake provider has served, of either kind.
    static func readCount(_ provider: FakeSensorProvider) async -> Int {
        await provider.readAllCallCount + provider.readKeysCalls.count
    }

    /// A started source whose latest reply is `snapshot`, recorded: the loop has sent its next
    /// request, which it does only after recording the last answer.
    @MainActor
    static func freshSource(
        _ helper: FakeSnapshotHelper, answering snapshot: SystemSnapshot,
        clock: SnapshotTestClock = SnapshotTestClock()
    ) async throws -> HelperSnapshotSource {
        let source = try await handshakenSource(helper, clock: clock)
        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: snapshot)
        try await helper.waitForRequests(2)
        try #require(freshSnapshot(source) == snapshot)
        return source
    }

    /// A source on `helper`, with a hand-wound age clock and an instant pacing clock.
    @MainActor
    static func source(
        _ helper: FakeSnapshotHelper,
        clock: SnapshotTestClock = SnapshotTestClock(),
        pacing: any PollingClock = FakePollingClock(),
        refreshInterval: TimeInterval = 1
    ) -> HelperSnapshotSource {
        HelperSnapshotSource(
            reader: helper, refreshInterval: { refreshInterval }, clock: clock, pacing: pacing)
    }

    /// A source on a helper that reports `.handshaken`, once the source has heard it.
    @MainActor
    static func handshakenSource(
        _ helper: FakeSnapshotHelper,
        clock: SnapshotTestClock = SnapshotTestClock(),
        pacing: any PollingClock = FakePollingClock(),
        refreshInterval: TimeInterval = 1
    ) async throws -> HelperSnapshotSource {
        helper.report(.handshaken)
        let source = source(helper, clock: clock, pacing: pacing, refreshInterval: refreshInterval)
        try #require(await settle { source.health == .handshaken })
        return source
    }

    /// Reports `health` and waits, boundedly, until the source has heard it.
    @MainActor
    static func report(
        _ health: HelperConnectionHealth, to source: HelperSnapshotSource,
        from helper: FakeSnapshotHelper
    ) async throws {
        helper.report(health)
        try #require(await settle { source.health == health })
    }

    /// Stops `source`, fails whatever it is waiting for, and waits — boundedly — for its loop
    /// to end. A loop that does not end is an issue recorded here, never a hang.
    @MainActor
    static func tearDown(
        _ source: HelperSnapshotSource, _ helper: FakeSnapshotHelper,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        while source.consumerCount > 0 { source.stop() }
        await helper.close()
        let ended = await settle { !source.isLoopRunning }
        #expect(
            ended, "the source's loop did not end after its consumers left",
            sourceLocation: sourceLocation)
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
        source.authority().notTracked
    }
}

/// One tag per `HelperConnectionHealth`, with an exhaustive switch and no `default:`, so a
/// state added to the client's vocabulary does not compile in these suites until it is listed —
/// and every argument list below is `allCases`, never a hand-written list.
enum HealthTag: CaseIterable {
    case idle, handshaken, unresponsive, interrupted, invalidated, refused, versionMismatched

    init(_ health: HelperConnectionHealth) {
        switch health {
        case .idle: self = .idle
        case .handshaken: self = .handshaken
        case .unresponsive: self = .unresponsive
        case .interrupted: self = .interrupted
        case .invalidated: self = .invalidated
        case .refused: self = .refused
        case .versionMismatched: self = .versionMismatched
        }
    }

    var health: HelperConnectionHealth {
        switch self {
        case .idle: return .idle
        case .handshaken: return .handshaken
        case .unresponsive: return .unresponsive
        case .interrupted: return .interrupted
        case .invalidated: return .invalidated
        case .refused: return .refused
        case .versionMismatched: return .versionMismatched
        }
    }

    static var all: [HelperConnectionHealth] { allCases.map(\.health) }
    static var departures: [HelperConnectionHealth] { all.filter { $0 != .handshaken } }
}

extension HelperSnapshotSource {
    /// A source with no helper behind it, as in the `Monitor` build: for suites about the
    /// direct-read path, which never consult a helper.
    @MainActor
    static func noHelper() -> HelperSnapshotSource {
        HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
    }
}
