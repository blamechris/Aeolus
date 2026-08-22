import Foundation

/// The loop that drives `docs/SAFETY.md` § 5.
///
/// A near-copy of `ThermalSupervisor`, which is itself a near-copy of
/// `LeaseExpirySupervisor`, and the duplication is the design rather than an oversight.
/// `ThermalSupervisor` states the argument in full: these loops enforce **independent**
/// mechanisms at different actor levels, and a single supervisor running two of them would
/// make one cancelled task defeat both at once — [ADR
/// 0007](../../../docs/ADR/0007-safety-composition.md)'s hole 1. § 3 is level 2 and § 5 is
/// level 3; they get separate tasks.
///
/// A shared *type* with two instances would satisfy that argument while removing the
/// duplication, since the objection is to one task driving two mechanisms rather than to
/// one loop implementation. It is not done here because generalising `ThermalSupervisor`
/// means editing a safety-critical file in the change that adds a second safety mechanism,
/// which is the wrong order — the same reasoning `ThermalEmergency` gives for leaving its
/// own file over the line limit. [#128](https://github.com/blamechris/Aeolus/issues/128)
/// owns that space.
///
/// ## What it is not
///
/// It schedules nothing on the SMC connection, and it does not decide who reads first.
/// `SMCReadScheduler` owns that. What this loop guarantees is only that
/// `ReclamationWatchdog.cycle()` — which is itself strictly sequential across fans, for the
/// reasons that type documents — is entered once per interval and never re-entered
/// concurrently with itself, because each pass is awaited before the sleep.
///
/// **Nothing starts it.** No lease can be granted in this build, so no fan is ever off
/// automatic control and the watchdog's registry is permanently empty.
/// [#103](https://github.com/blamechris/Aeolus/issues/103) owns wiring both supervisors into
/// the daemon's lifecycle, alongside startup reconciliation and signal teardown.
actor ReclamationSupervisor<Plane: FanControlPlane> {

    /// One cycle per second, matching § 3's.
    ///
    /// The two loops are independent but not usefully out of step: § 5's dwell and blind-cycle
    /// budgets are expressed in cycles (`ReclamationLimits`), and their conversion to seconds
    /// assumes this cadence. Changing it changes what those constants mean, which is why the
    /// figure lives here beside them rather than being passed in from a call site.
    ///
    /// Computed rather than stored because a generic type cannot hold a static stored
    /// property.
    static var defaultInterval: Duration { .seconds(1) }

    /// The soonest a pass will sleep for, so a misconfigured interval cannot spin a core in
    /// a root daemon. Both sibling supervisors carry the same floor for the same reason.
    static var minimumWake: Duration { .milliseconds(10) }

    private let watchdog: ReclamationWatchdog<Plane>
    private let clock: any MonotonicClock
    private let interval: Duration
    private let log: SafetyLog

    private var task: Task<Void, Never>?

    init(
        watchdog: ReclamationWatchdog<Plane>,
        clock: some MonotonicClock = SystemMonotonicClock(),
        interval: Duration = ReclamationSupervisor.defaultInterval,
        log: SafetyLog = SafetyLog()
    ) {
        self.watchdog = watchdog
        self.clock = clock
        self.interval = interval
        self.log = log
    }

    /// Starts the loop. Idempotent.
    ///
    /// `Task.detached` for `LeaseExpirySupervisor`'s reason: an unstructured task created in
    /// an actor-isolated context inherits that isolation, so a loop that never returns would
    /// hold this actor for the life of the process and `stop()` could only run in the gaps.
    ///
    /// - Returns: `true` when this call started the loop, `false` when one was already
    ///   running — so "starting twice runs one supervisor" is a fact a test can check rather
    ///   than a guard whose deletion nothing would notice.
    @discardableResult
    func start() -> Bool {
        guard task == nil else { return false }
        let watchdog = self.watchdog
        let clock = self.clock
        let interval = self.interval
        let log = self.log
        task = Task.detached {
            await Self.run(watchdog: watchdog, clock: clock, interval: interval, log: log)
        }
        return true
    }

    /// Whether a loop is running.
    var isRunning: Bool { task != nil }

    /// Stops the loop.
    ///
    /// The watchdog's registry is **not** cleared by stopping, and no fan is restored on the
    /// way out. That asymmetry is deliberate and it runs the opposite way to
    /// `ThermalSupervisor.stop()`'s: § 3 leaves its latch engaged because releasing it would
    /// hand fans back on a machine nobody has read, whereas here the fans are already held
    /// by a client with a live lease and a running TTL. Restoring them from a stopping
    /// supervisor would take working manual control away from a user because a loop was
    /// cancelled, which is over-firing on a lifecycle event rather than on a reading.
    ///
    /// **The consequence, stated rather than left to be discovered.** While stopped, nothing
    /// watches for the firmware taking a fan back: a reclamation goes unnoticed, the snapshot
    /// keeps reporting Aeolus's target, and the lease TTL is the only surviving backstop.
    /// The loop says so at `.fault` on its way out when any fan is still held.
    /// [#103](https://github.com/blamechris/Aeolus/issues/103) owns the restart policy that
    /// makes it recoverable.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// One supervisor, running to cancellation.
    ///
    /// `static` and taking everything it needs as parameters so a test drives the real loop
    /// against a clock whose `sleep` returns instantly, rather than testing a paraphrase of
    /// it against wall time.
    ///
    /// `cycle()` cannot throw, so the only error to reason about is cancellation from the
    /// sleep — handled explicitly rather than with `try?`, which this repository's
    /// `no_silent_write_failure` rule refuses outright in the helper.
    static func run(
        watchdog: ReclamationWatchdog<Plane>,
        clock: some MonotonicClock,
        interval: Duration,
        log: SafetyLog = SafetyLog()
    ) async {
        while !Task.isCancelled {
            await watchdog.cycle()

            let wake = max(
                clock.now.advanced(by: interval), clock.now.advanced(by: minimumWake))
            do {
                try await clock.sleep(until: wake)
            } catch {
                break
            }
        }
        log.reclamationSupervisorStopped(fansHeld: await watchdog.fansUnderManualControl.count)
    }
}
