import FanKit
import Foundation
import Testing
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

/// The same hands as a `Clock`, which is what the XPC client measures its deadlines on.
///
/// `HelperClient` cannot take a `MonotonicClock`: that protocol is the helper's, and the client
/// must not link the daemon. It takes `any Clock<Duration>` instead, and this conformance lets
/// its suite drive a deadline with the double the gate's suite already trusts rather than with
/// a second hand-wound clock. A sleep parks until `advance(by:)` reaches it and ends at once when
/// its task is cancelled, exactly as above; the tolerance is ignored, because no hand moves
/// except when the test moves it.
extension ManualClock: Clock {

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try await sleep(until: deadline)
    }
}

/// Level 6's step as A6's contract has it, before level 6 exists: the fan's examination gate taken
/// as a step, the target written through level 6's `GovernedFanWriter` straight to the plane, the
/// `CommandedTarget` that write returned reported under the lease after it returned, and the gate
/// left (ADR 0014's #383 and A6 amendments, item 3). PR-1's entrant at `.step`, kept for its tests:
/// `LeaseApplier` is the real one, and `LeaseApplierExaminationTests` holds the same orderings
/// with it.
///
/// A fresh writer for each write, so each target is written whole: a `GovernedFanWriter` with no
/// target behind it goes straight to its goal, which is what A6's `hold(_:of:)` does. § 8's ramp
/// is E8a's. Each phase is its own call, so a scenario can hold the gate between a write and its
/// report — the reverse order, which § 5 must never read inside — or never leave it at all.
struct LevelSixStandIn<Writes: FanControlPlane>: Sendable {
    let machine: ReclamationMachine<Writes>

    init(_ machine: ReclamationMachine<Writes>) {
        self.machine = machine
    }

    /// Fan `index`'s permit, minted from its declared condition as the fixture mints one.
    func permit(_ index: Int = 0) throws -> CommandableFan {
        try commandableFan(index, declaring: try #require(machine.fanConditions[index]))
    }

    /// Takes the fan's gate as a step, waiting at most `FanExaminationGate.stepWait`.
    func enter(fanAt index: Int = 0) async -> FanExaminationGate.Pass? {
        await machine.gate.enterForStep(fanAt: index)
    }

    /// Registers the fan under `lease` with § 5, as A6's item 2 does under the same gate.
    func register(_ permit: CommandableFan, under lease: UUID) async throws {
        try await machine.watchdog.manualControlEngaged(permit, under: lease)
    }

    /// Writes `rpm` to the fan through level 6's writer, straight to the plane.
    func write(_ rpm: Double, of permit: CommandableFan) async throws -> CommandedTarget {
        try await GovernedFanWriter(plane: machine.plane)
            .command(towards: rpm, of: permit, since: .zero)
    }

    /// Reports what a write returned, under `lease`.
    func report(_ written: CommandedTarget, under lease: UUID) async {
        await machine.watchdog.commandedTarget(written, under: lease)
    }

    func leave(_ pass: FanExaminationGate.Pass) {
        machine.gate.leave(pass)
    }

    /// One whole step: take the gate, ask whether `lease` is still live and covers the fan, as
    /// level 6 does before it writes, write `rpm`, report it, and leave.
    ///
    /// - Returns: what was written, or `nil` when the gate was refused or the lease had ended.
    func step(
        to rpm: Double, of permit: CommandableFan, under lease: UUID
    ) async throws -> CommandedTarget? {
        guard let pass = await enter(fanAt: permit.index) else { return nil }
        defer { leave(pass) }
        guard await machine.leases.hasLiveLease(id: lease, coveringFan: permit.index) else {
            return nil
        }
        let written = try await write(rpm, of: permit)
        await report(written, under: lease)
        return written
    }
}
