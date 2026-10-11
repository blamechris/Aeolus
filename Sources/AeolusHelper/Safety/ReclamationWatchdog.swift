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
/// Asked in `diverged(_:fanAt:)` before a re-assert, by the `EngagementDriver` before and after
/// every step of its mode write, and again by `reassert(_:fanAt:attempt:)` after its command
/// write (`currentRuling()`, via `SafetyArbiter.ruling(for:incumbent:)`), never by a second
/// `if temperature > ceiling`. The latch over-refuses (safe) but lags a ceiling crossing by up
/// to one § 3 cycle, so a re-assert can still be issued into that cycle; the re-checks after the
/// writes undo one the latch engaged underneath them, and the driver's § 3 registration covers
/// an undo the firmware refuses (#181).
/// reclamation-watchdog.md § *"The above-ceiling rule is the arbiter, not an `if`"*.
///
/// ## Reads are strictly sequential, and that is #134's answer for this issue
///
/// One fan is examined at a time, `await`ed to completion before the next, so this actor is
/// at most one supervisor waiter on `SMCReadScheduler` however many fans there are.
/// reclamation-watchdog.md § *"Reads are strictly sequential, and that is #134's answer for
/// this issue"*.
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
/// ## Running, with nothing to watch
///
/// `ReclamationSupervisor` is the loop: `HelperComposition` constructs it and `bringUp()`
/// starts it. No lease can be granted in this build, so nothing registers a fan here and every
/// cycle returns at once. E3 owns registering fans and telling this actor what it commanded.
///
/// - Note: everything below reads or writes `held`, `log`, `ledger`, `writer`, `sensing`,
///   `leases` or `latch`, so none of it can move to another file without widening that
///   state. The splits already taken, and the rationale relocated out of this file's doc
///   comments, are recorded in
///   [docs/records/reclamation-watchdog.md](../../../docs/records/reclamation-watchdog.md).
///   Relocating prose cannot relieve `type_body_length`, which counts this body's code: about
///   52 lines of headroom remain before its error at 350 (298 code lines since #346). New
///   behaviour belongs in value types and the `EngagementDriver`
///   ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md)), not in this actor.
///   [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest of this space.
actor ReclamationWatchdog<Plane: FanControlPlane> {

    /// The read half of the seam. **Not a `FanControlPlane`**, so this actor cannot
    /// command a fan except through `writer` — see `FanStateSensing` for why that is a
    /// compile-time property rather than a rule.
    private let sensing: any FanStateSensing

    /// Level 3's ungoverned writer. § 8 cannot reach it: `SafetyActorWriter` holds no
    /// `RampGovernor` and has no property one could be assigned to.
    private let writer: SafetyActorWriter<Plane>

    /// What the re-assert engages through, and what every restore here hands back through: the
    /// entitlement around each step, the § 3 registration, and the undo
    /// ([ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md) D2, D4; #181).
    private let engagement: EngagementDriver<Plane>

    /// The authority on whether a fan in `held` is still Aeolus's to hold — asked in every
    /// `examine(fanAt:)`, ADR 0009 D2 — and what `finaliseRelease(fanAt:because:)` revokes.
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

    /// The fan `finaliseRelease(fanAt:because:)` is giving up right now, whose ledger entry a
    /// release notification must not clear (#346) — see `manualControlReleased(fanAt:)`. A set
    /// only for legibility: one sweep runs at a time, so it never holds more than one fan.
    private var finalising: Set<Int> = []

    /// `sensing` is an existential rather than `some FanStateSensing`, unlike
    /// `ThermalEmergency`'s `telemetry`. It is stored as one either way, and taking it as an
    /// existential lets a caller choose the seam at run time — which the test target does,
    /// substituting a double for the read failures `ScriptedControlPlane`'s stages cannot
    /// express. There is no generic specialisation to lose: every call on it is a protocol
    /// witness through the stored `any` regardless of how it arrived.
    init(
        sensing: any FanStateSensing,
        writer: SafetyActorWriter<Plane>,
        engagement: EngagementDriver<Plane>,
        leases: LeaseAuthority,
        latch: ThermalEmergencyLatch,
        ledger: ReclamationLedger,
        log: SafetyLog = SafetyLog()
    ) {
        self.sensing = sensing
        self.writer = writer
        self.engagement = engagement
        self.leases = leases
        self.latch = latch
        self.ledger = ledger
        self.log = log
    }

    // MARK: - What is under manual control

    /// Registers a fan that has just been taken off automatic control.
    ///
    /// Called by whoever engages a fan, once `EngagementDriver.engageManualControl(of:)` has
    /// returned — level 6's `apply`, once it exists. The driver has already registered the fan
    /// with § 3 (`ThermalEmergency.manualControlEngaged(_:)`) by then.
    ///
    /// ## The ordering is normative: call this **after** the `F<n>Md` write has landed
    ///
    /// Register only after the `F<n>Md` write has landed. Registered first, a `cycle()` can read
    /// `.modeReclaimed` on a fan with nothing commanded; once the registration grace runs out
    /// (three divergent cycles) it restores the fan and revokes **every lease on the machine**.
    /// reclamation-watchdog.md § *"The ordering is normative: call this **after** the
    /// `F<n>Md` write has landed"*.
    ///
    /// ## The far side of the write is not free either, and the grace is what pays for it
    ///
    /// `gracedBeforeItsFirstCommand(_:of:fanAt:)` gives a fan with nothing commanded
    /// `ReclamationLimits.blindCyclesBeforeDivergence` cycles before the primary signal reaches
    /// the terminal action. Registering early still costs the client its lease, three cycles
    /// later instead of one.
    /// reclamation-watchdog.md § *"The far side of the write is not free either, and the
    /// grace is what pays for it"*.
    ///
    /// ## The parameter stays a `CommandableFan`
    ///
    /// Only `fan.index` is read, but a `CommandableFan` can only be minted from an envelope
    /// that passed its bounds gate, so the type is what makes registration lawful only from a
    /// caller authorised to write the fan. reclamation-watchdog.md § *"The parameter stays a
    /// `CommandableFan`"*.
    ///
    /// ## Re-registering a fan already held changes nothing about it
    ///
    /// The entry is created only when there is not one already, so its grace and its
    /// `commanded` target survive a second call. `HeldFan` says what refilling either cost.
    ///
    /// ## A live lease must already cover the fan
    ///
    /// ADR 0009 D2: every examination asks the lease table before it believes a reading, so a
    /// fan registered with no live lease covering it is `.leaseLapsed` on its first cycle and
    /// handed back. Acquire, then engage, then register.
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
    ///
    /// **A hint, not the authority** — ADR 0009 D2. `HelperFanRestorer` calls this before
    /// every lease-core restore, and `.leaseLapsed` is what hands back a fan whose lease
    /// ended without it: past its deadline and not yet swept, or registered after its lease.
    ///
    /// **Except the ledger of a fan `finaliseRelease(fanAt:because:)` is giving up** (#346). Its
    /// revocation's restorer sends this for that fan while the terminal action is suspended,
    /// and clearing then erased the entry it keeps, so a fan the system took was reported as
    /// not taken. The registry entry still goes and the restore is untouched; this clear is
    /// skipped, not postponed, so the mark stays until a later release or an engagement.
    /// reclamation-watchdog.md § *"The ledger entry `finaliseRelease` keeps"*.
    func manualControlReleased(fanAt index: Int) async {
        held[index] = nil
        guard !finalising.contains(index) else { return }
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

    /// One fan: read it, ask whether anyone is entitled to it, decide, act.
    private func examine(fanAt index: Int) async {
        guard held[index] != nil else { return }

        // Read here, believed only below the lease check — a failed read included.
        let reading: Result<FanControlState, any Error>
        do {
            reading = .success(try await sensing.readControlState(ofFan: index))
        } catch {
            reading = .failure(error)
        }

        // Re-fetched after the read, never carried across it. `manualControlReleased(fanAt:)`
        // runs on whatever task the lease core is on and can clear this entry while the read
        // is in flight; judging the fan from the pre-read copy reported an ordinary lease
        // expiry as the system reclaiming a fan, and revoked whatever lease was live at that
        // instant.
        guard held[index] != nil else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "its control-state read")
            return
        }

        // **`.leaseLapsed`, ADR 0009 D2: the lease table is the authority and `held` a hint**,
        // so a fan no live lease covers is restored and forgotten whatever the reading says.
        // After the read, never before: every teardown removes its entry before it restores,
        // so a read that saw that restore land is followed by a query that sees the lease
        // gone — asked first, the restore reads as `.modeReclaimed` and is re-asserted. Before
        // both signals and a failed read's count: blindness is grounds to act on a held fan.
        let entitled = await leases.hasLiveLease(coveringFan: index)

        // Re-fetched across the lease hop before either answer is acted on, so a fan released
        // during it gets no second restore and no false "may still be pinned". **Untested, and
        // kept by this file's re-fetch rule.** No seam wraps the hop. The only way found to land
        // a release inside it blocks a cooperative-pool thread from the lease clock, which failed
        // on CI (run 37940001373) and is unsafe in a parallel suite; #344 tracks a seam that
        // does not block.
        guard let fan = held[index] else {
            log.reclamationFanReleasedMidExamination(fan: index, during: "the lease check")
            return
        }
        guard entitled else {
            log.reclamationLeaseLapsed(fan: index)
            await restoreAndForget(fanAt: index)
            return
        }

        let state: FanControlState
        switch reading {
        case .success(let read):
            state = read
        case .failure(let error):
            await cycleCouldNotSee(fanAt: index, detail: String(describing: error))
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
    /// On a fan with nothing commanded, `.modeReclaimed` (the write-to-read-back lag) and
    /// `.targetUnreadable` are decided before `commanded` is consulted, and either would take
    /// the terminal action: restore, revoke **every lease on the machine**, blame the OS (#147).
    /// reclamation-watchdog.md § *"The window this closes"*.
    ///
    /// ## Why the failure asymmetry inverts here, and only here
    ///
    /// With no commanded target there is no pinned-fan hazard, so over-firing costs the client
    /// a lease it still held. The tolerance is granted only while `commanded` is `nil`; the first
    /// `commandedTarget(_:)` ends it.
    /// reclamation-watchdog.md § *"Why the failure asymmetry inverts here, and only here"*.
    ///
    /// ## Bounded by `blindCyclesBeforeDivergence`, and not by a fourth constant
    ///
    /// The same constant as `cycleCouldNotSee(fanAt:detail:)`, because it is the same question.
    /// reclamation-watchdog.md § *"Bounded by `blindCyclesBeforeDivergence`, and not by a
    /// fourth constant"*.
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
    /// The secondary signal is only evaluated once the primary has converged, so the firmware
    /// is holding Aeolus's target and nothing was reclaimed: a fan that cannot reach it is
    /// reported, and neither re-asserted, restored nor marked `isReclaimedBySystem`.
    /// reclamation-watchdog.md § *"Why this no longer reaches the terminal action"*.
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
            await restoreAndForget(fanAt: index)
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
        await reassert(
            commanded, fanAt: index, attempt: attempt, reengaging: divergence == .modeReclaimed)
    }

    /// One bounded attempt to take the fan back, below the ceiling.
    ///
    /// ## It reads a fresh envelope, and that is deliberate
    ///
    /// A re-assert reads a fresh envelope rather than reusing a stored permit (`HeldFan` keeps
    /// none), and one that cannot obtain an envelope restores rather than commanding (#126).
    /// reclamation-watchdog.md § *"It reads a fresh envelope, and that is deliberate"*.
    ///
    /// ## The two writes are not one step, and are not caught together
    ///
    /// `engageManualControl` and `command` are caught separately: a firmware that took the first
    /// and refused the second leaves the fan off automatic control at a speed nobody chose, so
    /// that half-landed case restores at once.
    /// reclamation-watchdog.md § *"The two writes are not one step, and are not caught
    /// together"*.
    ///
    /// ## Only a reclaimed mode is re-engaged
    ///
    /// The mode write runs ADR 0014 D3's unlock through the driver, whose first step refuses a
    /// fan whose raw mode is not `0` — so it is issued only for `.modeReclaimed`. A fan still in
    /// manual whose target diverged is re-commanded alone, after the same entitlement the driver
    /// asks before every step (#181), and the post-write ruling covers both.
    private func reassert(
        _ commanded: CommandedTarget, fanAt index: Int, attempt: Int, reengaging: Bool
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
            // Through the value type, so a fan released meanwhile refunds nothing and the
            // return below is the only thing that follows.
            held[index]?.refundReassertAttempt()
            log.reclamationAbandonedOnCancellation(fan: index)
            return
        }

        do {
            // Re-engage before re-commanding a reclaimed fan: it is on automatic control, and
            // writing `F<n>Tg` without first writing `F<n>Md` would put a number on the wire
            // that nothing honours. The driver asks the ruling and the lease before every step
            // — #181's pre-engage ruling — and has undone any step it took by the time it
            // throws. A fan still in manual is asked the same entitlement before its command.
            if reengaging {
                try await engagement.engageManualControl(of: permit)
            } else {
                try await engagement.requireEntitlement(for: permit)
            }
        } catch let refusal as EngagementRefusal where refusal.yieldsTheFan {
            // Not § 5's fan any more: `diverged`'s refusal path, without the attempt's write.
            log.reclamationReassertYielded(fan: index, refusal: refusal)
            await restoreAndForget(fanAt: index)
            return
        } catch {
            // The driver has handed back any step it took, so the fan is on Apple's thermal
            // management — or, if that undo was refused, registered with § 3, and the driver
            // said so at `.fault`. The attempt is spent and the budget is what bounds the trying.
            log.reclamationWriteFailed(
                verb: "re-engage manual control of", fan: index,
                detail: String(describing: error))
            return
        }

        // Past this point the fan is OFF automatic control, so every exit below has to leave
        // it somewhere deliberate. A fan released during either write is held by nobody, so
        // both re-fetches below restore before they stop, where the envelope one only stops:
        // this write may have landed after the release's own restore, and nothing else knows.
        guard held[index] != nil else {
            log.reclamationReleasedMidReassert(fan: index, during: "its first write")
            await restoreAndForget(fanAt: index)
            return
        }

        let recommanded: CommandedTarget
        do {
            recommanded = try await writer.command(commanded.rpm, of: permit)
        } catch {
            log.reclamationReassertHalfLanded(fan: index, detail: String(describing: error))
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        // A `guard`, and not `held[index]?.commanded = recommanded` as it was until #180: a
        // release during the write made that assignment vanish while the line below reported
        // a re-assert, and the fan was left off automatic control with nothing watching it.
        guard var fan = held[index] else {
            log.reclamationReleasedMidReassert(fan: index, during: "its command write")
            await restoreAndForget(fanAt: index)
            return
        }
        fan.commanded = recommanded
        held[index] = fan
        log.reclamationReasserted(
            fan: index,
            rpm: recommanded.rpm,
            attempt: attempt,
            budget: ReclamationLimits.reassertAttemptBudget)

        // **Verify after acting.** § 3 can latch during the command write above, and check-
        // then-act cannot be made atomic across two actors — see `currentRuling()`. If it did,
        // this mechanism has just commanded a fan level 2 wants on automatic control. The undo
        // is this mechanism's own and resolves in the safe direction; if the firmware refuses
        // it, the driver's § 3 registration is what bridges the fan in the emergency (#181).
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

    /// This fan is not § 5's to judge, so hand it back and stop watching it: § 3 holds the
    /// fans, or — `.leaseLapsed`, and a release during a re-assert write — nobody does.
    ///
    /// The restore is still attempted — it is the keystone verb, it consumes nothing, and
    /// whoever handed the fan back first may have been refused. What is **not** done here is
    /// marking the ledger or revoking leases. Revoking is § 3's own act — `fire(_:from:)`
    /// revokes every lease once it has bridged the fans, so one can still be live while § 5
    /// looks — a lapsed lease has nothing to revoke, and claiming a reclamation would blame
    /// the operating system for § 3's release or a lease ending. Forgotten even when the
    /// restore is refused, as ADR 0009 D2's "restore-and-forget" says: the `.fault` lines below
    /// are the residual.
    ///
    /// **Forgotten before the restore, not after it.** A re-grant is the ordinary next event
    /// for a fan handed back here, and a registration landing while the restore is in flight
    /// must start a fresh entry, not be erased by this one: forgetting afterwards left a fan off
    /// automatic control under a live lease with nothing watching it. `HelperFanRestorer` also
    /// tells § 5 before its write, and unlike checking the entry's episode after the write,
    /// forgetting first needs no identity `HeldFan` does not carry.
    ///
    /// **§ 3 is deregistered by the hand-back, for all three callers** (#181): a restore the
    /// firmware accepts marks the fan owed § 3's read-back, and a refused one leaves it in § 3's
    /// registry. § 3's yield needs it most — a latched § 3 bridges what is registered.
    private func restoreAndForget(fanAt index: Int) async {
        held[index] = nil
        do {
            try await engagement.handBack(fanAt: index)
        } catch {
            log.reclamationWriteFailed(
                verb: "restore", fan: index, detail: String(describing: error))
            log.reclamationFanMayStillBePinned(fan: index)
        }
        if await ledger.clearReclaimed(fanAt: index) {
            log.reclamationResolved(fan: index)
        }
    }

    /// The terminal action: hand the fan to Apple's thermal management and drop the leases
    /// that claimed it.
    ///
    /// The restore is attempted whatever else failed. The ledger entry for `index` is **kept**,
    /// as `.systemReclaimed` or `.supervisorBlind` depending on the caller (#140) — and kept
    /// through this call's own revocation, whose release notice skips its clear while this runs:
    /// the mark stays until a later release or engagement (#346).
    /// reclamation-watchdog.md § *"The ledger entry `finaliseRelease` keeps"*.
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
    ///
    /// The restore is the driver's hand-back, so § 3 is deregistered as `restoreAndForget`
    /// describes (#181); the siblings are the lease core's, whose restorer tells § 3 itself.
    private func finaliseRelease(fanAt index: Int, because cause: FanRestoreCause) async {
        // Before the first suspension, not around the revocation alone: a lease teardown landing
        // during the hand-back sends the same notice about a fan § 5 has already judged.
        finalising.insert(index)
        defer { finalising.remove(index) }
        do {
            try await engagement.handBack(fanAt: index)
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
}
