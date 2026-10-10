import Foundation
import os

@testable import AeolusHelper

// The gate monitor's fixtures (ADR 0012, PR C). A waiter is parked and granted by the same two
// events the scheduler emits, with the same identity the scheduler gives them — and time is the
// `WatchdogTimeline` the test moves, so nothing here waits on a clock.

/// A parked turn, as the scheduler names it: the priority queue it joined and the instant it
/// joined at, which is what its grant will carry.
struct ScriptedWaiter: Sendable, Equatable {
    let priority: SMCReadPriority
    let queuedAt: ContinuousClock.Instant
}

/// Emits the scheduler's `waiterParked` and `turnGranted` to a monitor.
///
/// Every waiter gets an instant of its own, so two parked at one priority are told apart the
/// way the scheduler tells them apart. The instants are on the scheduler's clock
/// (`ContinuousClock`), deliberately **not** the monitor's, and nothing here moves with the
/// timeline: a monitor that aged a waiter from the scheduler's instant would be wrong in a way
/// only this separation can show.
final class GateScript: Sendable {

    let monitor: GateWaitMonitor
    private let base = ContinuousClock.now
    private let issued = OSAllocatedUnfairLock(initialState: 0)

    init(_ monitor: GateWaitMonitor) {
        self.monitor = monitor
    }

    /// A read takes a place in `priority`'s queue.
    @discardableResult
    func park(_ priority: SMCReadPriority = .supervisor) -> ScriptedWaiter {
        let waiter = ScriptedWaiter(priority: priority, queuedAt: freshInstant())
        monitor.schedulerDidObserve(.waiterParked(priority: priority, queuedAt: waiter.queuedAt))
        return waiter
    }

    /// The scheduler hands the connection to a parked waiter (`admitNext()`).
    func grant(_ waiter: ScriptedWaiter) {
        monitor.schedulerDidObserve(
            .turnGranted(priority: waiter.priority, queuedAt: waiter.queuedAt))
    }

    /// The scheduler's fast path: a turn admitted straight away, with `queuedAt` equal to the
    /// grant instant and no waiter behind it. Nothing was parked with this instant.
    func grantOnTheFastPath(_ priority: SMCReadPriority = .supervisor) {
        monitor.schedulerDidObserve(.turnGranted(priority: priority, queuedAt: freshInstant()))
    }

    private func freshInstant() -> ContinuousClock.Instant {
        let ordinal = issued.withLock { count -> Int in
            count += 1
            return count
        }
        return base.advanced(by: .seconds(ordinal))
    }
}

/// What a `JournalingObserver` heard, and who heard it.
struct HeardEvent: Sendable, Equatable {
    let observer: String
    let event: SchedulerEvent
}

/// One journal several observers write into, so the order *between* them is observable.
final class ObserverJournal: Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [HeardEvent]())

    func record(_ observer: String, _ event: SchedulerEvent) {
        entries.withLock { $0.append(HeardEvent(observer: observer, event: event)) }
    }

    var heard: [HeardEvent] { entries.withLock { $0 } }
}

/// An observer that records into a shared journal and nothing else.
final class JournalingObserver: SchedulerObserving, Sendable {
    let name: String
    private let journal: ObserverJournal

    init(_ name: String, into journal: ObserverJournal) {
        self.name = name
        self.journal = journal
    }

    func schedulerDidObserve(_ event: SchedulerEvent) {
        journal.record(name, event)
    }
}
