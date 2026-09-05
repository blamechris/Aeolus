import AeolusXPC
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
/// — or for `idleInterval` when the table is empty — and in **neither** case for longer
/// than `maximumWake`, except where the anti-spin floor `minimumWake` is the higher of the
/// two and wins. That exception is unreachable as the two are configured — 10 ms against a
/// 5 s cap, and `idlesBelowTheShortestGrantableTimeToLive` reddens long before they could
/// cross — and it is written down because a summary stronger than the code it summarises is
/// how a reader stops checking.
///
/// That cap is the safety argument, and it is one sentence: **a lease granted during a
/// sleep has at least the shortest grantable TTL still to run at the moment it is
/// granted**, so a pass that wakes within that span cannot be late for it. `LeaseRecord`
/// lapses on `>=`, so even a lease granted in the same instant the pass parked is swept
/// exactly at its deadline rather than one wake after it.
///
/// The cap is what the deadline branch was missing. The table is free to change while a
/// pass is parked — a holder releases, and a second client takes a five-second lease — and
/// the deadline a pass sleeps to was read before any of that happened. Sleeping to lease
/// A's deadline is not a bound on lease B's, and the direction that hurts is a *shorter*
/// lease replacing a longer one, which made the TTL arbitrarily late rather than merely
/// imprecise: ~115 seconds of a lapsed lease still holding the fans with no live claim
/// behind it ([#151](https://github.com/blamechris/Aeolus/issues/151)). `maximumWake` is a
/// bound on both branches because it does not consult the table at all.
///
/// It is **derived** from `AeolusXPCValidation.leaseTTLRange` rather than restated against
/// it, so if the floor of that range is ever lowered the cap comes down with it and no
/// comment has to be believed.
///
/// The idle interval keeps its own coupling to that same floor, and that one is still a
/// hand-written constant: `defaultIdleInterval` has to stay **below** the shortest grantable
/// TTL, so lowering the floor obliges lowering the constant with it, and
/// `idlesBelowTheShortestGrantableTimeToLive` is the test that goes red if nobody does. It
/// sits far below the cap, so nothing about the idle branch changes here — what changed is
/// that it is no longer the only thing standing between a table change and a late expiry.
///
/// What it costs is one wake every five seconds while a lease is outstanding, against a
/// client that is already renewing on a heartbeat of a third of its TTL, and nothing at all
/// when the table is empty. What it buys is the property `docs/SAFETY.md` § 1 claims
/// outright: the TTL backstops every other mechanism for as long as the helper is alive.
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

    /// The longest a pass will sleep for, whatever the table says — the shortest TTL the
    /// helper will grant, read from the validator that enforces it rather than written out
    /// here. See the type's documentation for why every sleep is bounded by it.
    static let maximumWake: Duration = .seconds(AeolusXPCValidation.leaseTTLRange.lowerBound)

    /// The soonest a pass will sleep for. A sweep leaves no lapsed lease behind, so a
    /// deadline in the past should be unreachable — this is what stops "should be" from
    /// becoming a root daemon spinning a core.
    static let minimumWake: Duration = .milliseconds(10)

    private let authority: LeaseAuthority
    private let clock: any MonotonicClock
    private let idleInterval: Duration
    private let log: LeaseLog

    private var task: Task<Void, Never>?

    /// Which loop `task` refers to. See `loopEnded(generation:)`.
    private var generation: UInt64 = 0

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
        generation &+= 1
        let generation = self.generation
        let authority = self.authority
        let clock = self.clock
        let idleInterval = self.idleInterval
        let log = self.log
        task = Task.detached { [weak self] in
            await Self.run(
                authority: authority, clock: clock, idleInterval: idleInterval, log: log)
            await self?.loopEnded(generation: generation)
        }
        return true
    }

    /// Whether a loop is running. Diagnostics, and what makes `stop()` checkable.
    ///
    /// The loop, not the handle — `ThermalSupervisor.isRunning` states the defect
    /// ([#131](https://github.com/blamechris/Aeolus/issues/131)) this shape, which
    /// originated here, shared with both its siblings. The fix is identical in all three.
    var isRunning: Bool { task != nil }

    /// Clears the handle when the loop ends, whichever exit it took.
    ///
    /// Generation-checked rather than an unconditional `task = nil`, for the reason
    /// `ThermalSupervisor.loopEnded(generation:)` gives in full: `stop()` cancels without
    /// awaiting, so a superseded loop can finish after its replacement has started, and
    /// clearing the handle from there would let two supervisors sweep one lease table.
    private func loopEnded(generation: UInt64) {
        guard generation == self.generation else { return }
        task = nil
    }

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

            // Read *before* the table is consulted, and that order is the whole of the
            // cap's argument. A lease committed after this read is bounded by
            // `consultedAt + maximumWake`, which is no later than its own deadline; a lease
            // committed before it is already visible to `nextExpiryDeadline()` on the next
            // line, because that call is serialised behind it on the authority. Reading the
            // clock after the hop instead anchors the cap to the *resume* instant, which
            // narrows the window to the hop's latency rather than closing it.
            let consultedAt = clock.now
            let earliest = await authority.nextExpiryDeadline()
            let candidate = earliest ?? consultedAt.advanced(by: idleInterval)
            // The cap applies to both branches, and it is the one part of the wake that is
            // not derived from state another actor can invalidate while this pass is parked.
            let capped = min(candidate, consultedAt.advanced(by: maximumWake))
            // The floor applies to both branches, and it reads the clock again on purpose:
            // its question is how much time is left *now*, not when this pass began, and a
            // floor anchored to a stale instant is one that can already be in the past. A
            // misconfigured idle interval is as good a way to spin a core as a deadline in
            // the past, and the floor is applied after the cap so that a floor above the cap
            // still refuses to spin.
            let wake = max(capped, clock.now.advanced(by: minimumWake))

            do {
                try await clock.sleep(until: wake)
            } catch {
                break
            }
        }
        log.supervisorStopped(leasesOutstanding: await authority.leaseCount)
    }
}
