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
    /// **What covers the fan when the budget wins, stated exactly, because the obvious
    /// answer is wrong.** This paragraph said "§ 1's TTL is the backstop" until a review
    /// showed it could not be: `handBackEveryFan()` calls `releaseEveryLease()` first, which
    /// empties the table *synchronously*, so by the time the budget can fire there is no
    /// lease left to expire and no TTL to expire it. The sentence named a mechanism the same
    /// function had already dismantled. Recorded in place rather than rewritten, because a
    /// justification nobody re-reads is how a safety claim outlives its subject.
    ///
    /// The real cover, in the order it can act:
    ///
    /// - **The parked restore may still land.** Nothing cancels it; § 4 stops *waiting*, and
    ///   `BoundedFanRestorer` keeps attempting inside a task that does not inherit
    ///   cancellation. On a machine that only sleeps slowly, the write arrives.
    /// - **Every fan still outstanding is recorded as an unconfirmed handback before the
    ///   acknowledgement** — `LeaseAuthority.recordUnconfirmedHandbacks()`, decision D33
    ///   (ADR 0007, amendment 2026-09-06, #209). A lease over such a fan is refused exactly
    ///   as hard as one over an abandoned handback while it stands, so nothing can be leased
    ///   on a machine that never confirmed the fan went back to automatic.
    ///
    ///   **It records that, and not the durable `.restoreToAutomaticFailed`, and the bullet
    ///   said the opposite until D33 — decision D17, corrected here rather than deleted.**
    ///   A budget expiring is evidence about *time*: nothing on this path observed a refused
    ///   write, and treating five seconds of silence as a firmware refusal removed a fan from
    ///   manual control for the life of the process on a machine whose only fault was
    ///   sleeping slowly. The unconfirmed state ends three ways — the outstanding restore
    ///   lands and clears it, the restore comes back refused after `RestoreLimits.attemptBudget`
    ///   and converts it to the durable set through `LeaseAuthority.restore(_:because:)`'s
    ///   existing union, or the restore never returns and it stands for the life of the
    ///   process.
    /// - **§ 3 acts above the ceiling.** Its registry entry is deliberately retained across
    ///   the handback, so a fan that crossed the sleep in manual and comes back hot is taken
    ///   to full scale by the thermal override. Above the ceiling only — it is not a restore.
    /// - **Startup reconciliation at the next helper start**
    ///   ([#164](https://github.com/blamechris/Aeolus/issues/164), landed in #199), which is
    ///   what returns such a fan to automatic. **This bullet said it "is not built yet" until
    ///   #104, and that was stale**: `HelperComposition.bringUp()` runs the pass before any
    ///   supervisor starts and it reads `F<n>Md` for every enumerated fan. What it cannot do
    ///   is land a write — the restore is refused with `.controlPathNotBuilt` — so on today's
    ///   build such a fan is refused durably rather than recovered, and `docs/RECOVERY.md` is
    ///   the user's route out until E3/E4 ship a write path.
    ///
    /// Acknowledging anyway is still the right answer, and the argument is unchanged by the
    /// correction: holding the sleep open buys nothing, because the kernel sleeps the machine
    /// on its own timeout and this process learns less by being cut off than by giving up
    /// deliberately and writing the fault line.
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
    private let leases: LeaseAuthority
    private let budget: Duration
    private let log: SafetyLog

    private var settledOutcome: Outcome?

    init(
        _ notification: SystemPowerNotification,
        leases: LeaseAuthority,
        budget: Duration,
        log: SafetyLog
    ) {
        self.notification = notification
        self.leases = leases
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
    ///
    /// **The unconfirmed handback is recorded before the acknowledgement too, and for a
    /// stronger reason than the log line's.** A fan whose handback has not landed when the
    /// budget fires is a fan in a mode nothing confirmed, and `handbackUnconfirmed` is the
    /// refusal that says so. Recording it after the acknowledgement would put the one piece
    /// of state that survives the sleep on the far side of the instant the machine stops
    /// running this process — the same argument, applied to something a reader cannot merely
    /// miss.
    ///
    /// **This paragraph said "the abandonment" and named decision D17 until D33** (ADR 0007,
    /// amendment 2026-09-06, #209). What is recorded is no longer the durable
    /// `.restoreToAutomaticFailed` — see `SystemPowerLimits.acknowledgementBudget` for the
    /// argument — and the *ordering* claim above is unchanged by that, which is why it is
    /// corrected in place rather than rewritten.
    ///
    /// It sits inside the once-only guard rather than in the budget task, so it happens on
    /// the path that actually answers the system and on no other: a budget that fires while
    /// the handback is completing must not record anything about a fan that went back.
    func acknowledge(_ outcome: Outcome) async {
        guard settledOutcome == nil else { return }
        settledOutcome = outcome

        switch outcome {
        case .handedBack:
            log.allowingSleepAfterHandback()
        case .budgetExpired:
            let unconfirmed = await leases.recordUnconfirmedHandbacks()
            log.allowingSleepWithHandbackUnconfirmed(after: budget, leaving: unconfirmed)
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
/// **The lease teardown is first, and that ordering is the one a test pins.** On a wedged
/// connection the keystone never returns, so a version that issued it first would sleep the
/// machine with every lease still live and every fan still in manual — and on a healthy one
/// it would clear `F<n>Md` underneath § 5, whose next cycle reads a mode key it did not
/// expect as a reclamation and re-asserts on the way into sleep.
/// `UnconfirmedHandbackTests.aWedgedHandbackDropsTheLeaseFirstAndLeavesTheFanUnconfirmed`
/// asserts `leaseCount == 0` from **inside** the acknowledgement, so a keystone that never
/// returns cannot precede the teardown. (This named a test that did not exist under the
/// spelling given, until #209 replaced it and fixed the reference; a doc pointing at nothing
/// is how an ordering claim stops having a guard.)
///
/// ## Acquisition is sealed for the duration
///
/// `LeaseAuthority.sealForSleep()` runs before the teardown and `unsealAfterWake()` on
/// `.didWake`. Without it the two halves above leave a door open that everything else here
/// closes: a request already parked on `refuseIfBlind`'s 34-key read resumes after the table
/// is emptied, sees no lease and no fan mid-handback, and engages manual control as the
/// machine stops running this process. Clearing the seal on wake writes nothing.
///
/// ## What the lease lines say in `log show`
///
/// § 4's teardown goes through `releaseEveryLease()`, so each fan is logged with
/// `FanRestoreCause.allLeasesDropped` — the same attribution § 7's panic verb uses, because
/// it is the same verb. What tells them apart is this section's own `SafetyLog` line
/// (*"System will sleep: dropping every lease…"*) immediately above them. A dedicated
/// `FanRestoreCause` case would make the `LeaseLog` line self-describing and is deliberately
/// not added here: it would be a second name for one mechanism, which is the thing
/// `revokeEveryLease(because:)`'s own doc argues against.
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

    /// Reports that this graph was composed with no seam to hear the system through.
    ///
    /// The third of the three states `HelperComposition.observeSystemPower()`'s doc claims are
    /// distinguishable, and the one that had no line: a `nil` observer returned silently, so a
    /// helper built without § 4 read exactly like one whose registration succeeded. It is the
    /// same consequence as `couldNotObserve(_:)` — nothing hands the fans back before a sleep
    /// — reached by a different route, so it is the same level with a different sentence.
    func wasGivenNothingToObserve() {
        log.noSystemPowerObserver()
    }

    /// Acts on one power event.
    func respond(to notification: SystemPowerNotification) async {
        switch notification.event {
        case .willSleep:
            await allowSleepAfterHandback(notification)
        case .didWake:
            // Clearing the seal is not a write and does not make this branch one. It touches
            // no fan, issues no read, and reaches no plane — it reopens acquisition, which is
            // the only thing about a wake this helper acts on. See `LeaseAuthority.sleepSeal`.
            await leases.unsealAfterWake()
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

        // Before anything is torn down, so there is no instant at which the table is empty
        // and still open. A request parked on `refuseIfBlind`'s 34-key read that resumes into
        // the window would otherwise find an empty table, take a lease, and engage manual
        // control on a machine that is about to stop running this process.
        await leases.sealForSleep()

        let acknowledgement = SleepAcknowledgement(
            notification, leases: leases, budget: acknowledgementBudget, log: log)

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
