import Foundation

/// The bounds on § 4, where a reviewer can find them.
///
/// A sibling of `RestoreLimits` and `ReclamationLimits`, kept apart from both for the reason
/// those two are kept apart from each other: these are numbers to be argued with, and a
/// constant buried at its point of use is how a bound stops being a decision.
enum SystemPowerLimits {

    /// How long the handback may take before the helper lets the machine sleep anyway.
    ///
    /// **Five seconds is a bound on the wait, not an estimate of the work.** A restore is one
    /// mode write per fan; on this project's development machine a subset SMC read costs
    /// ~0.5 ms and there are two fans. The budget is sized for the case that actually
    /// happens — a wedged `io_connect_t`
    /// ([#68](https://github.com/blamechris/Aeolus/issues/68)) where the write never returns
    /// at all — and `FanRestoreAttempting` states plainly that nothing below it can bound
    /// that: *"a single synchronous IOKit call that never comes back on a wedged connection
    /// parks `revokeEveryLease(because:)`"*, and `BoundedFanRestorer` bounds attempts rather
    /// than the wall clock.
    ///
    /// The kernel gives a process on the order of thirty seconds to acknowledge
    /// `kIOMessageSystemWillSleep` before sleeping regardless. Spending all of it would buy
    /// nothing — the write is either quick or wedged, and no interesting case sits at twenty
    /// seconds — while making every sleep on a wedged connection visibly slow. Five seconds
    /// keeps the acknowledgement well inside the kernel's window with the decision this
    /// helper's own, rather than taken from it by a timeout it cannot see.
    ///
    /// Overrunning it is **not** a safety failure, and that is why acknowledging anyway is
    /// the right answer: § 1's TTL is the backstop, on a clock that runs whether or not
    /// `ContinuousClock` advances across sleep — see `docs/SAFETY.md` § 4.
    static let acknowledgementBudget: Duration = .seconds(5)
}

/// The one acknowledgement of one `.willSleep`, whoever gets there first.
///
/// Two paths reach it — the handback finishing, and the budget expiring — and exactly one of
/// them may answer the system. An actor rather than a flag on the responder because those
/// two paths are concurrent by construction: the budget runs on a task of its own precisely
/// so that it does not have to wait for the handback, and a `Bool` read and written from both
/// would be the race this type exists to not have.
///
/// **First outcome wins, and the loser is silent.** The alternative — last writer wins — would
/// report the handback as the reason for a sleep the budget had already allowed, which is a
/// line in a root daemon's log saying the fans were handed back in time when they were not.
actor SleepAcknowledgement {

    /// Why the system was told it may sleep.
    enum Outcome: Sendable, Hashable {

        /// Every lease was dropped and the keystone restore was issued first.
        case handedBack

        /// The budget ran out with the handback still in flight. Logged at `.fault`.
        case budgetExpired
    }

    private let notification: SystemPowerNotification
    private let budget: Duration
    private let log: SafetyLog

    private var settledOutcome: Outcome?

    init(_ notification: SystemPowerNotification, budget: Duration, log: SafetyLog) {
        self.notification = notification
        self.budget = budget
        self.log = log
    }

    /// The outcome that answered the system, or `nil` while nobody has.
    var outcome: Outcome? { settledOutcome }

    /// Allows the power change, once.
    ///
    /// The log line is written **before** the acknowledgement rather than after it. A
    /// `.willSleep` acknowledgement is the last thing this process does before the machine
    /// stops running it, and `os_log` on the far side of that is a line that may not survive
    /// to be read — which would leave the budget-expiry fault, the one line § 4 has that says
    /// the fans may not have been handed back, as the least likely of all to be recorded.
    func acknowledge(_ outcome: Outcome) async {
        guard settledOutcome == nil else { return }
        settledOutcome = outcome

        switch outcome {
        case .handedBack:
            log.allowingSleepAfterHandback()
        case .budgetExpired:
            log.allowingSleepWithHandbackOutstanding(after: budget)
        }

        await notification.acknowledge()
    }
}

/// `docs/SAFETY.md` § 4: what the helper does when the machine goes to sleep, and what it
/// carefully does not do when it wakes up.
///
/// ## Sleep: release, restore, *then* acknowledge
///
/// The order is the mechanism. `.willSleep` is the one moment the system is waiting on this
/// process, so it is the only moment a fan can be handed back with any guarantee that the
/// handback precedes the machine stopping. Acknowledging first would keep the code
/// identical, keep every log line identical, and turn § 4 into a lease that happens to be
/// released around the same time as a sleep — which is exactly the failure
/// `docs/SAFETY.md` § 4 calls "the load-bearing half".
///
/// Both halves of the handback happen, and they are not the same act:
///
/// - **`LeaseAuthority.releaseEveryLease()`** empties the lease table and restores each
///   lease's fans through `HelperFanRestorer`, so both safety registries are told and § 5's
///   next cycle does not read the handback as a system reclamation.
/// - **`restoreToAutomatic(.everyFan)`** through the keystone is machine-wide and additionally
///   clears the Apple Silicon force key. It is issued unconditionally, after and regardless
///   of the first: the keystone "consumes no bounds, no clamp, no sensor reading, no lease and
///   no prior call of any kind", so a fan left in manual by something this process no longer
///   has a lease for is still covered.
///
/// ## Wake: nothing, and the absence is the feature
///
/// § 4: *"The helper never silently re-asserts manual control on wake."* This type holds a
/// `SafetyActorWriter` and could write; the `.didWake` branch logs and returns. That is
/// deliberately a behaviour rather than a structural impossibility, because the thing worth
/// testing is the branch a future edit would put a reconciliation into —
/// `SystemPowerTests.wakingWritesNothingAtAll` is red the moment one appears.
///
/// Reconciliation on wake is the *specific* temptation, and it is refused for the reason
/// decision A2 gives startup reconciliation its one-shot rule: after the helper's single
/// startup restore, a fan observed in manual is foreign or firmware control, never a
/// reclamation, and restoring it a second time is a fight rather than a repair. Wake is not
/// a second startup.
///
/// ## Neither event touches a supervisor
///
/// Decision A5, stated as a property rather than as a promise: this type is handed no
/// supervisor and has no property one could be assigned to, so "sleep does not stop § 3"
/// cannot be broken from here. That removes § 4's exposure to a stopped-and-restarted
/// supervisor entirely rather than resting it on the fixes for
/// [#131](https://github.com/blamechris/Aeolus/issues/131) and
/// [#144](https://github.com/blamechris/Aeolus/issues/144).
struct SystemPowerResponder<Plane: FanControlPlane>: Sendable {

    private let leases: LeaseAuthority

    /// § 4's own precedence level — `SafetyActorLevel.sleepWake`, ADR 0007's level 4 — so a
    /// restore issued here is attributable to a mechanism rather than being an anonymous call
    /// into the firmware. Through `SafetyActorWriter` and never the plane directly, so § 8's
    /// ramp governor cannot reach it: the writer holds no `RampGovernor` and has no property
    /// one could be assigned to.
    private let writer: SafetyActorWriter<Plane>

    private let clock: any MonotonicClock
    private let acknowledgementBudget: Duration
    private let log: SafetyLog

    init(
        leases: LeaseAuthority,
        writer: SafetyActorWriter<Plane>,
        clock: some MonotonicClock = SystemMonotonicClock(),
        acknowledgementBudget: Duration = SystemPowerLimits.acknowledgementBudget,
        log: SafetyLog = SafetyLog()
    ) {
        self.leases = leases
        self.writer = writer
        self.clock = clock
        self.acknowledgementBudget = acknowledgementBudget
        self.log = log
    }

    /// Reports that this process cannot hear the system's power events at all.
    ///
    /// § 4's own voice, so the composition root does not have to hold a `SafetyLog` to say one
    /// sentence about a mechanism it merely wires. Synchronous and writes nothing: the only
    /// caller is `HelperComposition.observeSystemPower()`'s `catch`.
    func couldNotObserve(_ error: any Error) {
        log.systemPowerObserverUnavailable(error)
    }

    /// Acts on one power event.
    func respond(to notification: SystemPowerNotification) async {
        switch notification.event {
        case .willSleep:
            await allowSleepAfterHandback(notification)
        case .didWake:
            log.wokeWithoutWriting()
        }
    }

    /// The sleep path: hand every fan back, then allow the power change — bounded.
    ///
    /// ## Why the budget runs on a task of its own
    ///
    /// The obvious shape is a task group racing the handback against a sleep, and it does not
    /// work: a task group waits for **every** child before it returns, so a handback wedged in
    /// a synchronous IOKit call would park this function long after the acknowledgement was
    /// due — which is the exact failure the budget exists to prevent, reintroduced by the
    /// structure chosen to prevent it. `BoundedFanRestorer` makes each attempt deliberately
    /// uncancellable, so `cancelAll()` cannot unwedge it either.
    ///
    /// So the budget is the thing that runs unstructured, and the acknowledgement is a
    /// separate object both paths reach. The handback is awaited normally: on a healthy
    /// machine it finishes in microseconds, the budget task is cancelled unfired, and the
    /// acknowledgement records `.handedBack`. On a wedged one the budget wins, the system is
    /// released at five seconds with a `.fault` line, and this frame stays parked on a write
    /// that is no longer anybody's blocker.
    private func allowSleepAfterHandback(_ notification: SystemPowerNotification) async {
        log.sleepIsComing(budget: acknowledgementBudget)

        let acknowledgement = SleepAcknowledgement(
            notification, budget: acknowledgementBudget, log: log)

        let budget = Task { [clock, acknowledgementBudget, acknowledgement] in
            try await clock.sleep(until: clock.now.advanced(by: acknowledgementBudget))
            await acknowledgement.acknowledge(.budgetExpired)
        }

        await handBackEveryFan()

        // Cancelled before the acknowledgement rather than after it, so the two paths cannot
        // both be live across this actor hop. The guard inside `SleepAcknowledgement` is what
        // makes the outcome correct either way; this is what makes it ordinary.
        budget.cancel()
        await acknowledgement.acknowledge(.handedBack)
    }

    /// Drops every lease and returns every fan to the system's thermal management.
    ///
    /// The keystone restore is issued whether or not the lease teardown handed anything back,
    /// and its failure is logged rather than propagated. There is nobody to propagate to: the
    /// caller's next act is to let the machine sleep, and it must do that whatever the
    /// firmware said. `.fault` is the level `SafetyLog` reserves for exactly this — *"a write
    /// on its path did not land"* — and on a build with no write path at all it is what a
    /// reader will see, truthfully, on every sleep.
    private func handBackEveryFan() async {
        await leases.releaseEveryLease()
        do {
            try await writer.restoreToAutomatic(.everyFan)
            log.handedEveryFanBackBeforeSleep()
        } catch {
            log.couldNotHandEveryFanBackBeforeSleep(error)
        }
    }
}
