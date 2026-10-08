import Foundation
import Testing

@testable import AeolusHelper

/// The mirror of the scheduler's parked queues (ADR 0012, PR C, #135).
///
/// `GateWaitMonitor` hears `waiterParked` and `turnGranted` and keeps what the scheduler keeps:
/// a FIFO of parked waiters per priority, each with an age of the monitor's own. The scheduler
/// never reports a waiter's age and never will (`SchedulerEvent` says why), so the mirror is the
/// only way anything outside it can ask "how long has the oldest one waited".
///
/// Time is a `WatchdogTimeline` the test moves, and events are the scheduler's own two, emitted by
/// hand through `GateScript`. One suite drives the real scheduler, because a mirror that agrees
/// with a script and not with the scheduler is a mirror of the script.
///
/// Every test names the mutation that must turn it red; each was run, and the table is on the
/// pull request.
@Suite("The gate mirror", .timeLimit(.minutes(1)))
struct GateWaitMonitorTests {

    private struct Fixture {
        let timeline = WatchdogTimeline()
        let monitor: GateWaitMonitor
        let script: GateScript

        init() {
            let timeline = timeline
            monitor = GateWaitMonitor(now: { timeline.gateInstant() })
            script = GateScript(monitor)
        }
    }

    // MARK: - Parked, then granted

    /// A parked waiter is in the mirror until its own grant, in the queue it joined, and not
    /// in the other one.
    ///
    /// **Mutation:** ignore `turnGranted` in `schedulerDidObserve(_:)`. Run: red — a waiter
    /// that was served keeps aging, and a watchdog would log a `.fault` for a read that
    /// finished long ago.
    @Test("A waiter is mirrored from its park to its grant")
    func aWaiterIsMirroredFromParkToGrant() {
        let fixture = Fixture()
        let supervisor = fixture.script.park(.supervisor)
        fixture.script.park(.snapshot)

        #expect(fixture.monitor.depth(at: .supervisor) == 1)
        #expect(fixture.monitor.depth(at: .snapshot) == 1)

        fixture.script.grant(supervisor)

        #expect(fixture.monitor.depth(at: .supervisor) == 0)
        #expect(fixture.monitor.depth(at: .snapshot) == 1, "a grant touched the other queue")
        #expect(fixture.monitor.oldestParked().map(\.priority) == [.snapshot])
    }

    /// The scheduler's fast path grants a turn that never parked, and **the fast path implies
    /// empty queues**, so a grant that matches no parked waiter takes nobody out. The event
    /// carries a `queuedAt` equal to its own grant instant; no parked waiter has that one.
    ///
    /// The mirror is driven out of step with the scheduler on purpose (a waiter is parked and
    /// then a fast-path grant arrives at the same priority, which the real scheduler cannot
    /// do). It is the only way to observe that nothing is popped: with the queues in step, a
    /// pop on an empty queue is invisible.
    ///
    /// **Mutation:** pop the head of the priority's queue on every `turnGranted`, whatever it
    /// carries. Run: red — the parked waiter vanishes.
    @Test("A fast-path grant pops nothing")
    func aFastPathGrantPopsNothing() {
        let fixture = Fixture()
        let parked = fixture.script.park(.supervisor)

        fixture.script.grantOnTheFastPath(.supervisor)
        fixture.script.grantOnTheFastPath(.snapshot)

        #expect(
            fixture.monitor.depth(at: .supervisor) == 1,
            "a grant that matched no parked waiter popped one")
        fixture.script.grant(parked)
        #expect(fixture.monitor.depth(at: .supervisor) == 0)
    }

    /// Waiters at one priority are served first in, first out, and the age that is reported is
    /// the head's — the one that has waited longest.
    ///
    /// **Mutation:** insert at the front of the queue (`insert(_, at: 0)`) in the
    /// `waiterParked` branch. Run: red — the youngest waiter's age is reported.
    @Test("Waiters are mirrored first in, first out, and the head is the oldest")
    func waitersAreMirroredFirstInFirstOut() {
        let fixture = Fixture()
        let first = fixture.script.park(.supervisor)
        fixture.timeline.advance(by: .seconds(3))
        let second = fixture.script.park(.supervisor)
        fixture.timeline.advance(by: .seconds(2))
        let third = fixture.script.park(.supervisor)
        fixture.timeline.advance(by: .seconds(1))

        let head = fixture.monitor.oldestParked().first
        #expect(head?.age == .seconds(6), "the head is not the oldest: \(String(describing: head))")
        #expect(head?.depth == 3)

        fixture.script.grant(first)
        #expect(fixture.monitor.oldestParked().first?.age == .seconds(3))
        #expect(fixture.monitor.oldestParked().first?.depth == 2)

        fixture.script.grant(second)
        fixture.script.grant(third)
        #expect(fixture.monitor.oldestParked().isEmpty)
    }

    /// A grant is for the queue it names. Two waiters parked at different priorities with the
    /// same `queuedAt` are two waiters, and a supervisor grant takes out the supervisor one.
    ///
    /// **Mutation:** keep one queue for both priorities. Run: red.
    @Test("A grant takes a waiter out of the queue it names")
    func aGrantIsForTheQueueItNames() {
        let fixture = Fixture()
        let instant = ContinuousClock.now
        fixture.monitor.schedulerDidObserve(.waiterParked(priority: .supervisor, queuedAt: instant))
        fixture.monitor.schedulerDidObserve(.waiterParked(priority: .snapshot, queuedAt: instant))

        fixture.monitor.schedulerDidObserve(.turnGranted(priority: .snapshot, queuedAt: instant))

        #expect(fixture.monitor.depth(at: .snapshot) == 0)
        #expect(fixture.monitor.depth(at: .supervisor) == 1)
    }

    /// Every ticket is new: the identity a watchdog collapses its `.fault` on never repeats,
    /// even when a waiter is granted and another parks at the same priority straight after.
    ///
    /// **Mutation:** take the ticket from the queue's depth instead of a counter. Run: red.
    @Test("Tickets are never reused")
    func ticketsAreNeverReused() {
        let fixture = Fixture()
        let first = fixture.script.park(.supervisor)
        let firstTicket = fixture.monitor.oldestParked().first?.ticket
        fixture.script.grant(first)
        fixture.script.park(.supervisor)
        let secondTicket = fixture.monitor.oldestParked().first?.ticket

        #expect(firstTicket != nil)
        #expect(secondTicket != nil)
        #expect(firstTicket != secondTicket)
        #expect((secondTicket ?? 0) > (firstTicket ?? 0))
    }

    // MARK: - The clock

    /// The mirror ages on the suspending clock — a property of one `typealias`, asserted as a
    /// property of the type. A waiter parked across a sleep must not age by the sleep: on the
    /// continuous clock the first two ticks after an hour-long lid close would see an hour of
    /// waiting, and a gate fault would be logged for a read that has been parked for milliseconds
    /// of awake time (ADR 0012, "Two clock families in the helper").
    ///
    /// **Mutation:** `typealias MeasuringClock = ContinuousClock` in `GateWaitMonitor`.
    /// Run: red.
    @Test("The mirror ages on the suspending clock")
    func theMirrorReadsTheSuspendingClock() {
        #expect(GateWaitMonitor.Instant.self == SuspendingClock.Instant.self)
        #expect(GateWaitMonitor.MeasuringClock.self == SuspendingClock.self)
    }

    /// The scheduler's `queuedAt` is on the continuous clock and names a waiter; it is not a
    /// start of waiting. A waiter whose event says it queued an hour ago, parked just now on the
    /// monitor's clock, has waited no time at all.
    ///
    /// **Mutation:** age a waiter from the event's `queuedAt` (the monitor's `now()` replaced by
    /// `ContinuousClock.now`, the start by the event's instant). Run: red.
    @Test("A waiter's age does not come from the scheduler's own instant")
    func theAgeIgnoresTheSchedulersInstant() {
        let fixture = Fixture()
        let anHourAgo = ContinuousClock.now.advanced(by: .seconds(-3_600))
        fixture.monitor.schedulerDidObserve(
            .waiterParked(priority: .supervisor, queuedAt: anHourAgo))

        #expect(fixture.monitor.oldestParked().first?.age == .zero)
    }

    /// The age is read from the monitor's own clock when it is asked for, from the moment the
    /// waiter parked: the comparer mints the instant, so no caller can hand it one that makes
    /// the comparison a no-op, and no waiter's age is frozen at the moment it was parked.
    ///
    /// **Mutation:** store `Duration.zero` as the waiter's age when it parks and return that.
    /// Run: red.
    @Test("The age is minted when it is read, from the park")
    func theAgeIsMintedWhenRead() {
        let fixture = Fixture()
        fixture.script.park(.supervisor)

        fixture.timeline.advance(by: .seconds(4))
        #expect(fixture.monitor.oldestParked().first?.age == .seconds(4))
        fixture.timeline.advance(by: .milliseconds(2_500))
        #expect(fixture.monitor.oldestParked().first?.age == .milliseconds(6_500))
    }

    /// The clock the shipping monitor is built with actually moves. Every other test injects a
    /// timeline, so none runs the default; a default that was an instant captured once still
    /// has the right type and reads an age of zero for ever, and the gate trigger could never
    /// fire in the daemon. Only a lower bound is asserted: it waits, by sleeping, until the age
    /// is not zero, and says nothing about how soon.
    ///
    /// **Mutation:** default the `now:` parameter to an instant captured once
    /// (`{ [t = MeasuringClock.now] in t }`). Run: red.
    @Test("The shipping monitor's clock ages")
    func theDefaultClockAges() async {
        let monitor = GateWaitMonitor()
        GateScript(monitor).park(.supervisor)

        let aged = await pollUntil { (monitor.oldestParked().first?.age ?? .zero) > .zero }

        #expect(aged, "the default clock never moved: the gate trigger could never fire")
    }

    // MARK: - Against the real scheduler

    /// The mirror agrees with the scheduler's own queues through a real run: the same depth at
    /// each priority while waiters are parked, a grant that takes a waiter out of the queue the
    /// scheduler took it from (a supervisor read overtakes the waiting snapshots), and nothing
    /// left in either when it has drained.
    ///
    /// **Mutation:** pop from the snapshot queue whatever priority a grant names. Run: red.
    /// **Mutation:** ignore `turnGranted`. Run: red — nothing is ever taken out.
    @Test("The mirror agrees with the real scheduler's queues")
    func theMirrorTracksTheSchedulersQueues() async throws {
        let monitor = GateWaitMonitor()
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider, observer: monitor)

        // The first read takes the fast path and holds the connection at the provider.
        let holder = observing { try await scheduler.read(keys: ["H0"], at: .snapshot) }
        await yieldUntil("the first read to reach the provider") {
            await provider.turns.count == 1
        }
        #expect(monitor.oldestParked().isEmpty, "a fast-path grant left a waiter in the mirror")

        let snapshots = (0..<2).map { index in
            observing { try await scheduler.read(keys: ["S\(index)"], at: .snapshot) }
        }
        await yieldUntil("two snapshot reads to be queued") {
            await scheduler.queuedTurns(at: .snapshot) == 2
        }
        let supervisors = (0..<3).map { index in
            observing { try await scheduler.read(keys: ["T\(index)"], at: .supervisor) }
        }
        await yieldUntil("three supervisor reads to be queued") {
            await scheduler.queuedTurns(at: .supervisor) == 3
        }

        #expect(monitor.depth(at: .snapshot) == 2)
        #expect(monitor.depth(at: .supervisor) == 3)

        // The holder gives the connection back: a waiting supervisor overtakes the snapshots.
        await provider.releaseOneTurn()
        await yieldUntil("the scheduler to admit a supervisor read") {
            await scheduler.queuedTurns(at: .supervisor) == 2
        }
        #expect(monitor.depth(at: .supervisor) == 2, "the grant took out the wrong queue")
        #expect(monitor.depth(at: .snapshot) == 2)

        await provider.releaseEveryTurn()
        _ = try await finished("the holder", holder)
        for (index, read) in snapshots.enumerated() {
            _ = try await finished("snapshot read \(index)", read)
        }
        for (index, read) in supervisors.enumerated() {
            _ = try await finished("supervisor read \(index)", read)
        }

        #expect(monitor.oldestParked().isEmpty, "a drained scheduler left waiters in the mirror")
        #expect(await scheduler.queuedTurns(at: .supervisor) == 0)
        #expect(await scheduler.queuedTurns(at: .snapshot) == 0)
    }
}
