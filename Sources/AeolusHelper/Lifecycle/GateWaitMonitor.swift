import os

/// One read parked at the scheduler's gate, as the watchdog reads it: which queue, which
/// waiter, how long, and how many are behind the same gate.
struct GateWait: Sendable, Equatable {
    let priority: SMCReadPriority
    /// Strictly increasing across the life of one monitor, so two readings with the same
    /// ticket are the same waiter. This is what lets a watchdog log one `.fault` per waiter
    /// and not one per tick.
    let ticket: UInt64
    /// How long it has been parked, measured on the suspending clock.
    let age: Duration
    /// How many are parked at `priority`, this one included.
    let depth: Int
}

/// A mirror of the scheduler's parked queues, built from the two events it already reports,
/// so that the liveness watchdog can ask how long the oldest waiter at each priority has
/// waited (ADR 0012's third trigger, [#135](https://github.com/blamechris/Aeolus/issues/135)).
///
/// ## Why a mirror, and why it asks nothing of the scheduler
///
/// `SMCReadScheduler.takeTurn` parks a waiter on a continuation that **only the scheduler
/// resumes**, deliberately: the gate is not cancellable. The consequence is that a turn taken
/// and not given back parks every later read for good, with no throw, no log line and no
/// timeout. Nothing that completes can report that, because nothing completes. So the question
/// "has a waiter been parked too long" is put to an observer that holds its own record, under
/// its own lock, and never enters the scheduler: the scheduler is an actor whose state is
/// exactly what is stuck.
///
/// ## What it holds
///
/// A FIFO of waiters per priority, in the order the scheduler reported them parked. The
/// scheduler grants the head of one queue each time, so the head is the oldest and is the only
/// waiter whose age matters: if the head is not past the bound, nobody behind it is.
///
/// ## A grant takes out the waiter it names, and a fast-path grant takes out nobody
///
/// `turnGranted` carries the `queuedAt` the waiter was parked with, and the scheduler's fast
/// path reports a grant whose `queuedAt` is **its own grant instant** with no waiter behind it
/// (`takeTurn`: the fast path is taken only when both queues are empty). So the mirror takes
/// out the waiter at that priority whose `queuedAt` equals the grant's, and a grant that matches
/// none is the fast path and pops nothing. The alternative, to pop the head of the queue on
/// every grant, is right only while the mirror is in step with the scheduler, and when it is
/// not, it removes a waiter that is still parked and hides the very thing this exists to see.
///
/// ## Its own clock, and the comparer mints the instant
///
/// A waiter's age is measured on the **suspending** clock from the moment this monitor heard it
/// parked, and "now" is read when the age is asked for, never when the waiter parked. The
/// scheduler's `queuedAt` is a `ContinuousClock` instant for naming a waiter, and it is not
/// used as a start of waiting, for ADR 0012's reason: a waiter parked across a sleep must not
/// age by the sleep. Nor is this the composition's `MonotonicClock`, which is the continuous
/// clock too.
///
/// ## What it must not do
///
/// It never resumes, drops or holds a continuation, and the file names none: the gate stays
/// non-cancellable, and a monitor that could release a waiter would be a second owner of the
/// turn. It names no connection either (`WatchdogTripwireTests` holds both). Its lock is held
/// for an append, a removal or a copy, and never across anything else, which is what
/// `SchedulerObserving` asks of a conformer: this is called from inside the scheduler's own
/// isolation.
///
/// Sendable by construction: all state is behind an `OSAllocatedUnfairLock`, so there is no
/// unchecked claim to review.
final class GateWaitMonitor: SchedulerObserving, Sendable {

    /// The clock the mirror ages a waiter on. **This one line is the clock family.** A test
    /// asserts the type, not a clock it built.
    typealias MeasuringClock = SuspendingClock
    typealias Instant = MeasuringClock.Instant

    private struct Parked: Sendable {
        let ticket: UInt64
        /// The scheduler's name for this waiter, matched against a grant. Never an age.
        let queuedAt: ContinuousClock.Instant
        let parkedAt: Instant
    }

    /// The head of one queue, copied out under the lock.
    private struct Head: Sendable {
        let priority: SMCReadPriority
        let parked: Parked
        let depth: Int
    }

    private struct State: Sendable {
        /// Waiters heard parked, ever. A ticket is this value after the increment, so the
        /// first waiter is ticket 1 and 0 is never a ticket.
        var issued: UInt64 = 0
        var queues: [SMCReadPriority: [Parked]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> Instant

    /// `now` is the monitor's own notion of "now", read inside the lock when a waiter parks
    /// and again, after a copy, when an age is asked for. A test injects a clock it can move.
    init(now: @escaping @Sendable () -> Instant = { MeasuringClock.now }) {
        self.now = now
    }

    func schedulerDidObserve(_ event: SchedulerEvent) {
        switch event {
        case .waiterParked(let priority, let queuedAt):
            state.withLock { state in
                state.issued += 1
                state.queues[priority, default: []].append(
                    Parked(ticket: state.issued, queuedAt: queuedAt, parkedAt: now()))
            }
        case .turnGranted(let priority, let queuedAt):
            state.withLock { state in
                guard
                    let index = state.queues[priority]?.firstIndex(where: {
                        $0.queuedAt == queuedAt
                    })
                else { return }
                state.queues[priority]?.remove(at: index)
            }
        default:
            break
        }
    }

    /// The oldest waiter at each priority that has one, with its age as of now and the depth of
    /// its queue. In `SMCReadPriority.allCases` order, so the answer does not depend on
    /// dictionary order.
    ///
    /// Safe to call from any thread: it takes the lock for the length of a copy and never
    /// touches the scheduler. The age is computed **after** the copy, from this monitor's own
    /// clock, so it can never precede the waiter's own start and is never negative.
    func oldestParked() -> [GateWait] {
        let heads = state.withLock { state in
            SMCReadPriority.allCases.compactMap { priority -> Head? in
                guard let queue = state.queues[priority], let first = queue.first else {
                    return nil
                }
                return Head(priority: priority, parked: first, depth: queue.count)
            }
        }
        let asOf = now()
        return heads.map { head in
            GateWait(
                priority: head.priority, ticket: head.parked.ticket,
                age: head.parked.parkedAt.duration(to: asOf), depth: head.depth)
        }
    }

    /// How many waiters are parked at `priority`. Test seam, beside the scheduler's own
    /// `queuedTurns(at:)`: a test asserts that the mirror and the scheduler agree.
    func depth(at priority: SMCReadPriority) -> Int {
        state.withLock { $0.queues[priority]?.count ?? 0 }
    }
}
