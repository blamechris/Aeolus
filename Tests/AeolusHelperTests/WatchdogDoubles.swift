import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

// The liveness watchdog's fixtures (ADR 0012). Everything here moves time by hand, ticks by
// hand, and ends the process into a journal: a test of the watchdog that waited on a real
// timer would be a test with a wall-clock bound in it (#319), and one that let the shipping
// terminate run would end `swift test`.

/// A monitor no connection stamps: nothing is in flight, ever.
///
/// What a composition that is not about the watchdog is given, because
/// `HelperComposition.init` takes a monitor and has no default for it. It is built without a
/// connection on purpose — in the daemon a monitor with no connection behind it is exactly the
/// bug the missing default prevents, and in a test that does not look at it, it is nothing.
func idleRoundTrips() -> SMCRoundTripMonitor {
    SMCRoundTripMonitor()
}

/// A tick source the test fires by hand.
///
/// `start(_:)` keeps the first handler and counts the calls, so a test can say "armed once" and
/// "the handler is the watchdog's own tick" without a timer ever running.
final class ManualWatchdogTicks: WatchdogTicking, Sendable {

    private struct State: Sendable {
        var handler: (@Sendable () -> Void)?
        var starts = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(_ handler: @escaping @Sendable () -> Void) async {
        state.withLock {
            $0.starts += 1
            if $0.handler == nil { $0.handler = handler }
        }
    }

    /// Whether `start(_:)` has been called: whether the watchdog has been armed.
    var isRunning: Bool { state.withLock { $0.handler != nil } }

    var startCount: Int { state.withLock { $0.starts } }

    /// Delivers one tick, on the calling thread, exactly as the timer would.
    func fire() {
        let handler = state.withLock { $0.handler }
        handler?()
    }
}

/// A clock for the monitor, on the monitor's own `Instant` and the timeline's elapsed time.
///
/// Typed on `SMCRoundTripMonitor.Instant` rather than on `SuspendingClock.Instant`, so the
/// assertion that pins the monitor's clock family stays an assertion and does not turn into a
/// build error when that one line changes.
struct TimelineMonitorClock: Clock {
    typealias Instant = SMCRoundTripMonitor.Instant

    fileprivate let timeline: WatchdogTimeline

    var now: Instant { timeline.monitorInstant() }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// One timeline for the monitor, the progress and the gate mirror, moved by hand.
///
/// Each reads its own clock family's instant off the one elapsed counter, so advancing the
/// timeline ages a stamp, a stalled cycle and a parked waiter together, which is how a wedged
/// helper looks.
final class WatchdogTimeline: Sendable {
    private let elapsed = OSAllocatedUnfairLock(initialState: Duration.zero)
    private let monitorBase = SMCRoundTripMonitor.MeasuringClock().now
    private let progressBase = ThermalCycleProgress.MeasuringClock().now
    private let gateBase = GateWaitMonitor.MeasuringClock().now

    func advance(by amount: Duration) {
        elapsed.withLock { $0 += amount }
    }

    fileprivate func monitorInstant() -> SMCRoundTripMonitor.Instant {
        monitorBase.advanced(by: elapsed.withLock { $0 })
    }

    func progressInstant() -> ThermalCycleProgress.Instant {
        progressBase.advanced(by: elapsed.withLock { $0 })
    }

    func gateInstant() -> GateWaitMonitor.Instant {
        gateBase.advanced(by: elapsed.withLock { $0 })
    }

    var monitorClock: TimelineMonitorClock { TimelineMonitorClock(timeline: self) }
}

/// A timer that does nothing and remembers what it was asked, in order.
final class RecordingWatchdogTimer: WatchdogTimer, Sendable {

    struct Schedule: Sendable {
        let deadline: DispatchTime
        let repeating: DispatchTimeInterval
        let leeway: DispatchTimeInterval
    }

    private struct State: Sendable {
        var calls: [String] = []
        var schedules: [Schedule] = []
        var handler: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func schedule(
        deadline: DispatchTime, repeating: DispatchTimeInterval, leeway: DispatchTimeInterval
    ) {
        state.withLock {
            $0.calls.append("schedule")
            $0.schedules.append(
                Schedule(deadline: deadline, repeating: repeating, leeway: leeway))
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        state.withLock {
            $0.calls.append("setEventHandler")
            $0.handler = handler
        }
    }

    func resume() { state.withLock { $0.calls.append("resume") } }
    func cancel() { state.withLock { $0.calls.append("cancel") } }

    var calls: [String] { state.withLock { $0.calls } }
    var schedules: [Schedule] { state.withLock { $0.schedules } }
    var handler: (@Sendable () -> Void)? { state.withLock { $0.handler } }
}

/// What the tick source asked its factory for.
final class RecordingTimerFactory: Sendable {

    struct Request: Sendable {
        /// `DispatchSource.TimerFlags.rawValue`: the flag set itself is not `Sendable`.
        let flags: UInt
        let queue: DispatchQueue
    }

    private let requests = OSAllocatedUnfairLock(initialState: [Request]())
    let timer = RecordingWatchdogTimer()

    var made: [Request] { requests.withLock { $0 } }

    var makeTimer: DispatchWatchdogTicks.MakeTimer {
        { [self] flags, queue in
            let raw = flags.rawValue
            requests.withLock { $0.append(Request(flags: raw, queue: queue)) }
            return timer
        }
    }
}

/// Everything the watchdog logged, with its level.
final class RecordedWatchdogLog: Sendable {

    struct Line: Sendable, Equatable {
        let level: WatchdogLog.Level
        let message: String
    }

    private let recorded = OSAllocatedUnfairLock(initialState: [Line]())

    var log: WatchdogLog {
        WatchdogLog(recording: { [recorded] level, message in
            recorded.withLock { $0.append(Line(level: level, message: message)) }
        })
    }

    var lines: [Line] { recorded.withLock { $0 } }

    var faults: [String] {
        lines.filter { $0.level == .fault }.map(\.message)
    }

    func lines(containing fragment: String) -> [Line] {
        lines.filter { $0.message.contains(fragment) }
    }
}

/// A watchdog over a monitor and a progress the test controls, ending the process into a
/// journal.
///
/// Built from the same pieces `HelperComposition` builds, in the same shape — monitor,
/// progress, one `ProcessTermination`, a tick source — but with nothing shared with a
/// composition, so a test of the watchdog alone fails for the watchdog's reasons.
final class WatchdogRig: Sendable {

    let timeline = WatchdogTimeline()
    let monitor: SMCRoundTripMonitor
    let progress: ThermalCycleProgress
    let ticks = ManualWatchdogTicks()
    let journal = TeardownJournal()
    let log = RecordedWatchdogLog()
    let termination: ProcessTermination
    let watchdog: LivenessWatchdog

    init() {
        let timeline = self.timeline
        let journal = self.journal
        monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
        progress = ThermalCycleProgress(now: { timeline.progressInstant() })
        termination = ProcessTermination(
            terminate: journal.terminate,
            log: log.log)
        watchdog = LivenessWatchdog(
            roundTrips: monitor, progress: progress, termination: termination,
            ticks: ticks, log: log.log)
    }

    /// Two ticks, back to back: the least that can produce a verdict.
    func tickTwice() {
        watchdog.tick()
        watchdog.tick()
    }

    /// Every time the terminate seam was called, in order. The ending is synchronous (it happens
    /// inside `tick()`, on the caller's thread), so this is the exact answer the instant a tick
    /// returns: nothing is waited for, and nothing can arrive later. `== [.blind]` is "ended
    /// once, as `.blind`"; `isEmpty` is "never ended".
    var exitsNow: [TeardownOutcome] { journal.exitsNow }
}

/// A round trip that has begun and will not return until told to, on a dedicated thread.
///
/// A real parked thread, not a suspended task: that is what a wedged `IOConnectCallStructMethod`
/// is. Dedicated rather than on the global queue, because a thread that blocks on a
/// semaphore on a pool shared with the rest of the suite starved a three-core CI runner (#324).
///
/// **Nothing here blocks a cooperative-pool thread.** Waiting for the thread to be wedged polls
/// with `Task.sleep`, and `finish()` only lets the round trip go: the wedged thread returns on
/// its own and nothing joins it. The wedge is itself bounded (two minutes), so a test that
/// leaked one cannot park an OS thread for the life of the process.
final class WedgedRoundTrip: Sendable {
    private let entered = OSAllocatedUnfairLock(initialState: false)
    private let release = DispatchSemaphore(value: 0)

    init(_ monitor: SMCRoundTripMonitor, _ operation: SMCRoundTripOperation) {
        Thread { [entered, release] in
            monitor.bracket(operation) {
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + .seconds(120))
            }
        }.start()
    }

    /// Whether the round trip began, waiting for it by polling.
    func waitUntilWedged() async -> Bool {
        await pollUntil { entered.withLock { $0 } }
    }

    func letReturn() {
        release.signal()
    }

    /// Lets the round trip go. Safe in a `defer`: it neither waits nor suspends.
    func finish() {
        letReturn()
    }
}

/// `TPD0`, the first of `Mac16,5`'s curated critical keys, as the four bytes the wire carries.
let tpd0 = SMCRoundTripOperation.call(key: 0x5450_4430, selector: 5)

/// Polls `condition` every few milliseconds with `Task.sleep`, which suspends rather than
/// parking a cooperative-pool thread, for at most ten seconds. For readiness that another
/// thread or task has to reach — never an assertion about how fast it did.
func pollUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Gives every task already runnable a real chance to run: a quarter of a second of sleeping,
/// which suspends instead of spinning. For asserting that something did **not** happen, where
/// there is nothing to wait for — a floor on how long the absence was observed, never a bound
/// on how long anything takes.
func settle() async {
    for _ in 0..<25 { try? await Task.sleep(for: .milliseconds(10)) }
}
