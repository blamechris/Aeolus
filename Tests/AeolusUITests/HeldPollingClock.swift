import os

@testable import AeolusUI

/// A `PollingClock` whose sleeps park until the test lets them go, like `GatedPollingClock`,
/// except that letting them go is **synchronous**: `releaseNow()` is called without an `await`,
/// so it happens inside the test's own turn of the main actor.
///
/// It exists for one interleaving (#485's review, D2). A wait in `HelperSnapshotSource` that has
/// run its course must get back onto the main actor before it cuts a pause: its task is the
/// main actor's. Released from the test's turn, it cannot get back until the test lets go of it,
/// so whatever the test does next in that turn — a second interval change — happens first, by
/// isolation and not by luck. `GatedPollingClock.release()` is an actor call, and the test's
/// `await` on it gives the main actor up.
final class HeldPollingClock: PollingClock, Sendable {

    private typealias Waiter = CheckedContinuation<Void, any Error>

    private struct State {
        var parked: [Int: Waiter] = [:]
        var issued = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Sleeps parked now.
    var parkedCount: Int { state.withLock { $0.parked.count } }

    func sleep(seconds: Double) async throws {
        let token = state.withLock { state -> Int in
            state.issued += 1
            return state.issued
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Waiter) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.parked[token] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let parked = state.withLock { $0.parked.removeValue(forKey: token) }
            parked?.resume(throwing: CancellationError())
        }
    }

    /// Lets every parked sleep return, from the caller's own turn.
    func releaseNow() {
        let all = state.withLock { state -> [Waiter] in
            let all = Array(state.parked.values)
            state.parked = [:]
            return all
        }
        for continuation in all { continuation.resume() }
    }
}
