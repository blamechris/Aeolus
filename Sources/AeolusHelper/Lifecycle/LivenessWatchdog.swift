import Foundation
import SMCCore
import os

/// Why the watchdog ended the helper, in the terms the log line and a test read.
struct WatchdogVerdict: Sendable, Equatable {

    enum Trigger: Sendable, Hashable {
        /// A stamped round trip in flight for longer than D.
        case roundTrip
        /// No completed § 3 cycle since arming, for longer than D_bringUp: the supervisor was
        /// never started, or the bring-up stalled somewhere that is not a stamped round trip.
        case bringUp
        /// No completed § 3 cycle for longer than D_cycle, while the supervisor runs.
        case cycle
    }

    let trigger: Trigger
    /// The bound the age exceeded.
    let bound: Duration
    /// The round trip's age for `.roundTrip`; the time since the last completion otherwise.
    let age: Duration
    /// The round trip in flight at the verdict. For `.roundTrip` it is the one that did not
    /// return; for the other two it is evidence, present or absent.
    let stamp: SMCRoundTripInFlight?
    /// Progress at the verdict: phase, completions, and the age since the last of them.
    let progress: ThermalCycleProgress.Reading
}

/// What calls the watchdog once per `WatchdogLimits.tick`.
///
/// A seam so a test drives ticks by hand: the production source is a real timer on a real
/// queue, and a test that waited on it would be a test with a wall-clock bound in it.
protocol WatchdogTicking: Sendable {

    /// Starts calling `handler`, on whatever thread the source owns, once per
    /// `WatchdogLimits.tick`. The period is not a parameter (ADR 0012 I8). Idempotent: a
    /// second call keeps the first handler.
    func start(_ handler: @escaping @Sendable () -> Void) async
}

/// The slice of `DispatchSourceTimer` the tick source drives, so that a test can see exactly
/// what `DispatchWatchdogTicks.start` asked for: the flags, the queue, the period, the
/// leeway. Four of those are claims about the thread the watchdog runs on and how late it can
/// be, and none of them is observable from a timer that merely fires.
protocol WatchdogTimer {
    func schedule(
        deadline: DispatchTime, repeating: DispatchTimeInterval, leeway: DispatchTimeInterval)
    func setEventHandler(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

/// The real thing: a `DispatchSourceTimer`.
struct SystemWatchdogTimer: WatchdogTimer {

    private let source: any DispatchSourceTimer

    init(flags: DispatchSource.TimerFlags, queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(flags: flags, queue: queue)
    }

    static func make(flags: DispatchSource.TimerFlags, queue: DispatchQueue) -> any WatchdogTimer {
        SystemWatchdogTimer(flags: flags, queue: queue)
    }

    func schedule(
        deadline: DispatchTime, repeating: DispatchTimeInterval, leeway: DispatchTimeInterval
    ) {
        source.schedule(deadline: deadline, repeating: repeating, leeway: leeway)
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func resume() {
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

/// The daemon's tick source: a `.strict` `DispatchSourceTimer` on a queue of its own.
///
/// ## Why a dispatch queue and not a `Task`
///
/// The watchdog exists for the case where the cooperative pool and the connection actor are
/// not making progress. A timer driven by `Task.sleep` would run on the pool it is watching.
/// A dispatch timer on a serial queue of its own needs nothing from the pool, nothing from any
/// actor, and no executor the helper's own work could be holding — and, since the verdict ends
/// the process on this queue too (`LivenessWatchdog.tick()`), neither does the ending.
///
/// ## Why the timer is kept
///
/// Held in this actor for `DispatchSignalSources`' reason: a source released by ARC is
/// cancelled, and a watchdog whose timer was released is a mechanism that stopped without
/// saying so. `HelperComposition` holds the watchdog, the watchdog holds this, and
/// `main()` parks the composition for the life of the process.
///
/// ## What `start` asks for is pinned
///
/// `.strict`, a `.userInitiated` queue, `WatchdogLimits.tickInterval` and
/// `WatchdogLimits.timerLeeway`, through the `makeTimer` seam. A timer that is not strict can
/// be coalesced well past its leeway on a machine the system has classed as idle, and a queue
/// of lower QoS is one that work above it can starve: both would delay a verdict, and neither
/// shows in a test that only waits for two ticks.
actor DispatchWatchdogTicks: WatchdogTicking {

    typealias MakeTimer = @Sendable (DispatchSource.TimerFlags, DispatchQueue) -> any WatchdogTimer

    static let queueLabel = "dev.aeolus.AeolusHelper.watchdog"

    private let queue = DispatchQueue(label: DispatchWatchdogTicks.queueLabel, qos: .userInitiated)
    private let makeTimer: MakeTimer
    private var timer: (any WatchdogTimer)?

    init(makeTimer: @escaping MakeTimer = SystemWatchdogTimer.make) {
        self.makeTimer = makeTimer
    }

    func start(_ handler: @escaping @Sendable () -> Void) {
        guard timer == nil else { return }
        let timer = makeTimer(.strict, queue)
        timer.schedule(
            deadline: .now() + WatchdogLimits.tickInterval,
            repeating: WatchdogLimits.tickInterval,
            leeway: WatchdogLimits.timerLeeway)
        timer.setEventHandler(handler)
        timer.resume()
        self.timer = timer
    }

    /// Stops the timer and lets go of its handler. **For tests only — nothing in `Sources` may
    /// call this** (`WatchdogTripwireTests` holds that): the daemon's watchdog is not stopped
    /// by anything, and the handler's hold on the watchdog is what keeps it alive. A test that
    /// ran the real timer calls this so that no timer outlives it.
    func cancel() {
        timer?.cancel()
        timer = nil
    }
}

/// The helper's liveness watchdog (ADR 0012): if the helper cannot complete an SMC round trip
/// within D, or a safety cycle within D_cycle, it logs one `.fault` and ends the process
/// non-zero, as `TeardownOutcome.blind`. A third trigger, a read parked at the scheduler's gate
/// for longer than G, logs a `.fault` and **ends nothing**.
///
/// ## What it does not do
///
/// It abandons nothing, times nothing out, and reopens nothing. A round trip that has not
/// returned is a thread parked in the kernel, and nothing in Swift can resume it; the only
/// abandonment that can be ordered is the process's death. A verdict runs **no orderly
/// teardown** and makes **no IOKit call**: the teardown awaits the same connection a wedge
/// holds.
///
/// ## What the ending buys, and what it does not
///
/// launchd restarts a job it is keeping alive, and the next process's startup reconciliation
/// then restores automatic control **if its pass reaches its keystone**. A wedge that outlives the
/// restart ends that process the same way, launchd throttles the loop, and nothing is
/// restored until the driver answers. Where launchd is itself stopping the job — a bootout,
/// `SMAppService.unregister()`, a shutdown — it does not restart it at all. A false positive
/// on a healthy machine does put the fans back to automatic, once the successor reads.
///
/// ## The ending is on this watchdog's queue
///
/// `tick()` takes the claim on ending the process and ends it, synchronously, on the
/// watchdog's own dispatch queue. There is no `Task` on the verdict path: a hand-off to the
/// cooperative pool would never run in the one case this exists for, the pool not making
/// progress (see `ProcessTermination`).
///
/// ## Four things it reads, none of them through an actor
///
/// - **The stamp** (`SMCRoundTripMonitor.inFlight()`): the round trip that has begun and not
///   returned, with its sequence number and an age on the suspending clock. A lock-guarded
///   copy. It never takes the connection, and this file names no `SMCConnection`
///   (`LivenessWatchdogTests` holds that).
/// - **Progress** (`ThermalCycleProgress`): how long since § 3 last completed a cycle.
/// - **The gate** (`GateWaitMonitor.oldestParked()`): the oldest read parked at each priority of
///   the scheduler's gate, its age on the suspending clock and its queue's depth. A lock-guarded
///   copy; it never takes the scheduler.
/// - **Itself**: the previous tick's findings.
///
/// ## The gate trigger reports and ends nothing
///
/// A waiter parked at the gate for longer than `WatchdogLimits.gateWaiterAlarm` (G) logs one
/// `.fault` naming the priority, the age and the queue depth
/// ([#135](https://github.com/blamechris/Aeolus/issues/135)). **After the fault the helper does
/// nothing more:** the gate is not cancellable, so there is no wait to abandon, and the trigger
/// has no streak, no claim on ending the process and no `fired`. A gate that never turns starves
/// § 3 behind it, and the cycle trigger is the action; the fault is how the log says why, when
/// there is a waiter to say it. It is logged once per waiter, and it is suppressed while a
/// stamped round trip older than one tick is in flight, which explains the wait and has alarms
/// of its own.
///
/// ## A verdict is two consecutive ticks on the same thing
///
/// One over-bound observation is not a verdict. The same round trip (by sequence number) or the
/// same completion count has to be past its bound on `WatchdogLimits.ticksPerVerdict`
/// consecutive ticks. Many short round trips never trip it, however busy the connection is:
/// each is a different sequence with an age of its own, so none is old. Age is the stamp's own
/// start, never "the connection has been busy since".
///
/// ## Armed before the first read
///
/// `arm()` is the first statement of `HelperComposition.bringUp()`, ahead of reconciliation's
/// first read. Through the orderly teardown only the **round-trip** trigger stays armed:
/// stopping § 3 ends the cycle trigger, because a stopped supervisor is not a stall.
///
/// ## Sendable by construction
///
/// State is behind an `OSAllocatedUnfairLock`. The timer's handler holds this object for the
/// life of the process, deliberately: a watchdog that could be deallocated is one that can
/// silently stop.
final class LivenessWatchdog: Sendable {

    /// What was past its bound on a tick, identified so that "the same one on the next tick" is
    /// checkable. A round trip is its sequence number; a stalled cycle or bring-up is the
    /// completion count it stalled at.
    private enum Suspect: Sendable, Hashable {
        case roundTrip(sequence: UInt64)
        case bringUp(completions: UInt64)
        case cycle(completions: UInt64)
    }

    private struct State: Sendable {
        var isArmed = false
        /// Set inside the locked step that decides the verdict, so a later tick does nothing
        /// and exactly one `.fault` and one termination request follow.
        var fired = false
        /// For each suspect on the last tick, on how many consecutive ticks it has been one.
        var streaks: [Suspect: Int] = [:]
        /// The ticket of the last waiter a gate `.fault` was logged for, at each priority: the
        /// rate-collapse. A waiter that stays parked keeps its ticket, so it is logged once.
        /// Never the verdict's `fired`: a gate fault must not stand in the verdict's way.
        var gateFaulted: [SMCReadPriority: UInt64] = [:]
    }

    /// What one tick decided, taken inside the lock and acted on outside it. Gate faults are
    /// waiters past G not yet logged: log each, and end nothing.
    private enum Decision: Sendable {
        case nothing
        case verdict(WatchdogVerdict)
        case gateFaults([GateWait])
    }

    /// The monitor this watches, and the progress it reads. Internal rather than private so
    /// `HelperCompositionTests` can ask whether the watchdog holds the very objects the
    /// connection stamps and the supervisor reports into: a watchdog over a private copy of
    /// either watches nothing, and looks exactly like one that does.
    let roundTrips: SMCRoundTripMonitor
    let progress: ThermalCycleProgress
    let gateMonitor: GateWaitMonitor
    private let termination: ProcessTermination
    /// Internal for the same reason, and for one more: a composition whose default tick source
    /// quietly never fires arms, logs "armed", and never looks.
    /// `HelperCompositionTests` asks the shipping graph what it was given.
    let ticks: any WatchdogTicking
    private let log: WatchdogLog
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// No `Duration` parameter, by design (ADR 0012 I8): there is nothing to lengthen.
    init(
        roundTrips: SMCRoundTripMonitor,
        progress: ThermalCycleProgress,
        gateMonitor: GateWaitMonitor,
        termination: ProcessTermination,
        ticks: any WatchdogTicking,
        log: WatchdogLog = WatchdogLog()
    ) {
        self.roundTrips = roundTrips
        self.progress = progress
        self.gateMonitor = gateMonitor
        self.termination = termination
        self.ticks = ticks
        self.log = log
    }

    /// Starts watching. Idempotent. The bring-up bound runs from here.
    func arm() async {
        let first = state.withLock { state -> Bool in
            if state.isArmed { return false }
            state.isArmed = true
            return true
        }
        guard first else { return }
        progress.beginBringUp()
        log.armed()
        await ticks.start { [self] in tick() }
    }

    /// One look. Synchronous, and the whole of the watchdog's decision and its consequence:
    /// nothing in it suspends, so a test that calls it twice has the verdict, its `.fault` and
    /// the ending of the process the moment the second call returns.
    func tick() {
        let flight = roundTrips.inFlight()
        let reading = progress.reading()
        let parked = gateMonitor.oldestParked()

        let decision: Decision = state.withLock { state in
            guard !state.fired else { return .nothing }
            // Only what is past its bound on **this** tick keeps a streak: a suspect absent
            // from `found` is dropped, so "consecutive" means what it says.
            let found = Self.suspects(flight: flight, reading: reading)
            let streaks = Dictionary(
                uniqueKeysWithValues: found.map { ($0, (state.streaks[$0] ?? 0) + 1) })
            state.streaks = streaks
            // `found` is in priority order: a round trip names an operation, so it is reported
            // ahead of a stalled cycle that it may well be the cause of.
            let confirmed = found.first {
                (streaks[$0] ?? 0) >= WatchdogLimits.ticksPerVerdict
            }
            if let confirmed {
                state.fired = true
                return .verdict(Self.verdict(for: confirmed, flight: flight, reading: reading))
            }
            // Nothing to end the process for, so the third trigger: report, and only report.
            return .gateFaults(
                Self.newGateFaults(in: parked, flight: flight, logged: &state.gateFaulted))
        }

        switch decision {
        case .nothing:
            return
        case .gateFaults(let waits):
            for wait in waits { log.gateWaiter(wait, stamp: flight, phase: reading.phase) }
        case .verdict(let verdict):
            // The claim first, then the line, so that the line says what is true: that this
            // watchdog is ending the process, or that something else already is. Taken and
            // ended on this queue with no hand-off: a `Task` here needs a cooperative-pool
            // thread, and a verdict is only worth reaching when the pool may have none.
            switch termination.claim(.blind) {
            case .granted(let ending):
                log.verdict(verdict)
                ending.end()
            case .refused(let holder):
                log.verdictNotEnding(verdict, alreadyEndingAs: holder)
            }
        }
    }

    // MARK: - Deciding

    /// What is past its bound as of this tick, **in the order a verdict prefers**: the round
    /// trip first. The phase decides which of the other two can apply, so at most one does.
    private static func suspects(
        flight: SMCRoundTripInFlight?, reading: ThermalCycleProgress.Reading
    ) -> [Suspect] {
        var found: [Suspect] = []
        if let flight, flight.age > WatchdogLimits.roundTrip {
            found.append(.roundTrip(sequence: flight.sequence))
        }
        switch reading.phase {
        case .disarmed:
            break
        case .bringUp:
            if reading.sinceLastCompletion > WatchdogLimits.bringUpBound {
                found.append(.bringUp(completions: reading.completions))
            }
        case .cycling:
            if reading.sinceLastCompletion > WatchdogLimits.cycleBound {
                found.append(.cycle(completions: reading.completions))
            }
        }
        return found
    }

    /// The waiters to log a gate `.fault` for on this tick, recording them as logged: those that
    /// have waited **longer than** G and are not the last one logged at their priority, unless a
    /// **stamped round trip older than one tick** is in flight. That is the suppression: the
    /// stamp explains the wait and has alarms of its own. One tick and not D, deliberately: a
    /// stamp between the two is no verdict yet, and suppressing only past D would log a
    /// duplicate for one wedge. A suppressed waiter is **not** recorded: owed, not forgiven.
    private static func newGateFaults(
        in parked: [GateWait], flight: SMCRoundTripInFlight?,
        logged: inout [SMCReadPriority: UInt64]
    ) -> [GateWait] {
        if let flight, flight.age > WatchdogLimits.tick { return [] }
        var due: [GateWait] = []
        for wait in parked
        where wait.age > WatchdogLimits.gateWaiterAlarm && logged[wait.priority] != wait.ticket {
            logged[wait.priority] = wait.ticket
            due.append(wait)
        }
        return due
    }

    private static func verdict(
        for suspect: Suspect, flight: SMCRoundTripInFlight?,
        reading: ThermalCycleProgress.Reading
    ) -> WatchdogVerdict {
        switch suspect {
        case .roundTrip:
            return WatchdogVerdict(
                trigger: .roundTrip, bound: WatchdogLimits.roundTrip,
                age: flight?.age ?? .zero, stamp: flight, progress: reading)
        case .bringUp:
            return WatchdogVerdict(
                trigger: .bringUp, bound: WatchdogLimits.bringUpBound,
                age: reading.sinceLastCompletion, stamp: flight, progress: reading)
        case .cycle:
            return WatchdogVerdict(
                trigger: .cycle, bound: WatchdogLimits.cycleBound,
                age: reading.sinceLastCompletion, stamp: flight, progress: reading)
        }
    }
}
