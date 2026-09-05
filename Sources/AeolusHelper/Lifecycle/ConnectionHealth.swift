import os

/// The lifecycle owner's answer to *"the helper is blind, and nothing is doing anything
/// about it"*.
///
/// ## The case this exists for
///
/// `docs/SAFETY.md` § 5 already escalates blindness **on a fan the helper is holding**: the
/// reclamation watchdog cannot read fan 0, so it reconnects, restores it to automatic and
/// reports. That path is complete and this changes none of it.
///
/// What it does not cover is the machine holding *nothing*. With no lease outstanding, § 5's
/// registry is empty, so the watchdog examines no fan, so no read fails on its path, so
/// nothing ever escalates — and the helper sits with a dead `io_connect_t`, answering every
/// `snapshot` with an error and every `acquireLease` with a blindness refusal, for the life
/// of the process. #103's decision A6 names it: *"never sit blind holding nothing"*, which is
/// [#68](https://github.com/blamechris/Aeolus/issues/68)'s render-unavailable-forever case.
///
/// So this counts whole-read failures **on either path** — the client snapshot and the
/// supervisor cycle both — and fires one reconnect when a run of them says the connection
/// rather than a sensor is the problem.
///
/// ## Why the scheduler is where it listens
///
/// Because the scheduler is the only place the two paths meet. `SnapshotSensorReads` and
/// `SMCFanControlPlane` are different types with different callers and different error
/// vocabularies, and both bottom out in `SMCReadScheduler.read(keys:at:)`. Counting there
/// means "either path" is *definitional* rather than a pair of call sites somebody has to
/// remember to keep in step.
///
/// ## What it is not
///
/// - **Not a retry loop, though it is not a single attempt either.** One rebuild per run of
///   failures, and at most one per `ConnectionHealthLimits.minimumInterval`. On a machine
///   whose SMC is genuinely gone that is one attempt every thirty seconds for as long as
///   reads keep failing — bounded in *rate*, never in total, because an SMC that comes back
///   on its own has to be noticed and nothing else here would notice it. This bullet said
///   "rebuilds the handle once and stops" until a review pointed out that the thirty-second
///   window is precisely what makes that false. Whether reading works again is answered by
///   the next read, which arrives on its own from a path that is already polling.
/// - **Not a recovery announcement.** Nothing here says the SMC is back. A clean
///   `reconnect()` means the handle was rebuilt and no more — `CLAUDE.md` rule 6.
/// - **Not a safety mechanism.** It restores no fan and revokes no lease. A fan Aeolus is
///   holding while blind is § 5's, and § 5 is unchanged and still first: this fires on a
///   machine where § 5 has nothing to look at.
/// - **Not a supervisor.** It has no loop and no clock tick. It is driven entirely by reads
///   that other mechanisms were making anyway, which is why it costs nothing on a healthy
///   machine.
///
/// ## Ordering, and why there is a pump
///
/// "Three failures in a row" is a claim about order, and `SchedulerObserving` is called from
/// inside the scheduler's actor — so the reports arrive ordered and must be *kept* that way.
/// A `Task` per event would hand them to the cooperative pool in whatever order it liked, and
/// a success overtaking a failure silently resets a run that had not ended.
///
/// An `AsyncStream` is what preserves it: `yield` is synchronous, ordered, and returns at
/// once, so the scheduler is never held; a single consumer task drains it in order. The pump
/// is needed regardless of ordering, because `reconnect()` is `async` and takes a scheduler
/// turn — calling it from inside `schedulerDidObserve(_:)` would be the scheduler waiting on
/// a turn only the scheduler can grant.
actor ConnectionHealth: SchedulerObserving {

    /// The clock the rate limit is measured on.
    ///
    /// `MonotonicClock` rather than `ContinuousClock` directly, so a test can prove the
    /// window *reopens* — which is the half of a rate limit that a fast test cannot otherwise
    /// reach, and the half whose absence would be a helper that reconnects once per boot.
    private let clock: any MonotonicClock
    private let log: SafetyLog

    private let events: AsyncStream<SequencedOutcome>

    /// Written from inside the scheduler's actor, so it is `nonisolated` and must stay that
    /// way: an `await` here would put a hop between the scheduler and its own report.
    nonisolated private let continuation: AsyncStream<SequencedOutcome>.Continuation

    /// The numbering that makes a buffer eviction visible. See `eventBuffer`.
    ///
    /// It cannot be actor state: `schedulerDidObserve(_:)` assigns it and is `nonisolated`,
    /// because it is called from inside `SMCReadScheduler`'s own isolation and an `await`
    /// there would put a hop between the scheduler and its own report.
    ///
    /// `OSAllocatedUnfairLock` rather than a hand-written box, and that is `CLAUDE.md` rule 10
    /// deciding rather than a preference. The two alternatives both fail on their own terms: a
    /// final class round an `NSLock` needs a `Sendable` conformance the compiler cannot check,
    /// which is exactly the claim this target's lint rule refuses in privileged code, and
    /// `Synchronization.Atomic` needs macOS 15 against this package's macOS 13 floor. This one
    /// is audited by the SDK rather than asserted by us, and it satisfies `SchedulerObserving`'s
    /// obligation exactly: held across one increment, never across an `await`, and nothing else
    /// in the process can be holding it.
    ///
    /// `UInt64` so "could it wrap" has an answer that is arithmetic rather than judgement: at
    /// the corrected steady state of ~8 outcomes a second, about seventy billion years.
    nonisolated private let sequence = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    private var pump: Task<Void, Never>?

    /// Whether this instance is draining events right now.
    ///
    /// `false` before `start(recovering:)`, after `stop()`, and after a `start(recovering:)`
    /// that `stop()` refused. It is the sentinel that keeps the last of those from being the
    /// "looks started, observes nothing" shape `stop()`'s own documentation says this
    /// repository refuses — a `pump != nil` test could not tell it apart, because a pump over
    /// a finished stream is a non-`nil` task that has already returned.
    private(set) var isObserving = false

    /// Whether `stop()` has been called. One-way, like `stop()` itself.
    private var hasStopped = false

    /// Whole reads that have failed since the last one that succeeded.
    private var consecutiveFailures = 0

    /// The sequence number of the last outcome handled, or `nil` before the first.
    private var lastHandledSequence: UInt64?

    /// Forwarded outcomes the buffer threw away before the pump could reach them.
    ///
    /// Here for the tests, like `reconnectAttempts` and `observedOutcomes`, and it is the only
    /// way an eviction is observable at all: the effect of one is that a run *ends*, which is
    /// indistinguishable from the run having ended for the ordinary reason. The count is
    /// exact rather than a flag because the gap says how many went missing, and a fixture that
    /// overflowed the buffer by more than it meant to should say so rather than pass.
    private(set) var outcomesLostToTheBuffer = 0

    /// When the last reconnect was attempted, or `nil` if none has been.
    private var lastAttemptAt: ContinuousClock.Instant?

    /// Whether the refusal has already been logged for the window `lastAttemptAt` opened.
    ///
    /// The line is a `.fault`, and a machine whose `open()` keeps failing produces a run every
    /// ~1.5 s for the whole thirty seconds — so logging the *state* would put twenty fault
    /// lines in `log show` per window saying the same thing. It is logged as a **transition**
    /// instead, once when the helper first refuses inside a window, which is the discipline
    /// `ReclamationWatchdog` already uses. Cleared when a rebuild is actually attempted,
    /// because that is what opens the next window.
    private var hasLoggedRefusalInThisWindow = false

    /// How many reconnects have been attempted.
    ///
    /// Here because the tests need it and for no other reason — #103's A7 says to wire the
    /// hook without an emission policy, and a counter nothing reads is the first inch of one.
    /// It is the *attempt* count rather than a success count on purpose: whether a reconnect
    /// helped is not a thing this type is entitled to claim.
    private(set) var reconnectAttempts = 0

    /// How many whole-read outcomes have been fully handled.
    ///
    /// Also here for the tests, and it earns its place: without it a test that yields N
    /// failures can only wait on the *effect* it is asserting, so "exactly one reconnect
    /// fired" would be indistinguishable from "the second one has not been processed yet".
    /// Incremented **after** the event is handled, including after any reconnect it caused,
    /// so reaching N means all N are done rather than started.
    private(set) var observedOutcomes = 0

    init(clock: some MonotonicClock = SystemMonotonicClock(), log: SafetyLog = SafetyLog()) {
        self.clock = clock
        self.log = log
        let (events, continuation) = AsyncStream<SequencedOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        self.events = events
        self.continuation = continuation
    }

    /// How many unhandled outcomes are kept before the oldest are dropped.
    ///
    /// Bounded rather than unbounded, because an observer wired to a scheduler that is never
    /// started — or one whose pump is stuck inside a slow `reconnect()` — must not grow a
    /// queue in a root daemon that never exits.
    ///
    /// ## The hazard runs both ways, and an earlier version of this comment saw one of them
    ///
    /// `.bufferingNewest` drops the **oldest** unhandled outcome. In the direction that was
    /// documented, a dropped *failure* can only delay a reconnect the next failure asks for
    /// again. In the direction that was not, a dropped *success* joins two runs of failures
    /// that were never consecutive into one that looks it — and produces a rebuild of a handle
    /// that is working. That is the worse of the two and it was the one being argued away.
    ///
    /// So an eviction is made **detectable** rather than reasoned about: every forwarded
    /// outcome carries a `SequencedOutcome.sequence`, the pump compares it against the last it
    /// handled, and a gap ends the run — because a run with a hole in it is not a fact about
    /// three consecutive reads, whatever was in the hole. `outcomesLostToTheBuffer` records
    /// how many went missing.
    ///
    /// ## The backlog this buys, corrected
    ///
    /// It is not the half-minute an earlier draft claimed. A `snapshot()` is **three** reads,
    /// not one (see `SMCReadScheduler`), the supervisor cycle is one per second, and
    /// `LeaseAuthority.refuseIfBlind` issues one per `acquireLease` off any cycle at all — so
    /// a machine with a client attached forwards roughly four to eight outcomes a second, and
    /// 64 slots is **eight to sixteen seconds**. Still far longer than a pump that is merely
    /// hopping actors needs, which is the case the bound exists for; the number is quoted
    /// honestly because the previous one was quoted as a safety argument.
    private static let eventBuffer = 64

    // MARK: - Observing

    /// Forwards **only** whole-read outcomes, and drops everything else at the door.
    ///
    /// Not a filter for tidiness: the turn events outnumber the read outcomes by roughly the
    /// turn count of a snapshot — 46 to 1 on `Mac16,5` — so a buffer that carried them would
    /// evict the outcomes this type exists to count, with the eviction invisible. The turn
    /// events are for [#133](https://github.com/blamechris/Aeolus/issues/133) and
    /// [#135](https://github.com/blamechris/Aeolus/issues/135), which will hold observers of
    /// their own.
    nonisolated func schedulerDidObserve(_ event: SchedulerEvent) {
        switch event {
        case .wholeReadSucceeded, .wholeReadFailed:
            // Numbered here rather than in the pump, because a number assigned after the
            // buffer could not describe what the buffer threw away.
            let next = sequence.withLock { issued -> UInt64 in
                issued += 1
                return issued
            }
            continuation.yield(SequencedOutcome(sequence: next, event: event))
        case .waiterParked, .turnGranted, .turnEnded, .overtakeTaken, .quotaExhausted:
            break
        }
    }

    // MARK: - Lifecycle

    /// Binds the recovery seam and starts draining events. Called once, from
    /// `HelperComposition.bringUp()`.
    ///
    /// Events yielded before this are buffered and handled on start, which is deliberate:
    /// the scheduler is constructed before the composition and the very first reads of the
    /// process — reconciliation's — happen during bring-up. A failure there is exactly the
    /// case worth counting.
    ///
    /// **Discovery's walk is not among them**, and this comment named it until a review
    /// checked. `SMCReadScheduler.readAll()` emits no scheduler event at all, so a walk that
    /// fails during bring-up is counted by nothing here. Reporting it would need a decision
    /// this change does not take: whether a 2.2 s — 5.9 s cold — walk's outcome belongs in the
    /// same run as reads issued at 1 Hz.
    ///
    /// **`recovery` is carried by the pump rather than stored**, and that is what removes the
    /// unbound state entirely. Late binding is forced by the graph — the plane holds the
    /// scheduler, the scheduler holds this observer, and this observer reconnects through the
    /// plane, so something has to exist before the thing it talks to. Storing an optional
    /// would express that as a `nil` every later read has to reason about, and the branch
    /// would be unreachable: nothing is handled before the pump exists, and the pump does not
    /// exist before this call. Passing it down the one path that can reach a reconnect makes
    /// "not yet bound" mean "not yet draining", which is true.
    /// A `start(recovering:)` after `stop()` is **refused**, loudly and observably, rather
    /// than accepted. Accepting it used to build a pump over a finished stream: the `for
    /// await` returns at once, `pump` is left holding a task that has already exited, and the
    /// instance looks started while observing nothing — the exact shape `stop()`'s own
    /// documentation says is refused, one method away from where it says it. `isObserving`
    /// is what makes the refusal a fact a caller can read.
    func start(recovering recovery: some SMCConnectionRecovering) {
        guard !hasStopped else {
            log.connectionHealthRestartRefused()
            return
        }
        guard pump == nil else { return }
        isObserving = true
        pump = Task { [events] in
            for await outcome in events {
                await self.handle(outcome, recovering: recovery)
            }
        }
    }

    /// Stops draining. One-way: the stream is finished, so this instance observes nothing
    /// more.
    ///
    /// One-way rather than restartable because the alternative is worse. An `AsyncStream` has
    /// one iterator, so a "restart" would have to build a second stream — and the continuation
    /// the scheduler holds is `nonisolated let`, captured at construction, so it would keep
    /// yielding into the first one. A stop that silently stopped observing while looking
    /// started is the shape this repository keeps refusing — which is why `start(recovering:)`
    /// refuses after this rather than obliging.
    func stop() {
        hasStopped = true
        isObserving = false
        continuation.finish()
        pump?.cancel()
        pump = nil
    }

    // MARK: - The count

    private func handle(
        _ outcome: SequencedOutcome, recovering recovery: some SMCConnectionRecovering
    ) async {
        // A hole in the numbering means the buffer evicted something, and a run counted
        // across a hole is not a run. Ending it here is the conservative direction: the
        // machine that is really failing keeps producing failures and asks again a second and
        // a half later, whereas a manufactured run rebuilds a working handle immediately.
        if let lastHandledSequence, outcome.sequence > lastHandledSequence + 1 {
            outcomesLostToTheBuffer += Int(outcome.sequence - lastHandledSequence - 1)
            consecutiveFailures = 0
        }
        lastHandledSequence = outcome.sequence

        switch outcome.event {
        case .wholeReadSucceeded:
            consecutiveFailures = 0
        case .wholeReadFailed:
            consecutiveFailures += 1
            if consecutiveFailures >= ConnectionHealthLimits.consecutiveWholeReadFailures {
                await attemptReconnect(through: recovery)
            }
        case .waiterParked, .turnGranted, .turnEnded, .overtakeTaken, .quotaExhausted:
            // Never forwarded, so never seen. Handled exhaustively rather than with a
            // `default`, so adding a case to `SchedulerEvent` is a compile error here — the
            // one place a new event kind has to be thought about twice.
            return
        }
        observedOutcomes += 1
    }

    /// One reconnect, if the window allows it.
    ///
    /// The run is reset **before** the window is checked, and that ordering is the whole of
    /// the rate limit. Resetting only on success would leave `consecutiveFailures` above the
    /// threshold, so every subsequent failure would ask again and the limiter would be the
    /// only thing between the helper and a reconnect attempt per read — a check nothing may
    /// depend on alone.
    private func attemptReconnect(through recovery: some SMCConnectionRecovering) async {
        let run = consecutiveFailures
        consecutiveFailures = 0

        let now = clock.now
        if let lastAttemptAt, now - lastAttemptAt < ConnectionHealthLimits.minimumInterval {
            // Once per window, not once per refused run: see `hasLoggedRefusalInThisWindow`.
            guard !hasLoggedRefusalInThisWindow else { return }
            hasLoggedRefusalInThisWindow = true
            log.connectionReconnectRateLimited(
                consecutiveFailures: run, sinceLastAttempt: now - lastAttemptAt)
            return
        }

        lastAttemptAt = now
        hasLoggedRefusalInThisWindow = false
        reconnectAttempts += 1
        log.connectionReconnecting(consecutiveFailures: run)

        do {
            try await recovery.reconnect()
            log.connectionReconnected()
        } catch {
            log.connectionReconnectFailed(detail: String(describing: error))
        }
    }
}

// MARK: - What travels through the stream

/// One forwarded whole-read outcome, and its place in the order the scheduler reported it.
///
/// The sequence number is the whole reason this type exists rather than a bare
/// `SchedulerEvent`: it is what makes a buffer eviction observable to the pump, and an
/// eviction that is not observable is a run the buffer can manufacture. See
/// `ConnectionHealth.eventBuffer`.
private struct SequencedOutcome: Sendable {
    let sequence: UInt64
    let event: SchedulerEvent
}

// MARK: - The two numbers

/// What counts as a dead connection, and how often the helper may act on that belief.
///
/// Its own type for `ReclamationLimits`' reason: the numbers are the policy, and a policy
/// spelled as literals inside an actor is a policy a test has to restate rather than read.
/// Neither is configurable, and `CLAUDE.md` rule 5 is why — a file that could widen either
/// could stop the helper from ever noticing a dead connection.
enum ConnectionHealthLimits {

    /// Whole reads that must fail in a row before the connection itself is the suspect.
    ///
    /// Three, and the reasoning is about what a *smaller* number would catch. One is a
    /// transient: `SMCConnection.read(keys:)` fails a whole request for reasons that are not
    /// the handle, and reconnecting on every one would recycle the connection under the
    /// snapshot for a blip. Two is one transient plus its neighbour. Three consecutive
    /// whole-request failures across two independent paths is not a sensor and is not a blip.
    ///
    /// It is deliberately **not** measured in seconds. The snapshot runs at 1 Hz and the
    /// supervisor cycle at 1 Hz, so three failures is roughly a second and a half of
    /// blindness on a live machine — but a machine with no client attached is producing
    /// supervisor reads only, and a count says the same thing on both.
    static let consecutiveWholeReadFailures = 3

    /// The shortest gap between two reconnect attempts.
    ///
    /// A reconnect closes and reopens the `io_connect_t` under an exclusive scheduler turn,
    /// so it is not free: it stops both paths for its duration. Against a machine whose SMC
    /// is genuinely gone, an unlimited version would attempt one every three failed reads —
    /// roughly every 1.5 s, for ever — which turns a dead connection into a busy loop holding
    /// the very turn the safety cycle needs to discover that reading works again.
    ///
    /// Thirty seconds is chosen against the failure it is bounding rather than against a
    /// measurement: #68's stale handle is fixed by the *first* attempt or by none, so a
    /// second one exists only for the case where the SMC came back on its own, and half a
    /// minute is prompt at that timescale.
    static let minimumInterval: Duration = .seconds(30)
}
