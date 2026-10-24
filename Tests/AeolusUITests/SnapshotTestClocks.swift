import Foundation
import os

@testable import AeolusUI

/// A `PollingClock` whose every sleep **parks** until the test releases it, or until the
/// sleeping task is cancelled — which is how a pause is cut short.
///
/// `FakePollingClock` returns at once, so a loop pacing itself on it never pauses, and "stop()
/// cuts the pause short" is unobservable against it. This one holds each sleeper, counts the
/// sleeps that were cancelled, and lets one step through on `release()`.
actor GatedPollingClock: PollingClock {
    private var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextSleeper = 0
    private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]
    private var nextWaiter = 0

    /// Every `seconds` a sleep was asked for, in call order.
    private(set) var sleptSeconds: [Double] = []
    /// How many sleeps were ended by cancellation rather than by `release()`.
    private(set) var cancelledSleeps = 0

    /// Sleeps parked right now.
    var parkedCount: Int { sleepers.count }

    func sleep(seconds: Double) async throws {
        sleptSeconds.append(seconds)
        nextSleeper += 1
        let token = nextSleeper
        resumeWaiters()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[token] = continuation
            }
        } onCancel: {
            Task { await self.sleeperWasCancelled(token) }
        }
    }

    /// Lets every parked sleep return.
    func release() {
        let all = sleepers
        sleepers = [:]
        for continuation in all.values { continuation.resume() }
    }

    /// Suspends until `count` sleeps have been asked for. Throws if the test is cancelled.
    func waitForSleeps(_ count: Int) async throws {
        guard sleptSeconds.count < count else { return }
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

    private func sleeperWasCancelled(_ token: Int) {
        guard let continuation = sleepers.removeValue(forKey: token) else { return }
        cancelledSleeps += 1
        continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(_ token: Int) {
        waiters.removeValue(forKey: token)?.continuation.resume(throwing: CancellationError())
    }

    private func resumeWaiters() {
        for (token, waiter) in waiters where waiter.count <= sleptSeconds.count {
            waiters.removeValue(forKey: token)
            waiter.continuation.resume()
        }
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

/// A refresh interval a test can change while the source is running, as the preference can.
@MainActor
final class RefreshIntervalBox {
    var seconds: TimeInterval
    init(_ seconds: TimeInterval) { self.seconds = seconds }
}
