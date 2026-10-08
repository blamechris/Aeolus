import Foundation
import os

/// How recently `docs/SAFETY.md` § 3 last finished a cycle, as the liveness watchdog reads
/// it (ADR 0012 I4, and the amendment's "Which clock the progress and bring-up triggers age
/// on").
///
/// The round-trip trigger watches one call that has not returned. This is the other half: §
/// 3 starved without any single call being stuck — a connection actor held by something that
/// is not a stamped round trip, a loop parked in an `await` that never resumes, a bring-up
/// that returned without starting the supervisors. Nothing else in the process would notice
/// any of those, and a § 3 that has stopped looking is the mechanism the lease's whole
/// premise rests on.
///
/// ## The clock is the suspending clock, and it is this type's own
///
/// `MeasuringClock` is one line, and it is the decision. A `ContinuousClock` keeps counting
/// while the machine sleeps; the supervisors are not stopped across a sleep, so on a
/// continuous clock the first two ticks after an hour-long lid close would both see an hour
/// since the last cycle and end the helper `.blind`, dropping every lease. On the suspending
/// clock the sleep does not count and the first cycle after a wake is held to the same bound
/// as any other. **Never the composition's `MonotonicClock`**: that one is `ContinuousClock`,
/// because a lease must keep running while the machine sleeps. The helper measures time on
/// two clock families on purpose (ADR 0012, "Two clock families in the helper"), and unifying
/// them is not a tidy-up.
///
/// There is **no wake allowance**. A grace window after a wake would hide a genuine stall on
/// exactly the transition where the SMC is least observed, and it would be a number with
/// nothing measured behind it. If the first read after a wake proves slower than 50 ms,
/// raise D (ADR 0012, same section).
///
/// ## The comparer mints the instant
///
/// `reading()` takes "now" itself, from the clock it was given. No caller hands it an instant
/// to compare against, because a caller-stamped instant under a test's frozen clock compares
/// a value against itself and the guard goes silently dead. The same rule `SMCRoundTripMonitor`
/// follows for the same reason.
///
/// ## Phases
///
/// - **Disarmed** until the watchdog is armed, and again after the supervisor is stopped. A
///   stopped supervisor is not a stall: teardown stops § 3 on purpose, and the watchdog
///   stays armed through it for the round-trip trigger alone.
/// - **Bring-up** from the watchdog being armed (the first statement of
///   `HelperComposition.bringUp()`) until `ThermalSupervisor.start()`. Bounded by
///   `WatchdogLimits.bringUpBound`.
/// - **Cycling** from `ThermalSupervisor.start()` until `stop()`. Bounded by
///   `WatchdogLimits.cycleBound`.
///
/// ## A completed cycle
///
/// One for which `ThermalEmergency.cycle()` returned `true`, which it does on every exit after
/// its reentrancy guard, the blind path included. A cycle the guard dropped returns `false`
/// and `ThermalSupervisor` does not call `recordCompletion()` for it: otherwise a replacement
/// loop whose entries the guard keeps dropping would advance the count every second while the
/// outgoing cycle sat parked in an await that is not a round trip, and neither bound would
/// ever fire.
///
/// Sendable by construction: all state is behind an `OSAllocatedUnfairLock`, so there is no
/// unchecked claim to review. The lock is never held across anything but a copy.
final class ThermalCycleProgress: Sendable {

    /// The clock the progress ages on. **This one line is the clock family.** A test asserts
    /// the type, not a clock it built.
    typealias MeasuringClock = SuspendingClock
    typealias Instant = MeasuringClock.Instant

    enum Phase: Sendable, Hashable {
        case disarmed
        case bringUp
        case cycling
    }

    /// One reading: what phase, how many cycles have completed, and how long ago the last
    /// completion (or the start of the phase, if none has) was.
    struct Reading: Sendable, Equatable {
        let phase: Phase
        /// Cycles completed since this object was made. Identifies "the same stall" across
        /// ticks: the count does not move while nothing completes.
        let completions: UInt64
        /// Measured on the suspending clock, from the later of the last completion and the
        /// start of the current phase. Never negative.
        let sinceLastCompletion: Duration
    }

    private struct State: Sendable {
        var phase = Phase.disarmed
        var completions: UInt64 = 0
        /// The later of the last completion and the last phase change.
        var anchor: Instant
    }

    private let state: OSAllocatedUnfairLock<State>
    private let now: @Sendable () -> Instant

    init(now: @escaping @Sendable () -> Instant = { MeasuringClock.now }) {
        self.now = now
        self.state = OSAllocatedUnfairLock(initialState: State(anchor: now()))
    }

    // MARK: - Transitions

    /// Bring-up begins. Called when the watchdog is armed.
    func beginBringUp() {
        let instant = now()
        state.withLock {
            $0.phase = .bringUp
            $0.anchor = instant
        }
    }

    /// The supervisor started. The last completion is now: the first cycle is held to the same
    /// bound as every later one, measured from the moment it could begin.
    func beginCycling() {
        let instant = now()
        state.withLock {
            $0.phase = .cycling
            $0.anchor = instant
        }
    }

    /// The supervisor was stopped. Only a **cycling** phase is disarmed: stopping a supervisor
    /// that was never started leaves the bring-up bound in force, because a bring-up that has
    /// not yet started the supervisors has not been stopped, it has stalled.
    func endCycling() {
        state.withLock {
            if $0.phase == .cycling { $0.phase = .disarmed }
        }
    }

    /// A cycle completed: `ThermalEmergency.cycle()` returned `true`.
    ///
    /// Counts in any phase and moves no phase: a late completion from a loop that was stopped
    /// must not re-arm anything, and it must not be lost either.
    func recordCompletion() {
        let instant = now()
        state.withLock {
            $0.completions += 1
            $0.anchor = instant
        }
    }

    // MARK: - Reading

    /// The state of progress as of now. "Now" is read **after** the state is copied out, so it
    /// can never precede the anchor and the age is never negative.
    func reading() -> Reading {
        let copy = state.withLock { $0 }
        return Reading(
            phase: copy.phase,
            completions: copy.completions,
            sinceLastCompletion: copy.anchor.duration(to: now()))
    }
}
