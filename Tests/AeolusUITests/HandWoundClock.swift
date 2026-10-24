import Foundation
import os

@testable import AeolusUI

/// A `HeartbeatClock` whose hands move only when the test moves them: the shape of the helper
/// suite's `ManualClock`, written again here because `AeolusUITests` cannot link the helper's
/// tests.
///
/// A sleep parks until `advance(to:)` reaches its deadline, and a deadline already reached returns
/// at once. It honours cancellation: a cancelled sleep is removed and throws, so a heartbeat the
/// driver stops leaves nothing parked.
///
/// **What the test waits on is the clock's own state, never a real duration.** `untilParked(_:)`
/// suspends until the parked deadlines satisfy a condition, so "the heartbeat has re-armed for 20
/// seconds" is something a test can wait for exactly, and a wait never spends wall-clock time
/// against a budget. Nothing here blocks a thread: every wait is a continuation.
final class HandWoundClock: HeartbeatClock, Sendable {

    private typealias Wake = CheckedContinuation<Void, any Error>
    private typealias Wakeups = [CheckedContinuation<Void, Never>]

    private struct Sleeper: Sendable {
        let deadline: ContinuousClock.Instant
        let continuation: Wake
    }

    private struct Watcher: Sendable {
        let satisfied: @Sendable ([ContinuousClock.Instant]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now: ContinuousClock.Instant
        var issued: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var watchers: [UInt64: Watcher] = [:]

        var deadlines: [ContinuousClock.Instant] { sleepers.values.map(\.deadline).sorted() }

        /// Removes and returns every watcher whose condition now holds.
        mutating func satisfiedWatchers() -> Wakeups {
            let parked = deadlines
            let ready = watchers.filter { $0.value.satisfied(parked) }
            for key in ready.keys { watchers[key] = nil }
            return ready.values.map(\.continuation)
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(start: ContinuousClock.Instant = ContinuousClock.now) {
        state = OSAllocatedUnfairLock(initialState: State(now: start))
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }

    /// The deadlines of the sleeps parked now, ascending.
    var parked: [ContinuousClock.Instant] { state.withLock { $0.deadlines } }

    /// Moves the hands to `instant`, never backwards, and ends every sleep it reaches.
    func advance(to instant: ContinuousClock.Instant) {
        let (due, watchers) = state.withLock { state -> ([Sleeper], Wakeups) in
            if instant > state.now { state.now = instant }
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for key in due.keys { state.sleepers[key] = nil }
            return (Array(due.values), state.satisfiedWatchers())
        }
        for sleeper in due { sleeper.continuation.resume() }
        for watcher in watchers { watcher.resume() }
    }

    func advance(by duration: Duration) {
        advance(to: now.advanced(by: duration))
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = state.withLock { state -> UInt64 in
            state.issued &+= 1
            return state.issued
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Wake) in
                enum Now { case cancelled, due, parked }
                let (now, watchers) = state.withLock { state -> (Now, Wakeups) in
                    if Task.isCancelled { return (.cancelled, []) }
                    if deadline <= state.now { return (.due, []) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return (.parked, state.satisfiedWatchers())
                }
                for watcher in watchers { watcher.resume() }
                switch now {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .parked: break
                }
            }
        } onCancel: {
            let (parked, watchers) = state.withLock { state -> (Sleeper?, Wakeups) in
                let parked = state.sleepers.removeValue(forKey: id)
                return (parked, state.satisfiedWatchers())
            }
            parked?.continuation.resume(throwing: CancellationError())
            for watcher in watchers { watcher.resume() }
        }
    }

    /// Suspends until the parked deadlines satisfy `condition`, or the calling task is cancelled.
    func untilParked(_ condition: @escaping @Sendable ([ContinuousClock.Instant]) -> Bool) async {
        let id = state.withLock { state -> UInt64 in
            state.issued &+= 1
            return state.issued
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state -> Bool in
                    if Task.isCancelled || condition(state.deadlines) { return true }
                    state.watchers[id] = Watcher(satisfied: condition, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let watcher = state.withLock { $0.watchers.removeValue(forKey: id) }
            watcher?.continuation.resume()
        }
    }

    /// Suspends until a sleep is parked with exactly `deadline`.
    func untilParked(at deadline: ContinuousClock.Instant) async {
        await untilParked { $0.contains(deadline) }
    }
}
