import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The daemon's tick source (ADR 0012 I2): a `.strict` `DispatchSourceTimer` on a queue of its
/// own.
///
/// Two halves. The first runs the real timer, because a source nobody resumes never fires and a
/// source nobody holds is cancelled by ARC, and both leave a watchdog that looks armed and never
/// looks. The second runs a **recording** timer behind the `makeTimer` seam, because four of the
/// things `start` asks for — the strictness, the queue's quality of service, the period and the
/// leeway — are claims about how late a verdict can be, and none of them shows in a timer that
/// merely fires.
///
/// Every real timer a test here starts is cancelled before the test ends (`cancel()`, which
/// nothing in `Sources` may call): none outlives its test.
///
/// There is no bound on how *fast* the real timer ticks: the test waits, with a failsafe, for two
/// ticks to arrive and asserts what they were and where they ran.
@Suite("The daemon's tick source", .serialized, .timeLimit(.minutes(1)))
struct DispatchWatchdogTicksTests {

    // MARK: - The real timer

    private struct Observed: Sendable {
        var ticks = 0
        var queueLabels: Set<String> = []
        var onMainThread = false
    }

    /// Starts a real tick source and returns what its first handler saw once `count` ticks have
    /// arrived, or whatever it had seen when the failsafe ran out. The timer is cancelled before
    /// it returns.
    private func observe(ticks count: Int, startingTwice: Bool = false) async -> Observed {
        let seen = OSAllocatedUnfairLock(initialState: Observed())
        let source = DispatchWatchdogTicks()
        await source.start {
            let label = String(cString: __dispatch_queue_get_label(nil))
            seen.withLock {
                $0.ticks += 1
                $0.queueLabels.insert(label)
                if Thread.isMainThread { $0.onMainThread = true }
            }
        }
        if startingTwice {
            // The second handler must be ignored: one timer, the first handler.
            await source.start { seen.withLock { $0.ticks += 1_000 } }
        }
        _ = await pollUntil { seen.withLock { $0.ticks >= count } }
        await source.cancel()
        return seen.withLock { $0 }
    }

    /// **Mutation:** delete `source.resume()` from `DispatchWatchdogTicks.start`. Run: red —
    /// a source that was never resumed never fires. **Mutation:** do not store the source in
    /// `timer`. Run: red — ARC cancels it when `start` returns.
    @Test("The timer ticks repeatedly, on a queue of its own")
    func theTimerTicksOnItsOwnQueue() async {
        let observed = await observe(ticks: 2)

        #expect(observed.ticks >= 2, "the timer delivered \(observed.ticks) ticks")
        #expect(
            observed.queueLabels == [DispatchWatchdogTicks.queueLabel],
            "the tick ran on \(observed.queueLabels), not on the watchdog's own queue")
        #expect(!observed.onMainThread)
    }

    /// A second `start` keeps the first handler and starts no second timer.
    ///
    /// **Mutation:** delete the `guard timer == nil` in `DispatchWatchdogTicks.start`. Run:
    /// red — the second handler's thousand ticks are counted.
    @Test("Starting twice keeps one timer and the first handler")
    func startingTwiceKeepsTheFirstHandler() async {
        let observed = await observe(ticks: 2, startingTwice: true)

        #expect(observed.ticks >= 2)
        #expect(observed.ticks < 1_000, "a second timer's handler ran")
    }

    /// The period is what the ADR says and the leeway is the slop D_cycle allows for, converted
    /// to the dispatch timer's units without losing the fraction.
    ///
    /// **Mutation:** convert the attoseconds with the wrong divisor in `dispatchInterval`.
    /// Run: red.
    @Test("The timer's period and leeway are the watchdog's constants")
    func theTimerIsGivenTheWatchdogsConstants() {
        #expect(WatchdogLimits.tickInterval == .seconds(1))
        #expect(WatchdogLimits.timerLeeway == .milliseconds(100))
    }

    // MARK: - A watchdog over the real timer

    /// A `LivenessWatchdog` armed over the real `DispatchWatchdogTicks` — as `production` builds
    /// it — reaches its verdict **by itself**: nothing in this test calls `tick()`.
    ///
    /// Every other test of the watchdog fires its ticks by hand, and the test that asks what
    /// `production` was given only reads a type. So a later edit that stops the real timer
    /// after it has started — a `disarm()` that cancels it through a cast, an `arm()` that then
    /// returns early because `isArmed` is still set — leaves a watchdog that logged "armed" once
    /// and never looks, with every one of them green. The stalled round trip is a stamp on a
    /// timeline the test moves; only the timer is real.
    ///
    /// The wait is a floor: it polls until the verdict is in, with a failsafe that turns a timer
    /// that never fires into a failed expectation. It says nothing about how soon.
    ///
    /// **Mutation:** `if case let real as DispatchWatchdogTicks = ticks { await real.cancel() }`
    /// in `LivenessWatchdog.arm()`, after the start. Run: red.
    /// **Mutation:** never resume the timer. Run: red.
    @Test("A watchdog armed over the real timer reaches its verdict on its own")
    func aWatchdogOverTheRealTimerTicksOnItsOwn() async {
        let timeline = WatchdogTimeline()
        let journal = TeardownJournal()
        let log = RecordedWatchdogLog()
        let monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
        let ticks = DispatchWatchdogTicks()
        let watchdog = LivenessWatchdog(
            roundTrips: monitor,
            progress: ThermalCycleProgress(now: { timeline.progressInstant() }),
            gateMonitor: GateWaitMonitor(now: { timeline.gateInstant() }),
            termination: ProcessTermination(terminate: journal.terminate, log: log.log),
            ticks: ticks, log: log.log)
        let wedge = WedgedRoundTrip(monitor, tpd0)
        defer { wedge.finish() }
        guard await wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            return
        }
        timeline.advance(by: .seconds(6))

        await watchdog.arm()
        let ended = await pollUntil { !journal.exitsNow.isEmpty }
        await ticks.cancel()

        #expect(
            ended,
            "the real timer never delivered the two ticks a verdict needs: \(log.lines)")
        #expect(journal.exitsNow == [.blind])
        #expect(log.faults.count == 1)
    }

    // MARK: - What start asks for

    /// The timer is `.strict`, and on the watchdog's own queue.
    ///
    /// A timer that is not strict can be coalesced well past its leeway on a machine the system
    /// has classed as idle, which delays a verdict by an amount nobody chose.
    ///
    /// **Mutation:** pass `[]` for `.strict` in `DispatchWatchdogTicks.start`. Run: red.
    /// **Mutation:** make a queue other than the watchdog's own in `start`. Run: red.
    @Test("The timer is asked for strict, on the watchdog's queue")
    func theTimerIsStrictOnItsOwnQueue() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        await source.start {}

        #expect(factory.made.count == 1, "\(factory.made.count) timers were made")
        #expect(factory.made.first?.flags == DispatchSource.TimerFlags.strict.rawValue)
        #expect(factory.made.first?.queue.label == DispatchWatchdogTicks.queueLabel)
    }

    /// The queue is of a quality of service above the helper's own work. A queue below it is one
    /// that work above it can starve, which is a verdict that does not arrive in the one case it
    /// is for.
    ///
    /// Asked of the queue itself: a block that asks for the **lowest** quality of service and
    /// is submitted to it runs at the queue's, so the answer is the queue's. A queue with none
    /// would run it at the block's own, and a lower one at its own. The request is made on the
    /// block, from the test's own thread: a thread made to run at the lowest class is one a busy
    /// machine can starve for as long as it likes, and this test is not about the machine.
    ///
    /// **Mutation:** make the queue `.utility`, or give it none. Run: red.
    @Test("The timer's queue is user-initiated")
    func theQueueIsUserInitiated() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        await source.start {}
        guard let queue = factory.made.first?.queue else {
            Issue.record("no timer was made")
            return
        }

        let ran = OSAllocatedUnfairLock<UInt32?>(initialState: nil)
        queue.async(qos: .background) {
            ran.withLock { $0 = qos_class_self().rawValue }
        }
        let finished = await pollUntil { ran.withLock { $0 } != nil }

        #expect(finished, "the queue never ran a block")
        #expect(
            ran.withLock { $0 } == QOS_CLASS_USER_INITIATED.rawValue,
            "the watchdog's queue runs at QoS class \(ran.withLock { $0 } ?? 0)")
    }

    /// The first tick is a period away and the period and the leeway are the constants.
    ///
    /// A deadline of `.now()` would fire a tick before any state exists to be looked at; a
    /// period or leeway that was quietly changed moves every verdict by that much. Only a
    /// *lower* bound is asserted on the deadline (it is no earlier than a period after the
    /// call began): how late a timer is allowed to be is the leeway's business.
    ///
    /// **Mutation:** schedule with `deadline: .now()`. Run: red.
    /// **Mutation:** pass `.seconds(2)` for the repeating interval. Run: red.
    /// **Mutation:** pass `.milliseconds(500)` for the leeway. Run: red.
    @Test("The timer is scheduled with the watchdog's period and leeway")
    func theTimerIsScheduledWithTheWatchdogsConstants() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        let before = DispatchTime.now()
        await source.start {}

        let schedules = factory.timer.schedules
        #expect(schedules.count == 1)
        let schedule = schedules.first
        #expect(schedule?.repeating == WatchdogLimits.tickInterval)
        #expect(schedule?.leeway == WatchdogLimits.timerLeeway)
        #expect(schedule?.repeating == .seconds(1))
        #expect(schedule?.leeway == .milliseconds(100))
        let firstFire = schedule?.deadline.uptimeNanoseconds ?? 0
        #expect(
            firstFire >= before.uptimeNanoseconds + 1_000_000_000,
            "the first tick is scheduled less than a period after start")
    }

    /// The timer is configured and then resumed — once, last — and the handler it will call is
    /// the one `start` was given.
    ///
    /// **Mutation:** delete `timer.resume()`. Run: red. **Mutation:** resume before
    /// `setEventHandler`. Run: red.
    @Test("The timer is configured, then resumed once, with the handler it was given")
    func theTimerIsResumedLastWithTheGivenHandler() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        await source.start { delivered.withLock { $0 += 1 } }

        #expect(factory.timer.calls.last == "resume")
        #expect(factory.timer.calls.filter { $0 == "resume" }.count == 1)
        #expect(factory.timer.calls.filter { $0 == "schedule" }.count == 1)
        #expect(factory.timer.calls.filter { $0 == "setEventHandler" }.count == 1)

        factory.timer.handler?()
        #expect(delivered.withLock { $0 } == 1, "the timer's handler is not the one given")
    }

    /// A second `start` makes no second timer and replaces no handler.
    ///
    /// **Mutation:** delete the `guard timer == nil`. Run: red.
    @Test("A second start makes no second timer")
    func aSecondStartMakesNoSecondTimer() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        let first = OSAllocatedUnfairLock(initialState: 0)
        let second = OSAllocatedUnfairLock(initialState: 0)
        await source.start { first.withLock { $0 += 1 } }
        await source.start { second.withLock { $0 += 1 } }

        #expect(factory.made.count == 1)
        factory.timer.handler?()
        #expect(first.withLock { $0 } == 1)
        #expect(second.withLock { $0 } == 0)
    }

    /// `cancel()` — for tests, so that no real timer outlives one — cancels the timer it holds.
    ///
    /// **Mutation:** make `cancel()` do nothing. Run: red.
    @Test("cancel() cancels the timer")
    func cancelCancelsTheTimer() async {
        let factory = RecordingTimerFactory()
        let source = DispatchWatchdogTicks(makeTimer: factory.makeTimer)
        await source.start {}
        await source.cancel()

        #expect(factory.timer.calls.last == "cancel")
    }
}
