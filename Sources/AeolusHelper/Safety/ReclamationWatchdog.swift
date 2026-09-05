import FanKit

/// `docs/SAFETY.md` § 5, and the precedence engine's second consumer — the one that makes
/// `SafetyArbiter` load-bearing.
///
/// ## What it watches, and why not the obvious thing
///
/// **The primary signal is the target Aeolus wrote against the target the SMC reads back.**
/// Not actual-versus-target. `F<n>Ac` legitimately slews toward `F<n>Tg` rather than
/// stepping, so an actual-versus-target primary would read every ramp as a reclamation —
/// including the full-scale ramp § 3 performs during a thermal emergency, which is the one
/// moment this mechanism must not fire. A watchdog that reads another safety mechanism's
/// work as an attack on it is worse than no watchdog, and #119 is where that ruling was
/// made.
///
/// `CommandedTarget` is the number the comparison is made against: the step actually put on
/// the wire, deliberately distinct from the goal a caller was heading for.
///
/// Actual-versus-target survives as the **secondary** signal, behind
/// `ReclamationLimits.actualDwellCycles` — and it **reports without acting**. Reaching it at
/// all means the primary converged, so the firmware is holding Aeolus's target and nothing
/// has been reclaimed; see `reportShortfall(_:fanAt:)` for why re-asserting, restoring and
/// flagging `isReclaimedBySystem` are all wrong answers to a fan that simply cannot reach
/// its commanded speed. It used to reach the terminal action, and that was this file's worst
/// defect: a fan whose `F<n>Tg` read back exactly right lost its lease eight seconds after
/// being asked for a speed it could not achieve.
///
/// ## The above-ceiling rule is the arbiter, not an `if`
///
/// § 5 never fights the system for the fans while any temperature is above ceiling.
/// Reclamation mid-emergency means a more competent authority — one that can also throttle
/// the SoC, which Aeolus never can — reached the same destination first.
///
/// That rule is enforced by asking `SafetyArbiter.ruling(for:incumbent:)` whether level 3
/// may write while level 2 holds the fans, and the answer is no because ADR 0007 orders
/// them that way. It is deliberately **not** a second `if temperature > ceiling` here: a
/// bespoke comparison would be a second copy of § 3's own ceiling arithmetic, in the file
/// least able to keep it in step, and `ThermalEmergency` already documents that a margin
/// subtracted in two places is a margin that can disagree with itself.
///
/// `ThermalEmergency`'s own doc names this moment: the arbiter *"still has no production
/// caller"* with one actor implemented, and *"that half becomes load-bearing when the
/// reclamation watchdog (#126) and sleep/wake (#103) arrive to contend with it"*. This is
/// that arrival. Replacing `SafetyArbiter.ruling`'s body with `return .commands` now fails
/// `ReclamationWatchdogTests.itNeverReassertsWhileTheThermalLatchHolds` as well as the
/// arbiter's own tests — and, because the ruling is consulted twice per re-assert, also
/// `itUndoesAReassertWhenTheEmergencyLatchesMidWrite`.
///
/// **What the latch buys, stated exactly.** The incumbent is read from
/// `ThermalEmergencyLatch`, which is engaged from the cycle § 3 fires on until a fresh
/// reading falls a hysteresis margin below the ceiling — so this refuses to re-assert
/// through the whole band down to `ceiling − 5 °C`, which is *longer* than "above ceiling"
/// strictly requires. Over-refusing is the safe direction: the fan is on Apple's thermal
/// management throughout.
///
/// The gap in the other direction is one cycle. A temperature crossing the ceiling is not
/// visible here until § 3's next cycle engages the latch, so a re-assert can be issued into
/// the first second of an emergency. Making this read a temperature of its own to close that
/// window would add a supervisor-priority read per cycle — see
/// [#134](https://github.com/blamechris/Aeolus/issues/134) — for a window § 3 closes within
/// one cycle by latching, after which this mechanism refuses.
///
/// **What does not close it is § 3 correcting the re-assert, and an earlier version of this
/// paragraph claimed exactly that.** It said § 3's next cycle "bridges the fan to maximum and
/// restores it, which overrides the re-assert rather than racing it". That is false, and
/// checkably so: `ThermalEmergency.fire(_:from:)` empties `engagedFans` as it goes, and
/// `ThermalEmergency.manualControlEngaged(_:)` has **no caller anywhere in `Sources/`** — so
/// a fan this mechanism re-engaged is in no registry § 3 consults, and § 3's next cycle
/// would leave it off automatic control indefinitely. Relying on another mechanism to clean
/// up after this one was the wrong shape regardless; the correction belongs here, and
/// `reassert(_:fanAt:attempt:)` performs it by re-checking the ruling **after** its writes
/// and restoring if the latch engaged underneath them.
///
/// ## Reads are strictly sequential, and that is #134's answer for this issue
///
/// One fan is examined at a time, `await`ed to completion before the next begins.
/// `SMCReadScheduler` is FIFO within `.supervisor`, and the starvation quota forces a
/// snapshot turn after every `maxConsecutiveOvertakes`, so *N* concurrently outstanding
/// supervisor reads delay § 3's cycle by *N* supervisor turns **plus** roughly `N/2`
/// quota-forced snapshot turns — and a snapshot turn is 64 keys where a control-state read
/// is three. The forced turns, not the watchdog's own reads, are what would hurt.
///
/// Sequential examination means this actor contributes **at most one** supervisor waiter at
/// any instant however many fans the machine has, so § 3's cycle queues behind at most one
/// other supervisor read and `SMCReadScheduler`'s "at most two turns" bound very nearly
/// holds. The cost is borne here — a full sweep takes N times one read's latency — and this
/// mechanism runs at 1 Hz against N of 1 or 2 on real hardware, so there is nothing to buy
/// by parallelising it.
///
/// #134's remaining questions are untouched by this: whether § 3's cycle should outrank
/// other supervisor reads at all, whether grant-time `refuseIfBlind` reads should be
/// coalesced, and whether a third priority level is warranted. This issue only declines to
/// make them worse.
///
/// ## The failure asymmetry, again
///
/// Over-firing hands fans back to Apple's thermal management — safe, and visible to the
/// user. Under-firing leaves a fan pinned at a speed nothing is honouring while the UI says
/// otherwise, which is `CLAUDE.md` rule 6. Every uncertain branch below resolves that way:
/// an unreadable target read-back is divergence rather than "no divergence"; a re-assert
/// that cannot obtain an envelope restores rather than commanding; persistent read failure
/// is divergence rather than a read to be retried forever.
///
/// ## Not started, like § 3
///
/// `ReclamationSupervisor` is the loop, and nothing constructs one. No lease can be granted
/// in this build, so no fan is ever off automatic control and there is nothing to watch.
/// [#103](https://github.com/blamechris/Aeolus/issues/103) owns the lifecycle that starts
/// both supervisors, and E3 owns telling this actor what it commanded.
///
/// - Note: this file is over SwiftLint's 400-line warning, as `ThermalEmergency.swift` and
///   `LeaseAuthority.swift` already are, and it crossed the 1000-line **error** threshold
///   once #169/#170/#172 landed alongside the registration grace. Both splits available
///   without widening state have now been taken: `ReclamationDivergence` and
///   `ReclamationLimits` are values rather than mechanism and live in
///   `ReclamationLimits.swift`, and `primaryDivergence(of:against:)` and
///   `actualShortfall(of:against:)` are `static` and pure and live in
///   `ReclamationSignals.swift`. What is left is the actor and its private state: every
///   remaining member either reads or writes `held`, or is `held`, so moving any of it into
///   an extension in another file would mean widening that state to the whole module. That
///   state is exactly what makes `examine(fanAt:ruling:)`'s read-then-mutate reasoning
///   checkable, and [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest of
///   this space — including what to do when the next paragraph pushes this over again.
actor ReclamationWatchdog<Plane: FanControlPlane> {

    /// The read half of the seam. **Not a `FanControlPlane`**, so this actor cannot
    /// command a fan except through `writer` — see `FanStateSensing` for why that is a
    /// compile-time property rather than a rule.
    private let sensing: any FanStateSensing

    /// Level 3's ungoverned writer. § 8 cannot reach it: `SafetyActorWriter` holds no
    /// `RampGovernor` and has no property one could be assigned to.
    private let writer: SafetyActorWriter<Plane>

    private let leases: LeaseAuthority

    /// § 3's bit, read once per cycle to decide the incumbent. Never written here: this
    /// mechanism does not engage or release a thermal emergency, and `ThermalEmergency`
    /// remains the only thing in `Sources/` that clears the latch at all — through
    /// `cycle()`'s `release(ifStill:)`, the no-argument `release()` having no caller here.
    private let latch: ThermalEmergencyLatch

    /// What the user is told, via `FanState.isReclaimedBySystem`.
    private let ledger: ReclamationLedger

    private let log: SafetyLog

    /// Every fan currently off Apple's thermal management, with what this mechanism knows
    /// about it.
    ///
    /// Keyed by index so a second registration finds the entry that is already there rather
    /// than duplicating it — and `manualControlEngaged(_:)` then leaves that entry alone,
    /// which is what stops a re-registration rearming a budget. Empty is the ordinary state,
    /// and a cycle over an empty registry does nothing at all — there is no fan pinned, so
    /// there is nothing that could be taken back.
    private var held: [Int: HeldFan] = [:]

    /// `sensing` is an existential rather than `some FanStateSensing`, unlike
    /// `ThermalEmergency`'s `telemetry`. It is stored as one either way, and taking it as an
    /// existential lets a caller choose the seam at run time — which the test target does,
    /// substituting a double for the read failures `ScriptedControlPlane`'s stages cannot
    /// express. There is no generic specialisation to lose: every call on it is a protocol
    /// witness through the stored `any` regardless of how it arrived.
    init(
        sensing: any FanStateSensing,
        writer: SafetyActorWriter<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        ledger: ReclamationLedger,
        log: SafetyLog = SafetyLog()
    ) {
        self.sensing = sensing
        self.writer = writer
        self.leases = leases
        self.latch = latch
        self.ledger = ledger
        self.log = log
    }

    // MARK: - What is under manual control

    /// Registers a fan that has just been taken off automatic control.
    ///
    /// Called by whoever performs `FanControlPlane.engageManualControl(of:)` — E3's control
    /// plane, once it exists — at the same point it calls
    /// `ThermalEmergency.manualControlEngaged(_:)`.
    ///
    /// ## The ordering is normative: call this **after** the `F<n>Md` write has landed
    ///
    /// "At the same point" says nothing about which side, and only one of the two sides
    /// works. E3 will be written against this comment, so the constraint is stated here
    /// rather than discovered later.
    ///
    /// Registering *before* the mode write is not a harmless reordering. This mechanism runs
    /// on its own 1 Hz loop, so a `cycle()` can land in the window between the registration
    /// and the write. What it reads there is `mode == .automatic` on a fan with nothing
    /// commanded, which is `.modeReclaimed` — the strongest primary signal there is — and
    /// it reaches `diverged(_:fanAt:)`'s "nothing to re-assert" branch and
    /// `finaliseRelease(fanAt:because:)` with `.systemReclaimed`: the fan restored, **every
    /// lease on the machine revoked**, and a `.fault` line blaming the operating system —
    /// milliseconds after a client was granted control it never got to use.
    /// `ReclamationWatchdogRecoveryTests.aFanWithNoCommandedTargetIsRestored` and
    /// `fallingBackClearsTheWholeRegistry` are that path, arrived at on purpose.
    ///
    /// ## The far side of the write is not free either, and the grace is what pays for it
    ///
    /// An earlier version of this comment said the window after the mode write was safe, and
    /// that a grace flag on `HeldFan` was therefore unnecessary. That was true of the
    /// `.targetDiverged` case and of nothing else: both `.modeReclaimed` and
    /// `.targetUnreadable` are decided *before* `primaryDivergence(of:against:)` consults
    /// `commanded` at all, so a cycle landing in the `F<n>Md` write-to-read-back lag, or on
    /// one unreadable `F<n>Tg`, reached the same whole-machine revocation from the ordering
    /// this comment mandates. A write returning successfully and a read reflecting it are
    /// different facts, and the lag between them is unmeasured on Apple Silicon.
    ///
    /// `gracedBeforeItsFirstCommand(_:of:fanAt:)` closes that window — #147's second remedy,
    /// implemented rather than declined — by giving a fan with nothing commanded on it
    /// `ReclamationLimits.blindCyclesBeforeDivergence` cycles before the primary signal
    /// reaches the terminal action. So the ordering above is what this method requires, and
    /// the grace is what makes obeying it survivable rather than merely correct on paper.
    /// The two sides are not symmetrical after it: registering early still costs the client
    /// its lease, three cycles later instead of one.
    ///
    /// `ReclamationRegistrationWindowTests` is the whole window, one test per answer
    /// `primaryDivergence(of:against:)` can give inside it, so this comment claims no more
    /// than the suite shows.
    ///
    /// ## The parameter stays a `CommandableFan`
    ///
    /// Only `fan.index` is read, and with `HeldFan.permit` gone there is nothing else it is
    /// stored into — so tidying this to `manualControlEngaged(fanAt index: Int)` looks free.
    /// It is not: a `CommandableFan` can only be minted from a `FanEnvelope` that passed its
    /// bounds gate, so the type is what makes registration lawful only from a caller that
    /// was actually authorised to write to the fan. Widening it would let anything put a fan
    /// into a registry whose entries this mechanism will later re-engage manual control on.
    /// `ThermalEmergency.manualControlEngaged(_:)` takes the same parameter for the same
    /// reason.
    ///
    /// ## Re-registering a fan already held changes nothing about it
    ///
    /// The entry is created only when there is not one already, so calling this twice
    /// without an intervening `manualControlReleased(fanAt:)` is idempotent: the fan keeps
    /// its `commanded` target, its grace counter, its re-assert attempts and its blind-cycle
    /// count. It used to build a fresh `HeldFan` unconditionally, and that was two defects
    /// rather than one:
    ///
    /// - **The grace was rearmed.** `uncommandedDivergentCycles` went back to zero, so a
    ///   caller re-registering a fan every other cycle held it off automatic control
    ///   indefinitely and the terminal action was never reached — twenty registrations bought
    ///   forty divergent cycles, no restore, and a lease still live. That is the budget
    ///   `gracedBeforeItsFirstCommand(_:of:fanAt:)` exists to bound, refillable on demand by
    ///   the very caller it is meant to bound.
    /// - **`commanded` was wiped.** `primaryDivergence(of:against:)` reaches
    ///   `.targetDiverged` only behind `guard let commanded`, so a re-registered fan Aeolus
    ///   *had* commanded became unjudgeable on that case until the next `commandedTarget(_:)`
    ///   — a fan pinned at a number this mechanism had just forgotten it wrote, which is
    ///   `CLAUDE.md` rule 6.
    ///
    /// The refill point is a genuine release, and both of them drop the entry:
    /// `manualControlReleased(fanAt:)` for a lease that ended, `finaliseRelease(fanAt:because:)`
    /// for a fan this mechanism gave up. A registration after either of those starts fresh,
    /// which is the case a fresh `HeldFan` is actually for.
    ///
    /// `ReclamationRegistrationWindowTests.reRegisteringMidGraceDoesNotRefillIt` and
    /// `.reRegisteringKeepsWhatWasCommanded` are the two halves.
    ///
    /// Clears any reclamation recorded against this fan: something has just taken it off
    /// automatic control, so the ledger's claim that the system holds it is now false, and
    /// a stale `true` there would report a fan as lost that a client is about to command.
    /// That half is unconditional, because it is a statement about the world rather than
    /// about this registry.
    func manualControlEngaged(_ fan: CommandableFan) async {
        if held[fan.index] == nil { held[fan.index] = HeldFan() }
        if await ledger.clearReclaimed(fanAt: fan.index) {
            log.reclamationResolved(fan: fan.index)
        }
    }

    /// Records what was actually put on the wire for a fan.
    ///
    /// **The primary signal is built from this and nothing else.** A caller mid-ramp holds
    /// two numbers — the goal and this cycle's step — and comparing a read-back against the
    /// goal is the defect § 5 was rewritten to avoid. `SafetyActorWriter.command(_:of:)`
    /// and `GovernedFanWriter.command(towards:of:since:)` both return one of these
    /// precisely so their caller can hand it here.
    ///
    /// A target commanded for a fan this actor is not watching is ignored rather than
    /// registered: a `CommandedTarget` is an observation, and it is not evidence that
    /// anybody took the fan off automatic control.
    func commandedTarget(_ commanded: CommandedTarget) {
        guard held[commanded.fanIndex] != nil else { return }
        held[commanded.fanIndex]?.commanded = commanded
        // A fresh command resets the secondary dwell: the fan is being asked for something
        // new, and cycles spent short of the *previous* target say nothing about this one.
        held[commanded.fanIndex]?.actualDwellCycles = 0
    }

    /// Forgets a fan that has gone back to Apple's thermal management on purpose.
    ///
    /// The deliberate counterpart to a reclamation: a lease released, expired, or torn
    /// down. The ledger is cleared too, because a fan Aeolus stopped asking for is not a
    /// fan the system took.
    func manualControlReleased(fanAt index: Int) async {
        held[index] = nil
        if await ledger.clearReclaimed(fanAt: index) {
            log.reclamationResolved(fan: index)
        }
    }

    /// The fans this instance is watching, for tests and diagnostics.
    var fansUnderManualControl: Set<Int> { Set(held.keys) }

    /// What this instance last recorded as commanded for a fan, for tests and diagnostics.
    func lastCommanded(ofFan index: Int) -> CommandedTarget? { held[index]?.commanded }

    // MARK: - One cycle

    /// Whether a sweep is in flight. See `cycle()`'s "one sweep at a time".
    private var isSweeping = false

    /// Examines every held fan once and acts on what it finds.
    ///
    /// Never throws, for `ThermalEmergency.cycle()`'s reason: the driver is a loop in a
    /// root daemon, and an error escaping here would either kill the loop or be swallowed
    /// at the call site. Every failure below becomes a decision plus a log line.
    ///
    /// ## Nothing is carried across a suspension point
    ///
    /// This actor is reentrant, and every `await` below — a read, a write, a ledger or latch
    /// hop — is a point at which `manualControlEngaged(_:)`, `commandedTarget(_:)`,
    /// `manualControlReleased(fanAt:)` or a second `cycle()` can run. An adversarial review
    /// found four distinct defects of one shape here: a value read before an `await` and
    /// acted on after it. So the rule in this file is now uniform and stated once:
    ///
    /// > **Re-fetch `held[index]` after every `await`, and treat its absence as an
    /// > instruction to stop rather than as a no-op.**
    ///
    /// Optional chaining (`held[index]?.x = y`) is *not* that rule. It makes a mutation
    /// vanish silently while the code around it goes on acting as though the fan were still
    /// registered, which is exactly how `reassert(_:fanAt:attempt:)` came to write `F<n>Md`
    /// to a fan whose lease had just been released.
    ///
    /// ## One sweep at a time, by construction
    ///
    /// The sequential examination below is a property of *one* invocation, and until
    /// [#144](https://github.com/blamechris/Aeolus/issues/144) nothing made it a property of
    /// the mechanism. `ReclamationSupervisor.stop()` cancels without awaiting, so a
    /// stop-then-start — what a sleep/wake cycle does — starts a second loop whose first act
    /// is a `cycle()` while the outgoing one is still suspended inside a read. Two sweeps of
    /// the same fan then spend one re-assert budget twice and count one dwell twice, and a
    /// dwell that elapses in half the cycles it should is how the secondary signal starts
    /// reading a ramp as a reclamation.
    ///
    /// A second entrant therefore returns having done nothing, rather than waiting its
    /// turn — dropped to serialise the mechanism, not because its readings are stale. The
    /// sweep in flight is acting on a control state it has already read; the entrant has
    /// read nothing yet, so an entrant that queued would read *after* the incumbent finished
    /// and would hold the fresher view of the fan. What makes dropping it right is that it
    /// has nothing to add: this loop runs at a fixed cadence, an entrant exists only because
    /// a stop-then-start overlapped two loops, and queueing would run two sweeps back to
    /// back inside one interval — spending two supervisor-priority turns on the single SMC
    /// connection where the cadence budgets one.
    ///
    /// Nothing is carried past the return: every sweep re-reads each fan below, and the
    /// per-fan state that made the overlap consequential — the budget, the dwell — is what
    /// the next scheduled sweep will read fresh anyway.
    func cycle() async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        guard !held.isEmpty else { return }

        // Sorted and sequential. Sorted so a scenario's log and attempt order are
        // deterministic; sequential because this actor must contribute at most one
        // supervisor-priority waiter at a time — see this type's documentation.
        //
        // The index list is a snapshot, and deliberately so: `finaliseRelease` can empty the
        // whole registry part-way through a sweep, and the remaining iterations then find
        // nothing and stop. That is correct rather than merely tolerable — those fans were
        // released by the revocation this sweep performed.
        for index in held.keys.sorted() {
            await examine(fanAt: index)
        }
    }

    /// § 3's bit and the arbiter's answer, read **immediately before the write it guards**.
    ///
    /// ## Why this is not read once per sweep any more
    ///
    /// It was, and that was a defect. The ruling was computed at the top of `cycle()` and
    /// then carried by value through `examine` → `diverged` → `reassert`, where it
    /// authorised two writes three suspension points and — at `SMCFanControlPlane`'s own
    /// figures for two scheduled `.supervisor` turns — some tens of milliseconds later. § 3
    /// runs on an independent 1 Hz detached loop and can latch anywhere inside that window,
    /// so the writes were gated by an answer that was no longer true. `ThermalEmergency`
    /// states the rule this broke: *a check separated from the act it guards is not a
    /// check.*
    ///
    /// ## What it still cannot do, stated rather than papered over
    ///
    /// It cannot make check-and-act atomic. The latch is one actor and the plane is another,
    /// so there is always a hop between the answer and the write, and no arrangement of
    /// this code removes it. What this does is shrink the window from "a whole sweep" to
    /// "one actor hop", and `reassert(_:fanAt:attempt:)` then **verifies again after
    /// writing** and undoes in the safe direction if § 3 latched inside even that. Acting
    /// and then checking is the only sound pattern available when the check cannot be made
    /// atomic with the act; claiming the window is closed would be the more dangerous
    /// spelling.
    private func currentRuling() async -> SafetyRuling {
        let incumbent: SafetyActorLevel? = await latch.isActive ? .thermalEmergency : nil
        return SafetyArbiter.ruling(for: .reclamationWatchdog, incumbent: incumbent)
    }

    /// One fan: read it, decide, act.
    private func examine(fanAt index: Int) async {
        guard held[index] != nil else { return }

        let state: FanControlState
        do {
            state = try await sensing.readControlState(ofFan: index)
        } catch {
            await cycleCouldNotSee(fanAt: index, detail: String(describing: error))
            return
        }

        // Re-fetched after the read, never carried across it. `manualControlReleased(fanAt:)`
        // runs on whatever task the lease core is on and can clear this entry while the read
        // is in flight; judging the fan from the pre-read copy reported an ordinary lease
        // expiry as the system reclaiming a fan, and revoked whatever lease was live at that
        // instant.
        guard let fan = held[index] else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "its control-state read")
            return
        }

        if fan.consecutiveReadFailures > 0 {
            log.reclamationTelemetryRecovered(
                fan: index, afterCycles: fan.consecutiveReadFailures)
            held[index]?.consecutiveReadFailures = 0
        }

        // Primary first, and it is the only signal that reaches the terminal action.
        if let primary = Self.primaryDivergence(of: state, against: fan.commanded) {
            held[index]?.actualDwellCycles = 0
            guard !gracedBeforeItsFirstCommand(primary, of: fan, fanAt: index) else { return }
            await diverged(primary, fanAt: index)
            return
        }

        // Secondary: the fan is not turning as fast as it was told to, sustained. It
        // **reports and stops** — see `reportShortfall(_:fanAt:)`.
        if let shortfall = Self.actualShortfall(of: state, against: fan.commanded) {
            reportShortfall(shortfall, fanAt: index)
            return
        }

        // Converged on both signals. `uncommandedDivergentCycles` is deliberately **not**
        // reset alongside these two — see `HeldFan.uncommandedDivergentCycles`. A fan whose
        // `F<n>Tg` is merely flaky rather than gone would otherwise refill the registration
        // grace on every readable cycle and stay off automatic control for as long as the
        // flapping lasted, which is
        // `ReclamationRegistrationWindowTests.aConvergedCycleDoesNotRefillTheGrace`.
        held[index]?.actualDwellCycles = 0
        held[index]?.reassertAttempts = 0
        if await ledger.clearReclaimed(fanAt: index) {
            log.reclamationResolved(fan: index)
        }
    }

    // MARK: - The registration grace

    /// Whether this divergence is still inside the window that follows registration, and so
    /// must not reach the terminal action yet.
    ///
    /// ## The window this closes
    ///
    /// `manualControlEngaged(_:)` mandates registration **after** the `F<n>Md` write lands,
    /// and an earlier version of that comment claimed the far side of the write was
    /// therefore safe without any grace. It is not, and the claim covered exactly one of the
    /// three ways `primaryDivergence(of:against:)` can answer for a fan on which nothing has
    /// been commanded yet:
    ///
    /// - `.targetDiverged` — unreachable, because that case is behind
    ///   `guard let commanded else { return nil }`. This is the only case the old claim
    ///   analysed, and it is the one that never needed a grace.
    /// - `.modeReclaimed` — reached **before** `commanded` is consulted at all. A write that
    ///   has returned successfully is not the same fact as a read that reflects it, and the
    ///   `F<n>Md` write-to-read-back latency on Apple Silicon is unmeasured — `docs/SMC-
    ///   RESEARCH.md`'s observed section is empty on this point. One cycle landing inside
    ///   that lag reads automatic.
    /// - `.targetUnreadable` — reached before `commanded` as well. A single unreadable
    ///   `F<n>Tg` on a fan nothing has been commanded on took the terminal action on the
    ///   spot, with none of the tolerance `cycleCouldNotSee(fanAt:detail:)` gives a fan that
    ///   could not be read at all.
    ///
    /// Both of the latter two ended at `diverged(_:fanAt:)`'s "nothing to re-assert" branch:
    /// the fan restored, **every lease on the machine revoked**, and a `.fault` line blaming
    /// the operating system — milliseconds after a client was granted control it never got
    /// to use. That is the defect [#147](https://github.com/blamechris/Aeolus/issues/147)
    /// names, arrived at from the ordering it mandates rather than from the one it forbids.
    ///
    /// ## Why the failure asymmetry inverts here, and only here
    ///
    /// This file's rule is that over-firing is the safe direction: handing a fan back to
    /// Apple's thermal management costs cooling nobody chose, while under-firing leaves a
    /// fan pinned at a speed nothing honours, which is `CLAUDE.md` rule 6. **On a fan with
    /// no commanded target there is no such speed.** Nothing Aeolus picked is on the wire,
    /// so the pinned-fan hazard the asymmetry is built around does not exist, and what
    /// over-firing costs instead is the whole-machine revocation above — losing control that
    /// is in fact still held, which is rule 6 in the direction people forget.
    /// `reportShortfall(_:fanAt:)` declines the terminal action on the same grounds.
    ///
    /// So the tolerance is granted **only while `commanded` is `nil`**. The first
    /// `commandedTarget(_:)` ends it for the rest of that registration, and a commanded fan
    /// is judged exactly as strictly as before — including on the very next cycle.
    ///
    /// ## Bounded by `blindCyclesBeforeDivergence`, and not by a fourth constant
    ///
    /// The same number, because it is the same question: how many 1 Hz cycles may pass
    /// without this mechanism being able to confirm a fan is ours before that becomes
    /// divergence. Three cycles is three seconds — long against any plausible firmware
    /// read-back lag and short against anything a user would notice — and a genuine
    /// reclamation of an uncommanded fan is still restored and reported, just on the third
    /// cycle rather than the first. `ReclamationLimitsTests` already holds that constant
    /// under a literal ceiling, so this window cannot be widened into minutes either.
    ///
    /// Synchronous, so there is no suspension point between reading the counter and writing
    /// it back and no re-fetch is owed — `reportShortfall(_:fanAt:)`'s reason.
    ///
    /// - Returns: `true` when the caller must stop, leaving the fan held and untouched.
    private func gracedBeforeItsFirstCommand(
        _ divergence: ReclamationDivergence, of fan: HeldFan, fanAt index: Int
    ) -> Bool {
        guard fan.commanded == nil else { return false }

        let cycles = fan.uncommandedDivergentCycles + 1
        held[index]?.uncommandedDivergentCycles = cycles
        guard cycles < ReclamationLimits.blindCyclesBeforeDivergence else { return false }

        // Log the transition, not the state — #124's forward constraint, and
        // `cycleCouldNotSee(fanAt:detail:)`'s rule for the same reason.
        if cycles == 1 {
            log.reclamationAwaitingItsFirstCommand(fan: index, divergence: divergence)
        }
        return true
    }

    // MARK: - The secondary signal reports, and does nothing else

    /// The fan has been short of its commanded speed for the whole dwell. Say so, and stop.
    ///
    /// ## Why this no longer reaches the terminal action
    ///
    /// It used to, and that was the most consequential defect in this file. The secondary
    /// signal is only ever *evaluated* when the primary has converged — `examine` returns
    /// early on primary divergence — so reaching this function means `F<n>Md` reads manual
    /// and `F<n>Tg` reads back exactly what Aeolus commanded. **The firmware is holding our
    /// target.** Nothing has been reclaimed.
    ///
    /// A fan that is not reaching a target the firmware is faithfully holding is a fan that
    /// *cannot* reach it: an obstruction, a failing bearing, a declared `F<n>Mx` the part
    /// cannot actually achieve. The three things the mechanism could do about that are all
    /// wrong. Re-asserting rewrites the number that is already correct. Restoring to
    /// automatic makes it worse — Apple's thermal management will spin the same fan against
    /// the same obstruction. And marking `isReclaimedBySystem` tells the user the system
    /// took a fan it did not take, which is `CLAUDE.md` rule 6 in the direction people
    /// forget: claiming to have *lost* control that is in fact still held.
    ///
    /// So it reports. The user is told, which is what `docs/SAFETY.md` § 5 asks for — *"and
    /// either way tells the user"* — and the fan stays under the control it is genuinely
    /// still under.
    ///
    /// ## `==` and not `>=`
    ///
    /// One line per episode. `>=` would emit at the supervisor's 1 Hz for as long as the
    /// shortfall lasted, which is #124's forward constraint exactly: *an unchanged degraded
    /// set logged every tick at 1 Hz is not a log, it is a denial of service against the
    /// reader.* The dwell counter goes on rising and the next transition through
    /// convergence, or a fresh `commandedTarget(_:)`, resets it — so a fan that recovers and
    /// falls short again produces a second line rather than silence.
    ///
    /// Synchronous on purpose: it touches no other actor, so there is no suspension point
    /// between reading the dwell and writing it back, and no re-fetch is needed.
    private func reportShortfall(
        _ shortfall: (actual: Double, commanded: Double), fanAt index: Int
    ) {
        let dwell = (held[index]?.actualDwellCycles ?? 0) + 1
        held[index]?.actualDwellCycles = dwell
        guard dwell == ReclamationLimits.actualDwellCycles else { return }
        log.reclamationFanNotReachingTarget(
            fan: index,
            actual: shortfall.actual,
            commanded: shortfall.commanded,
            dwellCycles: dwell)
    }

    // MARK: - Acting on divergence

    /// The primary signal fired for this fan. Re-assert, or fall back and report.
    private func diverged(
        _ divergence: ReclamationDivergence, fanAt index: Int
    ) async {
        // **The above-ceiling rule, asked here rather than once per sweep.** Deleting this
        // guard is the mutation `ReclamationWatchdogTests.itNeverReassertsWhileTheThermalLatchHolds`
        // exists to kill: without it, § 5 re-asserts a user's target into a machine § 3 has
        // just handed to Apple's thermal management.
        guard await currentRuling().permitsWrite else {
            // **Attributed to § 3, not to the system.** § 3's `fire(_:from:)` bridges every
            // held fan to maximum and restores it to automatic, so a latched machine is
            // precisely where this mechanism should expect to read `.modeReclaimed` — and
            // reading it is evidence of Aeolus's own thermal override working, not of the OS
            // taking a fan. Marking the ledger here produced a `.fault` line claiming the
            // system had reclaimed a fan § 3 had just deliberately released, and a
            // `isReclaimedBySystem` that stayed true for the rest of the process.
            log.reclamationYieldedToThermalEmergency(fan: index, divergence: divergence)
            await releaseToThermalEmergency(fanAt: index)
            return
        }

        // Re-fetched across the latch hop above.
        guard let fan = held[index] else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "the precedence check")
            return
        }

        if await ledger.markReclaimed(fanAt: index) {
            log.reclamationDetected(
                fan: index, divergence: divergence, commanded: fan.commanded)
        }

        // Re-fetched across the ledger hop above.
        guard held[index] != nil else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "the reclamation report")
            return
        }

        guard let commanded = fan.commanded else {
            // Nothing was ever commanded here, so there is no target to re-assert to. The
            // fan came off automatic control and the system took it back before a speed
            // followed; restoring is both the honest answer and the only available one.
            log.reclamationHadNothingToReassert(fan: index)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        guard fan.reassertAttempts < ReclamationLimits.reassertAttemptBudget else {
            log.reclamationBudgetExhausted(
                fan: index, attempts: fan.reassertAttempts, divergence: divergence)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        let attempt = fan.reassertAttempts + 1
        held[index]?.reassertAttempts = attempt
        await reassert(commanded, fanAt: index, attempt: attempt)
    }

    /// One bounded attempt to take the fan back, below the ceiling.
    ///
    /// ## It reads a fresh envelope, and that is deliberate
    ///
    /// Not the permit taken when the fan came off automatic control — and `HeldFan` keeps no
    /// permit at all, so there is not one to reach for. Permits do not expire
    /// — `FanWriteAuthorisation.swift` is explicit that freshness is *"policy held by
    /// review, not by the type"* — and § 3 depends on that, because its maximum write has
    /// to be available while the machine is above ceiling and reading may be what has
    /// failed. This branch is the opposite case: it runs below the ceiling, and it has just
    /// successfully read this fan's control state, so reading works. A mechanism that can
    /// read has no excuse to command a fan against bounds nobody has checked since the
    /// system took it back.
    ///
    /// That is also what `CommandedTarget` withholding an `AuthorisedFanTarget` is for: it
    /// makes the re-assert explicitly fallible rather than free, and this is where the
    /// fallibility is spent.
    ///
    /// A re-assert that cannot obtain an envelope **restores rather than commanding** —
    /// #126's acceptance criterion, and `FanControlPlane`'s §2 rule that the only action a
    /// fan with untrusted bounds is subject to is the bounds-free restore verb.
    ///
    /// ## The two writes are not one step, and are not caught together
    ///
    /// `engageManualControl` then `command` were wrapped in a single `do`/`catch`, which
    /// made a firmware that accepted the first and refused the second indistinguishable from
    /// one that refused both. Those are opposite states: the second leaves the fan on
    /// Apple's thermal management, which is safe, and the first leaves it **off** automatic
    /// control holding whatever `F<n>Tg` the system last wrote — a fan pinned at a speed
    /// nobody chose, which is the worst reachable state in this project. They are caught
    /// separately, and the half-landed case restores immediately rather than waiting for a
    /// budget to run out.
    private func reassert(
        _ commanded: CommandedTarget, fanAt index: Int, attempt: Int
    ) async {
        let permit: CommandableFan
        do {
            permit = try await sensing.readEnvelope(ofFan: index).commandable.get()
        } catch {
            log.reclamationReassertHadNoEnvelope(
                fan: index, detail: String(describing: error))
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        // Re-fetched across the envelope read. This is the guard whose absence let § 5 write
        // `F<n>Md` to a fan whose lease had been released while the read was in flight —
        // manual control with no lease behind it, no registry entry to notice it, and
        // nothing left watching. `CLAUDE.md` rule 2.
        guard held[index] != nil else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "its envelope read")
            return
        }

        // **A cancelled sweep does not take a fan off automatic control.** The other half of
        // #144's `stop()` shape: the in-flight guard on `cycle()` makes the *incoming* loop
        // harmless, and this makes the *outgoing* one harmless.
        // `ReclamationSupervisor.stop()` cancels without awaiting, so a sweep suspended
        // inside a read resumes inside a supervisor that has already stopped — and the write
        // below is the only one in this file that moves a fan in the unsafe direction: off
        // Apple's thermal management and onto a target with nothing watching it, because the
        // loop that would have watched it is the loop that was just cancelled. `stop()`
        // documents that it leaves already-held fans held; acquiring a *new* one on the way
        // out is not covered by that reasoning, it runs against it.
        //
        // Only this write is guarded. The restores below resolve *towards* automatic
        // control, which is where a stopping supervisor wants a fan it can no longer see,
        // and § 3 needs no counterpart at all — `bridgeToMaximumThenRelease` ends on
        // `restoreToAutomatic` whether it is cancelled or not.
        //
        // Read from the task, because cancellation is the supervisor's stop signal and
        // `cycle()` runs on the supervisor's task; placed immediately before the write for
        // this file's own rule, that a check separated from the act it guards is not a
        // check.
        //
        // **The attempt is refunded, because the budget counts writes and this branch
        // performs none.** `diverged(_:fanAt:)` spends the attempt before the envelope read
        // that suspends, so the cost is booked at the point of *intent* and this is the one
        // exit that never converts it into a write. Leaving it spent made a sleep/wake cycle
        // — `stop()` then `start()` — able to burn the whole budget without a single
        // `F<n>Md` reaching the firmware: three stop-starts catching one diverged fan inside
        // its read, and the next real sweep skips straight to `finaliseRelease` with cause
        // `.systemReclaimed`. The direction is safe and the account is false, which is
        // exactly what rule 6 forbids — the operator is told the system took a fan Aeolus
        // never once tried to take back, and loses control it could have had.
        //
        // An earlier version of this comment argued the other way, that "restarting with one
        // fewer attempt gives the fan back to automatic control sooner, which is the
        // direction this mechanism fails in". Failing safe is not a licence to mis-attribute:
        // the budget exists to stop Aeolus *fighting* firmware that discards its writes, and
        // an attempt that never reached the wire is not a round of that fight. Refunding
        // keeps the budget measuring the thing it was sized against.
        //
        // Decremented rather than assigned back to `attempt - 1`: `held[index]` is re-fetched
        // above but is not proven to be the same episode, and a decrement is correct for
        // whatever count is actually there. Floored at zero so a concurrent reset —
        // `convergence` zeroes this — cannot leave it negative and hand the fan an extra try.
        guard !Task.isCancelled else {
            if let spent = held[index]?.reassertAttempts {
                held[index]?.reassertAttempts = max(0, spent - 1)
            }
            log.reclamationAbandonedOnCancellation(fan: index)
            return
        }

        do {
            // Re-engage before re-commanding. The system took this fan back, so it is on
            // automatic control: writing `F<n>Tg` without first writing `F<n>Md` would put
            // a number on the wire that nothing honours.
            try await writer.engageManualControl(of: permit)
        } catch {
            // The fan is still on Apple's thermal management, which is the safe state. The
            // attempt is spent and the budget is what bounds the trying.
            log.reclamationWriteFailed(
                verb: "re-engage manual control of", fan: index,
                detail: String(describing: error))
            return
        }

        // Past this point the fan is OFF automatic control, so every exit below has to leave
        // it somewhere deliberate.
        do {
            let recommanded = try await writer.command(commanded.rpm, of: permit)
            held[index]?.commanded = recommanded
            log.reclamationReasserted(
                fan: index,
                rpm: recommanded.rpm,
                attempt: attempt,
                budget: ReclamationLimits.reassertAttemptBudget)
        } catch {
            log.reclamationReassertHalfLanded(fan: index, detail: String(describing: error))
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        // **Verify after acting.** § 3 can latch during either write above, and check-then-
        // act cannot be made atomic across two actors — see `currentRuling()`. If it did,
        // this mechanism has just taken a fan off automatic control that level 2 wants on
        // it, and nothing else will correct that: `ThermalEmergency.fire(_:from:)` empties
        // its own registry as it goes and nothing re-registers a fan with it, so § 3's next
        // cycle will not bridge this one. The undo is therefore this mechanism's own, and it
        // resolves in the safe direction.
        guard await currentRuling().permitsWrite else {
            log.reclamationUndoneAfterEmergencyLatched(fan: index)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }
    }

    // MARK: - Blindness

    /// A cycle that could not read this fan at all.
    ///
    /// Transient failure changes nothing: taking a fan from a client because one read
    /// missed would be over-firing on noise. Persistent failure **is divergence** — § 5 is
    /// explicit that "being unable to read is divergence too" — because the alternative is
    /// a read retried indefinitely while the fans stay pinned, which is ADR 0007's hole 2.
    private func cycleCouldNotSee(fanAt index: Int, detail: String) async {
        guard let fan = held[index] else { return }
        let failures = fan.consecutiveReadFailures + 1
        held[index]?.consecutiveReadFailures = failures

        guard failures >= ReclamationLimits.blindCyclesBeforeDivergence else {
            // Log the transition, not the state: the first blind cycle says so, and the
            // ones after it are silent until either recovery or escalation. #124's forward
            // constraint — a line per tick at 1 Hz is a denial of service against the
            // reader.
            if failures == 1 {
                log.reclamationCycleUnreadable(fan: index, detail: detail)
            }
            return
        }

        log.reclamationBlindnessEscalated(fan: index, afterCycles: failures, detail: detail)

        // The reconnect. One attempt, and its outcome does not change what happens next.
        do {
            try await sensing.reconnect()
            log.reclamationReconnected(fan: index)
        } catch {
            log.reclamationReconnectFailed(fan: index, detail: String(describing: error))
        }

        // Re-fetched across the reconnect. A fan released while the connection was being
        // rebuilt is a fan the lease core has already restored, and marking it reclaimed
        // would report an ordinary release as a loss.
        guard held[index] != nil else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "the reconnect attempt")
            return
        }

        // Restore either way. A reconnect that returned without throwing has not been shown
        // to have fixed anything — only the next read is evidence of that, and waiting for
        // it is another cycle with a fan pinned on a machine nobody can see. § 5 says
        // reconnect **then** restore and report, not reconnect and hope.
        //
        // **Recorded as blindness, not as a reclamation** — #140. This path calls
        // `markReclaimed(fanAt:)` nowhere: nothing here has been learned about who holds the
        // fan, only that the helper cannot read it, and the ledger's reclaimed set is what
        // becomes `FanState.isReclaimedBySystem`. Setting that bit told the user the system
        // had taken a fan while `finaliseRelease` in the next line told the lease core the
        // supervisor had gone blind.
        await ledger.markSupervisorBlind(fanAt: index)
        log.reclamationRestoredBlindFan(fan: index)
        await finaliseRelease(fanAt: index, because: .supervisorBlind)
    }

    // MARK: - Falling back

    /// § 3 holds the fans, so this one is level 2's to dispose of.
    ///
    /// The restore is still attempted — it is the keystone verb, it consumes nothing, and
    /// § 3's own restore may have been refused. What is **not** done here is marking the
    /// ledger or revoking leases: `fire(_:from:)` already revoked every lease before this
    /// mechanism could observe anything, and claiming a reclamation would attribute § 3's
    /// deliberate release to the operating system.
    private func releaseToThermalEmergency(fanAt index: Int) async {
        do {
            try await writer.restoreToAutomatic(.fan(index))
        } catch {
            log.reclamationWriteFailed(
                verb: "restore", fan: index, detail: String(describing: error))
            log.reclamationFanMayStillBePinned(fan: index)
        }
        held[index] = nil
        if await ledger.clearReclaimed(fanAt: index) {
            log.reclamationResolved(fan: index)
        }
    }

    /// The terminal action: hand the fan to Apple's thermal management and drop the leases
    /// that claimed it.
    ///
    /// The restore is attempted whatever else failed, and consumes nothing a failing
    /// machine might be unable to supply — ADR 0007's keystone. The ledger entry for `index`
    /// is **kept**, and what it says depends on which caller got here, because since #140
    /// the two are no longer one bit:
    ///
    /// - `.systemReclaimed` — the system does hold this fan now, that is what the user
    ///   should be told, and it stays true until something deliberately takes it off
    ///   automatic control again.
    /// - `.supervisorBlind` — the helper could not read the fan, so this entry asserts
    ///   **nothing** about who holds it. It records that § 5 gave the fan up and why, which
    ///   is what `ManualControlAvailability.Reason.supervisorBlind` reports and what
    ///   `FanState.isReclaimedBySystem` deliberately does not.
    ///
    /// Either way it is kept rather than cleared, for the reason `clearReclaimed(fanAt:)`
    /// states: a fan this mechanism has just handed back is not a fan known to be fine.
    ///
    /// Every lease is revoked rather than the one covering this fan, for
    /// `ThermalEmergency.fire(_:from:)`'s reason: a lease is a claim over a *set* of fans,
    /// and a client left holding a lease over a subset it can no longer command would be
    /// told it has control it does not have.
    ///
    /// ## Which is why the whole registry goes, not just this fan
    ///
    /// `revokeEveryLease(because:)` drops every lease on the machine and restores the fans
    /// they covered. Every other entry in `held` is therefore a fan that is now unleased and
    /// back on automatic control — and dropping only `index` left them registered, so the
    /// next cycle read `.modeReclaimed` on a sibling and **re-engaged manual control on a
    /// fan with no lease behind it**. Their ledger entries are cleared rather than marked:
    /// they were not reclaimed by anything, they were given up by this mechanism.
    private func finaliseRelease(fanAt index: Int, because cause: FanRestoreCause) async {
        do {
            try await writer.restoreToAutomatic(.fan(index))
        } catch {
            log.reclamationWriteFailed(
                verb: "restore", fan: index, detail: String(describing: error))
            log.reclamationFanMayStillBePinned(fan: index)
        }

        held[index] = nil
        let siblings = held.keys.sorted()
        held.removeAll()

        if !siblings.isEmpty {
            log.reclamationSiblingsReleased(fans: siblings)
            for sibling in siblings where await ledger.clearReclaimed(fanAt: sibling) {
                log.reclamationResolved(fan: sibling)
            }
        }

        await leases.revokeEveryLease(because: cause)
    }

    // MARK: - Per-fan state

    /// What this mechanism knows about one fan it is watching.
    ///
    /// **No write permit is kept here, deliberately.** One was, and it was read nowhere: a
    /// `CommandableFan` stored at registration and overwritten by every envelope read. The
    /// hazard was not the dead field, it was the sentence attached to it — *"replaced by
    /// every successful re-assert, so it is never older than the last envelope actually
    /// read"* — which is both inaccurate on its own terms and an argument, handed to the next
    /// editor, for deleting `reassert(_:fanAt:attempt:)`'s fresh `readEnvelope(ofFan:)` and
    /// passing the stored permit instead. That would remove the bounds check the branch
    /// exists to perform and the "no envelope → restore, not command" failure path with it.
    /// ADR 0008's context is the same defect: a comment telling an editor that load-bearing
    /// code was redundant. The field is gone rather than re-documented, because there is
    /// nothing to reuse if nothing is kept.
    private struct HeldFan: Sendable {
        /// The step last put on the wire, or `nil` when nothing has been commanded yet.
        var commanded: CommandedTarget?
        /// Cycles in a row that could not read this fan. Reset by any successful read.
        var consecutiveReadFailures = 0
        /// Cycles in a row the actual speed has been short of the commanded target. Reset
        /// by convergence and by a fresh command.
        var actualDwellCycles = 0
        /// Re-asserts issued for the current episode. Reset by convergence.
        var reassertAttempts = 0
        /// Divergent cycles spent on this fan before anything was ever commanded on it —
        /// the registration grace, see `gracedBeforeItsFirstCommand(_:of:fanAt:)`.
        ///
        /// **Spent, never reset.** A fan cannot be graced indefinitely by alternating
        /// between divergence and convergence — `examine(fanAt:)`'s converged branch resets
        /// the two counters below it and deliberately not this one — and it cannot be graced
        /// indefinitely by being registered again either: the budget belongs to one
        /// registration, and the only thing that refills it is a fresh `HeldFan`, which
        /// `manualControlEngaged(_:)` builds only for a fan that is not already held.
        var uncommandedDivergentCycles = 0
    }
}
