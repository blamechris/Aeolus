import Foundation
import os

@testable import AeolusHelper

/// A `MonotonicClock` whose sleeps park until the test moves its hands past them, and end at once
/// when their task is cancelled.
///
/// `TestClock` cannot drive the examination gate: its `sleep(until:)` jumps to the deadline and
/// returns, so every contended wait would run out the moment it began. This one holds a sleep
/// until `advance(by:)` reaches its deadline, so a bound can be checked to the nanosecond, and a
/// clock that is never advanced is frozen: a wait on it ends only by a grant or a cancellation.
///
/// **It honours cancellation**, which is the gate prototype's second gap fixed in the double: the
/// gate cancels a wait's timer however the wait ends, and a clock that ignored that would leave
/// every timer parked for the rest of the process, its task alive behind a sleep nothing resumes.
/// `sleepers` is how a test asserts none was left. The cancellation is read under the lock that
/// parks the sleep, so a sleep cancelled before it parks never parks.
final class ManualClock: MonotonicClock, Sendable {

    private typealias Wake = CheckedContinuation<Void, any Error>

    private struct Sleeper: Sendable {
        let deadline: ContinuousClock.Instant
        let continuation: Wake
    }

    private struct State: Sendable {
        var now: ContinuousClock.Instant
        var issued: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(start: ContinuousClock.Instant = ContinuousClock.now) {
        state = OSAllocatedUnfairLock(initialState: State(now: start))
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }

    /// How many sleeps are parked now.
    var sleepers: Int { state.withLock { $0.sleepers.count } }

    /// Moves the hands by `duration` and ends every sleep whose deadline they reached.
    func advance(by duration: Duration) {
        move(by: duration)
        endDueSleeps()
    }

    /// Moves the hands by `duration` and ends no sleep: the instant has come and no timer has run.
    func move(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    /// Ends every sleep whose deadline the hands have reached.
    func endDueSleeps() {
        let due = state.withLock { state -> [Sleeper] in
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for key in due.keys { state.sleepers[key] = nil }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { state -> UInt64 in
            state.issued &+= 1
            return state.issued
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Wake) in
                enum Now { case cancelled, due, parked }
                let now = state.withLock { state -> Now in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .parked
                }
                switch now {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .parked: break
                }
            }
        } onCancel: {
            let parked = state.withLock { $0.sleepers.removeValue(forKey: id) }
            parked?.continuation.resume(throwing: CancellationError())
        }
    }
}
