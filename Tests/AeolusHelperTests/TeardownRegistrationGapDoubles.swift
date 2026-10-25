import AeolusXPC
import Dispatch
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper

/// The schedule `TeardownRegistrationGapTests` needs, in a file of its own: an acquirer parked
/// before `acquireLease`'s marker that is resumed **inside** a teardown's first job on the lease
/// core, so it runs at that job's first suspension and at no later one.
///
/// ## Why a task executor, and why a serial one
///
/// A resumed continuation is enqueued on the generic executor (the runtime's default
/// `ResumeToExecutor`) and then hops to the actor its code is isolated to. A teardown that yields
/// does the same. The two hops race on the global pool, so "the acquirer runs at the teardown's
/// first suspension" is a probability, not an ordering. Measured on 2026-10-25 with a standalone
/// model of this schedule (its source is in #516's pull request), the parked task missed the gap
/// in 3 of 20,000 runs (release) and 7 of 20,000 (debug) when it was parked on an actor sharing
/// the lease core's executor, and in 1,511 of 50,000 (release) when it was parked in nonisolated
/// code.
///
/// `OneLaneTaskExecutor` removes the race. Both tasks prefer it (SE-0417), so each one's
/// generic-bound resumption is enqueued on one FIFO lane. The acquirer's is enqueued when the
/// gate opens, inside the teardown's job and before anything in that job can suspend. The
/// teardown's own resumption from a suspension can only be enqueued after it suspends, so it
/// is behind the acquirer's. The same model then missed the gap in 0 of 200,000 runs, 100,000
/// in each configuration. Nothing blocks a thread: the acquirer waits on a continuation, and
/// the lane runs each job once, as an executor's own drain does.
///
/// Both tasks are created with the same explicit priority, because a default actor runs
/// higher-priority jobs first.
enum TeardownGapFixture {

    /// What `acquireLease` told one acquirer.
    enum Answer: Sendable, Equatable {
        case granted(UUID)
        case refused(AeolusXPCFault)
        case failed(String)
    }

    /// One acquirer's `Answer`, recorded on the lease core's executor in the same job as the
    /// decision.
    ///
    /// That placement is what makes `openingThenSuspendingOnce(opening:reading:on:)` a
    /// measurement: a record taken after the call returned would be made on the lane after the
    /// hop off the lease core, behind whatever was already queued there.
    final class GrantAnswer: Sendable {

        private let answer = OSAllocatedUnfairLock<Answer?>(initialState: nil)

        var recorded: Answer? { answer.withLock { $0 } }

        func record(_ given: Answer) {
            answer.withLock { $0 = given }
        }
    }

    /// Asks for `request` from `connection` and records the answer before leaving the lease core.
    static func acquiring(
        _ request: LeaseRequest, from connection: ConnectionID,
        answeringInto answer: GrantAnswer, on authority: isolated LeaseAuthority
    ) async {
        do {
            let lease = try await authority.acquireLease(request, from: connection)
            answer.record(.granted(lease.id))
        } catch let fault as AeolusXPCFault {
            answer.record(.refused(fault))
        } catch {
            answer.record(.failed(String(describing: error)))
        }
    }

    /// Opens the gate and tears `connection` down **in one job on the lease core**. The parked
    /// acquirer's resumption is on the lane before `connectionDidInvalidate` begins.
    static func openingThenInvalidating(
        _ connection: ConnectionID, opening gate: ParkingEnvelopeRead,
        on authority: isolated LeaseAuthority
    ) async {
        gate.open()
        await authority.connectionDidInvalidate(connection)
    }

    /// Opens the gate, suspends the lease core's job once, and returns what the acquirer had been
    /// told by the time the job resumed: the measurement that the schedule above can see one
    /// suspension. `nil` means it cannot, and then nothing `openingThenInvalidating` is used to
    /// test is being tested.
    static func openingThenSuspendingOnce(
        opening gate: ParkingEnvelopeRead, reading answer: GrantAnswer,
        on authority: isolated LeaseAuthority
    ) async -> Answer? {
        gate.open()
        await Task.yield()
        return answer.recorded
    }
}

/// One lane: every job a task preferring this executor enqueues runs on one serial queue, once,
/// in the order enqueued.
@available(macOS 15.0, *)
final class OneLaneTaskExecutor: TaskExecutor {

    private let lane = DispatchQueue(label: "dev.aeolus.AeolusHelperTests.one-lane")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        lane.async { job.runSynchronously(on: executor) }
    }
}

/// The bounds read `acquireLease` suspends on last before its marker, parking the first call it
/// is given until `open()`.
///
/// It reads the firmware **before** it parks, so the call has no hop left to make once it is
/// released: the next thing the acquirer does after resuming is return to the lease core. A
/// hop after the park would put a second suspension between the acquirer's resumption and its
/// decision, and the teardown would win that one.
///
/// Every later call reads through without parking: that is the holder's grant, which must not
/// wait on the newcomer.
final class ParkingEnvelopeRead: FanEnvelopeReading {

    private struct State {
        var isArmed = true
        var isOpen = false
        var parked: CheckedContinuation<Void, Never>?
    }

    private let wrapped: any FanEnvelopeReading
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(over wrapped: any FanEnvelopeReading) {
        self.wrapped = wrapped
    }

    /// Whether the first read is parked here now.
    var isParked: Bool { state.withLock { $0.parked != nil } }

    /// Releases the parked read, if any, and stops parking. Synchronous, so it can be called from
    /// inside a job on the lease core without that job suspending.
    func open() {
        let parked = state.withLock { state in
            state.isOpen = true
            defer { state.parked = nil }
            return state.parked
        }
        parked?.resume()
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        let envelope = try await wrapped.readEnvelope(ofFan: index)
        let parks = state.withLock { state in
            defer { state.isArmed = false }
            return state.isArmed && !state.isOpen
        }
        guard parks else { return envelope }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let opened = state.withLock { state in
                if !state.isOpen { state.parked = continuation }
                return state.isOpen
            }
            if opened { continuation.resume() }
        }
        return envelope
    }
}
