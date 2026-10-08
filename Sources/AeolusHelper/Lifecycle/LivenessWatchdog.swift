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

/// The daemon's tick source: a `.strict` `DispatchSourceTimer` on a queue of its own.
///
/// ## Why a dispatch queue and not a `Task`
///
/// The watchdog exists for the case where the cooperative pool and the connection actor are
/// not making progress. A timer driven by `Task.sleep` would run on the pool it is watching.
/// A dispatch timer on a serial queue of its own needs nothing from the pool, nothing from any
/// actor, and no executor the helper's own work could be holding.
///
/// ## Why the timer is kept
///
/// Held in this actor for `DispatchSignalSources`' reason: a source released by ARC is
/// cancelled, and a watchdog whose timer was released is a mechanism that stopped without
/// saying so. `HelperComposition` holds the watchdog, the watchdog holds this, and
/// `main()` parks the composition for the life of the process.
actor DispatchWatchdogTicks: WatchdogTicking {

    private let queue = DispatchQueue(
        label: "dev.aeolus.AeolusHelper.watchdog", qos: .userInitiated)

    private var timer: (any DispatchSourceTimer)?

    func start(_ handler: @escaping @Sendable () -> Void) {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(
            deadline: .now() + WatchdogLimits.tickInterval,
            repeating: WatchdogLimits.tickInterval,
            leeway: WatchdogLimits.timerLeeway)
        source.setEventHandler(handler: handler)
        source.resume()
        timer = source
    }
}

/// The helper's liveness watchdog (ADR 0012): if the helper cannot complete an SMC round trip
/// within D, or a safety cycle within D_cycle, it logs one `.fault` and ends the process
/// non-zero, as `TeardownOutcome.blind`. launchd restarts it, and startup reconciliation
/// restores automatic control.
///
/// ## What it does not do
///
/// It abandons nothing, times nothing out, and reopens nothing. A round trip that has not
/// returned is a thread parked in the kernel, and nothing in Swift can resume it; the only
/// abandonment that can be ordered is the process's death. A verdict runs **no orderly
/// teardown** and makes **no IOKit call**: the teardown awaits the same connection a wedge
/// holds. A false positive puts the fans back to automatic, which is the safe direction.
///
/// ## Three things it reads, none of them through an actor
///
/// - **The stamp** (`SMCRoundTripMonitor.inFlight()`): the round trip that has begun and not
///   returned, with its sequence number and an age on the suspending clock. A lock-guarded
///   copy. It never takes the connection, and this file names no `SMCConnection`
///   (`LivenessWatchdogTests` holds that).
/// - **Progress** (`ThermalCycleProgress`): how long since § 3 last completed a cycle.
/// - **Itself**: the previous tick's findings.
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
/// first read, and the watchdog stays armed through the orderly teardown.
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
    }

    /// The monitor this watches, and the progress it reads. Internal rather than private so
    /// `HelperCompositionTests` can ask whether the watchdog holds the very objects the
    /// connection stamps and the supervisor reports into: a watchdog over a private copy of
    /// either watches nothing, and looks exactly like one that does.
    let roundTrips: SMCRoundTripMonitor
    let progress: ThermalCycleProgress
    private let termination: ProcessTermination
    private let ticks: any WatchdogTicking
    private let log: WatchdogLog
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// No `Duration` parameter, by design (ADR 0012 I8): there is nothing to lengthen.
    init(
        roundTrips: SMCRoundTripMonitor,
        progress: ThermalCycleProgress,
        termination: ProcessTermination,
        ticks: any WatchdogTicking,
        log: WatchdogLog = WatchdogLog()
    ) {
        self.roundTrips = roundTrips
        self.progress = progress
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

    /// One look. Synchronous, and the whole of the watchdog's decision: nothing in it suspends,
    /// so a test that calls it twice has the verdict, and its `.fault`, the moment the second
    /// call returns.
    func tick() {
        let flight = roundTrips.inFlight()
        let reading = progress.reading()

        let verdict: WatchdogVerdict? = state.withLock { state in
            guard !state.fired else { return nil }
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
            guard let confirmed else { return nil }
            state.fired = true
            return Self.verdict(for: confirmed, flight: flight, reading: reading)
        }
        guard let verdict else { return }

        log.verdict(verdict)
        // The one bridge from this synchronous tick to the `async` terminate seam. The body
        // does nothing but hand off, which is the property `WriteVerbAllowlistTests` requires
        // of every unstructured `Task` in this target.
        let termination = self.termination
        Task { await termination.end(.blind) }
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
