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
/// the wire, deliberately distinct from the goal a caller was heading for. Actual-versus-
/// target survives as the **secondary** signal, behind `ReclamationLimits.actualDwellCycles`,
/// which is exactly long enough that a ramp is not mistaken for a loss.
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
/// arbiter's own tests.
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
/// the first second of an emergency. It is bounded by § 3's 1 Hz cadence, and § 3 outranks
/// this mechanism: its next cycle bridges the fan to maximum and restores it, which
/// overrides the re-assert rather than racing it. Making this read a temperature of its own
/// to close a one-second window would add a supervisor-priority read per cycle — see
/// [#134](https://github.com/blamechris/Aeolus/issues/134) — to pre-empt a mechanism that
/// already corrects it.
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
///   `LeaseAuthority.swift` already are. The split that *was* available has been taken —
///   `ReclamationDivergence` and `ReclamationLimits` are values rather than mechanism and
///   live in `ReclamationLimits.swift`. What is left is the actor and its private state, and
///   moving any of it into an extension in another file would mean widening that state to
///   the whole module. That state is exactly what makes `examine(fanAt:ruling:)`'s
///   read-then-mutate reasoning checkable, and
///   [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest of this space.
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
    /// mechanism does not engage or release a thermal emergency, and
    /// `ThermalEmergency.cycle()` remains the only caller of `release()` in `Sources/`.
    private let latch: ThermalEmergencyLatch

    /// What the user is told, via `FanState.isReclaimedBySystem`.
    private let ledger: ReclamationLedger

    private let log: SafetyLog

    /// Every fan currently off Apple's thermal management, with what this mechanism knows
    /// about it.
    ///
    /// Keyed by index so a second registration replaces rather than duplicates. Empty is
    /// the ordinary state, and a cycle over an empty registry does nothing at all — there
    /// is no fan pinned, so there is nothing that could be taken back.
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
    /// Clears any reclamation recorded against this fan: something has just taken it off
    /// automatic control, so the ledger's claim that the system holds it is now false, and
    /// a stale `true` there would report a fan as lost that a client is about to command.
    func manualControlEngaged(_ fan: CommandableFan) async {
        held[fan.index] = HeldFan(permit: fan)
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

    /// Examines every held fan once and acts on what it finds.
    ///
    /// Never throws, for `ThermalEmergency.cycle()`'s reason: the driver is a loop in a
    /// root daemon, and an error escaping here would either kill the loop or be swallowed
    /// at the call site. Every failure below becomes a decision plus a log line.
    func cycle() async {
        guard !held.isEmpty else { return }

        // One latch read per cycle rather than per fan. The answer cannot usefully differ
        // between two fans of the same sweep — § 3 is machine-wide — and reading it once
        // means a sweep cannot act on two different views of who holds the fans.
        let incumbent: SafetyActorLevel? = await latch.isActive ? .thermalEmergency : nil
        let ruling = SafetyArbiter.ruling(for: .reclamationWatchdog, incumbent: incumbent)

        // Sorted and sequential. Sorted so a scenario's log and attempt order are
        // deterministic; sequential because this actor must contribute at most one
        // supervisor-priority waiter at a time — see this type's documentation.
        for index in held.keys.sorted() {
            await examine(fanAt: index, ruling: ruling)
        }
    }

    /// One fan: read it, decide, act.
    private func examine(fanAt index: Int, ruling: SafetyRuling) async {
        guard let fan = held[index] else { return }

        let state: FanControlState
        do {
            state = try await sensing.readControlState(ofFan: index)
        } catch {
            await cycleCouldNotSee(fanAt: index, detail: String(describing: error))
            return
        }

        if fan.consecutiveReadFailures > 0 {
            log.reclamationTelemetryRecovered(
                fan: index, afterCycles: fan.consecutiveReadFailures)
            held[index]?.consecutiveReadFailures = 0
        }

        // Primary first, and it is the only signal that can fire on its own.
        if let primary = Self.primaryDivergence(of: state, against: fan.commanded) {
            held[index]?.actualDwellCycles = 0
            await diverged(primary, fanAt: index, ruling: ruling)
            return
        }

        // Secondary: the fan is not turning as fast as it was told to, sustained.
        if let shortfall = Self.actualShortfall(of: state, against: fan.commanded) {
            let dwell = (held[index]?.actualDwellCycles ?? 0) + 1
            held[index]?.actualDwellCycles = dwell
            guard dwell >= ReclamationLimits.actualDwellCycles else { return }
            await diverged(
                .actualShortfall(
                    actual: shortfall.actual,
                    commanded: shortfall.commanded,
                    dwellCycles: dwell),
                fanAt: index, ruling: ruling)
            return
        }

        // Converged on both signals.
        held[index]?.actualDwellCycles = 0
        held[index]?.reassertAttempts = 0
        if await ledger.clearReclaimed(fanAt: index) {
            log.reclamationResolved(fan: index)
        }
    }

    // MARK: - The signals

    /// § 5's primary signal: what was written against what the firmware reads back.
    ///
    /// Pure, and static, so the whole of the ruling is one expression over two values a
    /// test can construct directly.
    ///
    /// **The mutation this exists to survive** is replacing this comparison with an
    /// actual-versus-target one — `switch state.target` becoming `switch state.actualRPM`.
    /// Run: `ReclamationWatchdogTests`'s "An emergency ramp in flight is not read as
    /// reclamation" goes red on both its assertions, because that scenario has `F<n>Tg`
    /// holding exactly what § 3 commanded while `F<n>Ac` is still climbing — convergence
    /// here, and divergence under the mutant.
    private static func primaryDivergence(
        of state: FanControlState, against commanded: CommandedTarget?
    ) -> ReclamationDivergence? {
        // The mode is the unambiguous half, and it needs no commanded target to read: a fan
        // Aeolus is holding that the firmware reports as automatic has been taken back,
        // whatever any RPM key says.
        guard state.mode == .manual else { return .modeReclaimed }

        switch state.target {
        case .unreadable(let reason):
            // **Divergence, never "no divergence".** This is why `FanRPMReadback` is an enum
            // and not a `Double?`: a watchdog that could not tell "no target set" from "this
            // target could not be read" would report a fan it can no longer see as healthy,
            // which is the single failure this signal exists to prevent.
            return .targetUnreadable(reason: reason)
        case .rpm(let readBack):
            // Nothing has been commanded on this fan yet — it came off automatic control
            // and no target followed. The mode check above is the whole of what can be said.
            guard let commanded else { return nil }
            guard abs(readBack - commanded.rpm) > ReclamationLimits.targetToleranceRPM
            else { return nil }
            return .targetDiverged(commanded: commanded.rpm, readBack: readBack)
        }
    }

    /// § 5's secondary signal: the fan is turning slower than it was told to.
    ///
    /// A **shortfall** only. A fan spinning faster than asked is the system helping or a
    /// sensor reading high, and neither is Aeolus losing control of it; treating it as
    /// divergence would fire this mechanism on a machine that is cooling perfectly well.
    ///
    /// An unreadable `F<n>Ac` is *not* divergence here, and that is not an inconsistency
    /// with the primary signal's treatment of an unreadable target. The target read-back is
    /// the evidence that the fan is still ours; the actual speed is corroboration. Losing
    /// corroboration while the evidence still reads correctly is a degraded cycle, not a
    /// reclamation — and a total read failure is caught by `examine(fanAt:ruling:)`'s
    /// blindness path rather than here.
    ///
    /// - Returns: both speeds when the observed one is short by more than the tolerance,
    ///   else `nil`. The caller applies the dwell; this function has no memory.
    ///
    /// It returns the commanded speed as well as the observed one so the caller never has to
    /// re-derive it. An earlier draft returned only the observed speed and the call site
    /// read the other half back out of an optional with a `?? 0` fallback — a fabricated
    /// zero that could only ever have reached a `.fault` log line telling an operator a fan
    /// had been commanded to stop, which is the one number this project may never state.
    private static func actualShortfall(
        of state: FanControlState, against commanded: CommandedTarget?
    ) -> (actual: Double, commanded: Double)? {
        guard let commanded, case .rpm(let actual) = state.actualRPM else { return nil }
        let tolerance = commanded.rpm * ReclamationLimits.actualToleranceFraction
        guard commanded.rpm - actual > tolerance else { return nil }
        return (actual: actual, commanded: commanded.rpm)
    }

    // MARK: - Acting on divergence

    /// Divergence is confirmed for this fan. Re-assert, or fall back and report.
    private func diverged(
        _ divergence: ReclamationDivergence, fanAt index: Int, ruling: SafetyRuling
    ) async {
        // Report before acting. Whatever happens next, the user's display should already
        // say the system holds this fan — `CLAUDE.md` rule 6 is about the window as much as
        // the steady state.
        if await ledger.markReclaimed(fanAt: index) {
            log.reclamationDetected(fan: index, divergence: divergence)
        }

        // **The above-ceiling rule.** Deleting this guard is the mutation
        // `ReclamationWatchdogTests.itNeverReassertsWhileTheThermalLatchHolds` exists to
        // kill: without it, § 5 re-asserts a user's target into a machine § 3 has just
        // handed to Apple's thermal management, and the two mechanisms fight over a fan
        // while a CPU sits above its ceiling.
        guard ruling.permitsWrite else {
            log.reclamationYieldedToThermalEmergency(fan: index, divergence: divergence)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        guard let commanded = held[index]?.commanded else {
            // Nothing was ever commanded here, so there is no target to re-assert to. The
            // fan came off automatic control and the system took it back before a speed
            // followed; restoring is both the honest answer and the only available one.
            log.reclamationHadNothingToReassert(fan: index)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        let attempts = held[index]?.reassertAttempts ?? 0
        guard attempts < ReclamationLimits.reassertAttemptBudget else {
            log.reclamationBudgetExhausted(
                fan: index, attempts: attempts, divergence: divergence)
            await finaliseRelease(fanAt: index, because: .systemReclaimed)
            return
        }

        held[index]?.reassertAttempts = attempts + 1
        await reassert(commanded, fanAt: index, attempt: attempts + 1)
    }

    /// One bounded attempt to take the fan back, below the ceiling.
    ///
    /// ## It reads a fresh envelope, and that is deliberate
    ///
    /// Not the permit taken when the fan came off automatic control. Permits do not expire
    /// — `FanWriteAuthorisation.swift` is explicit that freshness is *"policy held by
    /// review, not by the type"* — and § 3 depends on that, because its maximum write has
    /// to be available while the machine is above ceiling and reading may be what has
    /// failed. This branch is the opposite case: it runs **only below the ceiling**, and it
    /// has just successfully read this fan's control state, so reading works. A mechanism
    /// that can read has no excuse to command a fan against bounds nobody has checked since
    /// the system took it back.
    ///
    /// That is also what `CommandedTarget` withholding an `AuthorisedFanTarget` is for: it
    /// makes the re-assert explicitly fallible rather than free, and this is where the
    /// fallibility is spent.
    ///
    /// A re-assert that cannot obtain an envelope **restores rather than commanding** —
    /// #126's acceptance criterion, and `FanControlPlane`'s §2 rule that the only action a
    /// fan with untrusted bounds is subject to is the bounds-free restore verb.
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
        held[index]?.permit = permit

        do {
            // Re-engage before re-commanding. The system took this fan back, so it is on
            // automatic control: writing `F<n>Tg` without first writing `F<n>Md` would put
            // a number on the wire that nothing honours, and the next cycle would read the
            // divergence again with an attempt spent for no action.
            try await writer.engageManualControl(of: permit)
            let recommanded = try await writer.command(commanded.rpm, of: permit)
            held[index]?.commanded = recommanded
            log.reclamationReasserted(
                fan: index,
                rpm: recommanded.rpm,
                attempt: attempt,
                budget: ReclamationLimits.reassertAttemptBudget)
        } catch {
            // The attempt is spent, not converted into an immediate restore. A firmware
            // that refuses one write may honour the next, the budget is what bounds the
            // trying, and `no_silent_write_failure` is why this is a logged decision rather
            // than a `try?`. Exhausting the budget is what falls back.
            log.reclamationWriteFailed(
                verb: "re-assert control of", fan: index, detail: String(describing: error))
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
        let failures = (held[index]?.consecutiveReadFailures ?? 0) + 1
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

        // Restore either way. A reconnect that returned without throwing has not been shown
        // to have fixed anything — only the next read is evidence of that, and waiting for
        // it is another cycle with a fan pinned on a machine nobody can see. § 5 says
        // reconnect **then** restore and report, not reconnect and hope.
        await ledger.markReclaimed(fanAt: index)
        log.reclamationRestoredBlindFan(fan: index)
        await finaliseRelease(fanAt: index, because: .supervisorBlind)
    }

    // MARK: - Falling back

    /// The terminal action: hand the fan to Apple's thermal management and drop the leases
    /// that claimed it.
    ///
    /// The restore is attempted whatever else failed, and consumes nothing a failing
    /// machine might be unable to supply — ADR 0007's keystone. The ledger entry is
    /// **kept**: the system does hold this fan now, that is what the user should be told,
    /// and it stays true until something deliberately takes it off automatic control again.
    ///
    /// Every lease is revoked rather than the one covering this fan, for
    /// `ThermalEmergency.fire(_:from:)`'s reason: a lease is a claim over a *set* of fans,
    /// and a client left holding a lease over a subset it can no longer command would be
    /// told it has control it does not have.
    private func finaliseRelease(fanAt index: Int, because cause: FanRestoreCause) async {
        do {
            try await writer.restoreToAutomatic(.fan(index))
        } catch {
            log.reclamationWriteFailed(
                verb: "restore", fan: index, detail: String(describing: error))
        }

        // Stop watching. This mechanism has said everything it can say about this fan, and
        // a registry entry that outlived the decision would go on spending budget and
        // logging against a fan nothing is holding.
        held[index] = nil
        await leases.revokeEveryLease(because: cause)
    }

    // MARK: - Per-fan state

    /// What this mechanism knows about one fan it is watching.
    private struct HeldFan: Sendable {
        /// The write permit. Replaced by every successful re-assert, so it is never older
        /// than the last envelope actually read.
        var permit: CommandableFan
        /// The step last put on the wire, or `nil` when nothing has been commanded yet.
        var commanded: CommandedTarget?
        /// Cycles in a row that could not read this fan. Reset by any successful read.
        var consecutiveReadFailures = 0
        /// Cycles in a row the actual speed has been short of the commanded target. Reset
        /// by convergence and by a fresh command.
        var actualDwellCycles = 0
        /// Re-asserts issued for the current episode. Reset by convergence.
        var reassertAttempts = 0
    }
}
