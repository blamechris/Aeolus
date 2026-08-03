import Foundation

/// The TTL supervisor: the lease's **independent** path back to automatic control.
///
/// ## Why it is a separate type
///
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md): *"The TTL is the independent
/// backstop for the case where invalidation never fires. Either mechanism alone suffices;
/// both must fail for the fans to stay pinned; **they share no code path.**"*
/// `AeolusXPCProtocol` says the same thing from the other end: *"An implementation that
/// expires leases from the invalidation handler has one mechanism wearing two names."*
///
/// So this is a loop that knows nothing about connections. It has no reference to a
/// listener, no `ConnectionID` anywhere in its signature, and nothing delivers an event to
/// it. It reads a clock and it sweeps. A connection can die without this running, and this
/// can run without any connection dying — which is what "independent" has to mean if it is
/// to be checkable.
///
/// ## What it does, and why the schedule is safe
///
/// Each pass expires whatever has lapsed, then sleeps until the earliest remaining deadline
/// — or for `idleInterval` when the table is empty.
///
/// The idle interval is **shorter than the shortest TTL the helper will grant**
/// (`AeolusXPCValidation.leaseTTLRange` starts at 5 seconds), which is what makes an idle
/// sleep unable to make an expiry late: a lease acquired during an idle sleep is seen at the
/// next wake, at most `idleInterval` later, and its deadline is still at least four seconds
/// away at that point. If the floor of that range is ever lowered, this constant has to come
/// down with it — the two are coupled, and this sentence is the coupling.
///
/// ## Precedence
///
/// Lease expiry is an **actor** in [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s
/// precedence order — below sleep, above the control loop — and its terminal action is the
/// bounds-free restore verb. Nothing in this loop reads a bound, a sensor, or a clamp, and
/// the sweep it drives takes no arguments at all. If restoring ever needed something read
/// first, the design would be wrong.
actor LeaseExpirySupervisor {

    /// How long a pass waits when no lease is outstanding. See the type's documentation for
    /// why this is coupled to `AeolusXPCValidation.leaseTTLRange`'s lower bound.
    static let defaultIdleInterval: Duration = .seconds(1)

    /// The soonest a pass will sleep for. A sweep leaves no lapsed lease behind, so a
    /// deadline in the past should be unreachable — this is what stops "should be" from
    /// becoming a root daemon spinning a core.
    static let minimumWake: Duration = .milliseconds(10)

    private let authority: LeaseAuthority
    private let clock: any MonotonicClock
    private let idleInterval: Duration
    private let log: LeaseLog

    private var task: Task<Void, Never>?

    init(
        authority: LeaseAuthority,
        clock: some MonotonicClock = SystemMonotonicClock(),
        idleInterval: Duration = LeaseExpirySupervisor.defaultIdleInterval,
        log: LeaseLog = LeaseLog()
    ) {
        self.authority = authority
        self.clock = clock
        self.idleInterval = idleInterval
        self.log = log
    }

    /// Starts the loop. Idempotent.
    ///
    /// `Task.detached` rather than `Task {}`: an unstructured task created in an
    /// actor-isolated context inherits that isolation, and a loop that never returns would
    /// then hold this actor for the life of the process, so `stop()` could only run in the
    /// gaps. The loop needs nothing from this actor's state, so it is given none of it.
    ///
    /// - Returns: `true` when this call started the loop, `false` when one was already
    ///   running. Returned rather than swallowed so that "starting twice runs one
    ///   supervisor" is a fact a test can check, instead of a guard whose deletion nothing
    ///   would notice.
    @discardableResult
    func start() -> Bool {
        guard task == nil else { return false }
        let authority = self.authority
        let clock = self.clock
        let idleInterval = self.idleInterval
        let log = self.log
        task = Task.detached {
            await Self.run(
                authority: authority, clock: clock, idleInterval: idleInterval, log: log)
        }
        return true
    }

    /// Whether a loop is running. Diagnostics, and what makes `stop()` checkable.
    var isRunning: Bool { task != nil }

    /// Stops the loop.
    ///
    /// The fans are **not** left pinned by this on its own: connection death is still an
    /// independent path back to automatic, which is the whole point of there being two. The
    /// loop says so in the log on its way out, because a lease enforcer that went quiet
    /// without saying so would be the worst silent failure in the project.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// One supervisor, running to cancellation.
    ///
    /// `static` and taking everything it needs as parameters so that a test can drive the
    /// real loop directly — against a clock whose `sleep` returns instantly and which
    /// cancels the run after a fixed number of passes — rather than testing a paraphrase of
    /// it against wall time.
    ///
    /// Cancellation is the only way out, and it is handled explicitly rather than with
    /// `try?`: a swallowed error in the helper leaves the fans in an unknown state, and this
    /// repository's `no_silent_write_failure` rule refuses the shorthand outright.
    static func run(
        authority: LeaseAuthority,
        clock: some MonotonicClock,
        idleInterval: Duration,
        log: LeaseLog
    ) async {
        while !Task.isCancelled {
            await authority.expireLapsedLeases()

            let earliest = await authority.nextExpiryDeadline()
            let candidate = earliest ?? clock.now.advanced(by: idleInterval)
            // The floor applies to both branches. A misconfigured idle interval is as good
            // a way to spin a core as a deadline in the past.
            let wake = max(candidate, clock.now.advanced(by: minimumWake))

            do {
                try await clock.sleep(until: wake)
            } catch {
                break
            }
        }
        log.supervisorStopped(leasesOutstanding: await authority.leaseCount)
    }
}
