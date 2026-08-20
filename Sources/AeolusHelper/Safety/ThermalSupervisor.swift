import Foundation

/// The loop that drives `docs/SAFETY.md` § 3: *"the helper samples critical sensors every
/// cycle"*.
///
/// Written as a near-copy of `LeaseExpirySupervisor` — start, stop, a detached task, a
/// clock it is given — and that similarity is deliberate rather than accidental
/// duplication. The two loops enforce **independent** mechanisms: § 1's TTL and § 3's
/// ceiling are actor levels 5 and 2, and ADR 0005's rule that the lease's paths back to
/// automatic "share no code path" generalises. A single supervisor running both would make
/// one cancelled task defeat two mechanisms at once, which is the failure mode
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s hole 1 is about.
///
/// ## What it is not
///
/// It schedules nothing on the SMC connection. Whether a supervisor read pre-empts a
/// client snapshot on the single connection ADR 0006 mandates — a snapshot costing 2.2 s
/// warm against a 1 Hz cycle — is
/// [#127](https://github.com/blamechris/Aeolus/issues/127)'s to settle, in
/// `SMCFanControlPlane` and whatever owns connection access. This loop only says *when* a
/// cycle should happen.
///
/// **Nothing starts it yet.** Actor level 2 has no fans to take back until E3 or E4 builds
/// a write path, and `AeolusHelperMain` still serves `ReadOnlyFanAuthority`, which grants no
/// lease at all. Wiring the start into the daemon's lifecycle is
/// [#103](https://github.com/blamechris/Aeolus/issues/103)'s, alongside startup
/// reconciliation and signal teardown.
actor ThermalSupervisor<Plane: FanControlPlane> {

    /// One cycle per second.
    ///
    /// The cadence `SAFETY.md` § 3 and #125 both assume, and the one the app already renders
    /// `isThermalEmergencyActive` at — so a user watching the banner sees it within one
    /// cycle of the mechanism deciding, rather than within one cycle plus one poll.
    ///
    /// Computed rather than stored because a generic type cannot hold a static stored
    /// property.
    static var defaultInterval: Duration { .seconds(1) }

    /// The soonest a pass will sleep for, so a misconfigured interval cannot spin a core in
    /// a root daemon. `LeaseExpirySupervisor` carries the same floor for the same reason.
    static var minimumWake: Duration { .milliseconds(10) }

    private let emergency: ThermalEmergency<Plane>
    private let clock: any MonotonicClock
    private let interval: Duration
    private let log: SafetyLog

    private var task: Task<Void, Never>?

    init(
        emergency: ThermalEmergency<Plane>,
        clock: some MonotonicClock = SystemMonotonicClock(),
        interval: Duration = ThermalSupervisor.defaultInterval,
        log: SafetyLog = SafetyLog()
    ) {
        self.emergency = emergency
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
        let emergency = self.emergency
        let clock = self.clock
        let interval = self.interval
        let log = self.log
        task = Task.detached {
            await Self.run(emergency: emergency, clock: clock, interval: interval, log: log)
        }
        return true
    }

    /// Whether a loop is running.
    var isRunning: Bool { task != nil }

    /// Stops the loop.
    ///
    /// The latch is **not** cleared by stopping. A supervisor that released § 3 on its way
    /// out would hand the fans back to a client on a machine nobody has read since it was
    /// above its ceiling — the failure asymmetry's second branch, reached through a
    /// lifecycle event instead of a bad reading.
    ///
    /// **The consequence, stated rather than left to be discovered.**
    /// `ThermalEmergency.cycle()` is the only caller of `ThermalEmergencyLatch.release()`
    /// anywhere in `Sources/`, so stopping while latched leaves § 3 engaged for the life of
    /// the process: `acquireLease` refuses `.thermalEmergencyActive` forever and every
    /// snapshot reports an emergency that is no longer happening. That is the right trade —
    /// refusing manual control is safe, releasing blind is not — but it is a trade, and the
    /// loop now says so at `.fault` on its way out.
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
        emergency: ThermalEmergency<Plane>,
        clock: some MonotonicClock,
        interval: Duration,
        log: SafetyLog = SafetyLog()
    ) async {
        while !Task.isCancelled {
            await emergency.cycle()

            let wake = max(
                clock.now.advanced(by: interval), clock.now.advanced(by: minimumWake))
            do {
                try await clock.sleep(until: wake)
            } catch {
                break
            }
        }
        // `LeaseExpirySupervisor` ends the same way, for the reason it gives: a safety
        // enforcer that went quiet without saying so would be the worst silent failure in
        // the project. It is more true here — see `stop()`.
        log.thermalSupervisorStopped(whileLatched: await emergency.isHolding)
    }
}
