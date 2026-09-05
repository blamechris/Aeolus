import Foundation
import SMCCore
import os

/// What the safety subsystem says about its own ability to see.
///
/// Its own category, separate from `LeaseLog`'s, because it answers a different question.
/// `LeaseLog` answers *"why are the fans not where the user left them?"*. This one answers
/// *"was the mechanism that protects them actually watching?"* — and those diverge exactly
/// when it matters, because a degraded supervisor produces no lease events at all.
///
/// ## Why a degraded cycle has to be logged
///
/// `CriticalSensorSet`'s justification for a compiled-in key list is that asking for a key
/// this firmware does not expose is *not* a failure: the seam reports it in
/// `CriticalTemperatureReport.unreadableKeys`, and partial loss is a degraded, logged cycle
/// rather than blindness. That argument is only sound if something logs it. Before this
/// type existed nothing did — `unreadableKeys` had no readers anywhere in `Sources/` — so
/// 33 of 34 curated keys could fall silent and every `acquireLease` would still be granted,
/// with nothing in `log show` and no signal to any client. "Degraded but sighted" would
/// have been indistinguishable from healthy, which is the precise property the seam's own
/// documentation says this subsystem must not have.
struct SafetyLog: Sendable {

    /// How loud a line is.
    ///
    /// Two levels and no more. `degradedCycle`'s own note already argues the distinction
    /// that matters — a fault-level line for a routine partial read would train the reader
    /// to ignore the level that real trouble uses — so the vocabulary is exactly "the
    /// mechanism is working, with something worth knowing" and "the mechanism fired, or
    /// could not".
    enum Level: Sendable, Hashable {
        /// Persisted by default, unlike `.info`, because the whole value of these lines is
        /// being there when somebody goes looking afterwards.
        case notice
        /// § 3 engaged or released, or a write on its path did not land.
        case fault
    }

    private let emit: @Sendable (Level, String) -> Void

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Safety") {
        let logger = Logger(subsystem: subsystem, category: category)
        emit = { level, message in
            switch level {
            case .notice: logger.notice("\(message, privacy: .public)")
            case .fault: logger.fault("\(message, privacy: .public)")
            }
        }
    }

    /// A sink a test can read back, **including the level**.
    ///
    /// `LeaseLog` has no equivalent and its lines go unasserted, which was tolerable while
    /// the log was commentary. It is not tolerable here: "partial loss is a degraded
    /// **logged** cycle" is the stated justification for compiling a fixed key list into
    /// the helper, and a review found that sentence true of nothing — `unreadableKeys` had
    /// no reader anywhere in `Sources/`. A claim that load-bearing needs a test that fails
    /// when it stops being true, and a test cannot read `os_log`.
    /// The level is passed through rather than discarded. An earlier version of this
    /// initialiser was `{ _, message in sink(message) }`, which meant every `.fault` line
    /// here could be demoted to `.notice` with the whole suite green — the level was a
    /// claim no test could check, in the type whose own header says a load-bearing claim
    /// "needs a test that fails when it stops being true".
    init(recording sink: @escaping @Sendable (Level, String) -> Void) {
        emit = sink
    }

    /// Some curated keys answered and some did not.
    ///
    /// `.notice` rather than `.info`, because `.info` is not persisted by default and the
    /// whole value of this line is being there when somebody goes looking afterwards. Not
    /// `.fault` either: this is a machine still doing its job with fewer sensors, and a
    /// fault-level line for a routine partial read would train the reader to ignore the
    /// level that total blindness uses.
    ///
    /// - Note: the caller is currently `acquireLease`, so this fires at most once per lease
    ///   acquisition. When #125's supervisor polls on a cycle, an unchanged degraded set
    ///   will need collapsing — a per-cycle line at 1 Hz is not a log, it is a denial of
    ///   service against the reader. Said here rather than discovered there.
    /// - Note: every field interpolated below is compiled-in or firmware-derived — key
    ///   names, counts, and a provenance string this module wrote — so marking the whole
    ///   line `.public` discloses nothing a client chose. That is why one interpolated
    ///   string is acceptable here and would not be in `LeaseLog`, which carries
    ///   `holderDescription`.
    func degradedCycle(
        provenance: String, answered: Int, requested: Int, silent: [SMCKey]
    ) {
        emit(
            .notice,
            """
            Critical temperature cycle degraded: \(answered) of \(requested) curated keys \
            answered (\(provenance)). Silent: \(Self.describe(silent)). The thermal \
            override is still watching, on fewer sensors than it was built with.
            """
        )
    }

    /// The degraded set went away: every curated key is answering again.
    ///
    /// The other half of "log the transition, not the state". Without it a reader sees a
    /// machine lose sensors and never sees it get them back, which reads as a fault that
    /// is still current however long ago it cleared.
    func degradationCleared(provenance: String, answered: Int) {
        emit(
            .notice,
            """
            Critical temperature cycle recovered: all \(answered) curated keys are \
            answering again (\(provenance)).
            """
        )
    }

    // MARK: - docs/SAFETY.md § 3

    /// The override fired.
    ///
    /// `.fault`, and this is the line the level exists for: a root daemon has just taken
    /// the fans from a client that did nothing wrong, because the machine was too hot. If
    /// one line from this subsystem is ever read, it is this one.
    func thermalEmergencyEngaged(
        hottest: CriticalTemperature, ceiling: Double, fansHeld: Int
    ) {
        emit(
            .fault,
            """
            Thermal emergency engaged: \(hottest.key.rawValue) read \
            \(Self.celsius(hottest.celsius)) against a \(Self.celsius(ceiling)) ceiling. \
            \(fansHeld) fan(s) under manual control go to maximum and then back to \
            automatic; any lease covering them is revoked and no new lease is granted \
            while this holds.
            """
        )
    }

    /// The override let go: a fresh reading fell a hysteresis margin below the ceiling.
    func thermalEmergencyReleased(hottest: CriticalTemperature, threshold: Double) {
        emit(
            .fault,
            """
            Thermal emergency released: the hottest curated key \
            (\(hottest.key.rawValue)) read \(Self.celsius(hottest.celsius)), at or below \
            the \(Self.celsius(threshold)) release threshold. Leases may be granted again.
            """
        )
    }

    /// The bridge write landed: this fan is at its highest commandable speed, in one step.
    func emergencyCommandedMaximum(fan: Int, rpm: Double) {
        emit(
            .notice,
            """
            Thermal emergency commanded fan \(fan) to \(Int(rpm.rounded())) RPM in a \
            single write, bypassing the ramp governor (docs/SAFETY.md § 8, ADR 0007).
            """
        )
    }

    /// A write on the emergency's path did not land.
    ///
    /// `detail` is helper-authored — a `FanControlPlaneError`'s own description — never
    /// client-chosen text, which is what keeps the whole line safe to mark `.public`. The
    /// same rule the type's header states for `degradedCycle`.
    func emergencyWriteFailed(verb: String, fan: Int, detail: String) {
        emit(
            .fault,
            """
            Thermal emergency could not \(verb) fan \(fan): \(detail). The restore verb \
            is attempted regardless — under-firing is the dangerous direction.
            """
        )
    }

    /// A fan came under manual control while § 3 was already holding.
    ///
    /// It should not be reachable in the ordinary case — a latched machine refuses every
    /// `acquireLease` — so a line here means either a lease raced the grant-time check or a
    /// client engaged a fan under a lease it already held. Both are worth seeing.
    func thermalEmergencyTakingBackLateEngagement(fans: [Int]) {
        emit(
            .fault,
            """
            Thermal emergency taking back fan(s) \
            \(fans.map(String.init).joined(separator: ", ")) engaged while it was already \
            holding. They go to maximum and then back to automatic, and every lease is \
            revoked.
            """
        )
    }

    /// The latch was held because this cycle could see less than the cycle that engaged it.
    ///
    /// `.fault`, because it means § 3 is holding on a machine it can no longer fully see —
    /// and because the alternative to holding is releasing on a view that shrank, which
    /// reads exactly like a machine that cooled down.
    func thermalEmergencyHeldThroughDegradedCycle(missing: Int, atEngage: Int) {
        emit(
            .fault,
            """
            Thermal emergency latch held: \(missing) of the \(atEngage) curated keys that \
            were answering when it fired have gone silent. A shrinking view of the machine \
            is not evidence that it cooled down, so the latch does not let go on one.
            """
        )
    }

    /// The latch was held because the episode holding began after this cycle took its
    /// reading.
    ///
    /// `.notice` and not `.fault`, which is where it differs from every other "held through"
    /// line here. Nothing is wrong with the machine or with the mechanism: a cycle simply
    /// arrived with a reading of the moment before the emergency started, and the honest
    /// thing to do with a measurement of the wrong episode is not to act on it. The next
    /// cycle judges on a reading taken after the episode began, so this cannot repeat while
    /// the episode lasts — it is a boundary, not a state, and cannot reach the polling-rate
    /// repetition #124's forward constraint is about.
    func thermalEmergencyHeldAcrossEpisodeBoundary() {
        emit(
            .notice,
            """
            Thermal emergency latch held across an episode boundary: the episode now \
            holding engaged after this cycle read its temperatures, so that reading \
            describes the machine before the emergency and is not evidence it has passed.
            """
        )
    }

    /// Telemetry came back after a run of cycles that could read nothing.
    ///
    /// The closing half of the blind path's transition logging. Without it a reader sees a
    /// supervisor go quiet and never sees it recover, which reads as a fault still current
    /// however long ago it cleared.
    func thermalEmergencyTelemetryRecovered(answered: Int) {
        emit(
            .notice,
            """
            Thermal emergency telemetry recovered: \(answered) curated key(s) answering \
            again after a run of unreadable cycles.
            """
        )
    }

    /// § 3's supervisor stopped.
    ///
    /// `LeaseExpirySupervisor` logs its own stop because "a lease enforcer that went quiet
    /// without saying so would be the worst silent failure in the project". The same is
    /// true here and more so: nothing in `Sources/` clears `ThermalEmergencyLatch` except
    /// `ThermalEmergency.cycle()`, and it clears it through `release(ifStill:)` — the
    /// no-argument `release()` has no caller there at all. So a loop that stops while
    /// latched leaves the latch engaged for the life of the process: `acquireLease`
    /// refusing `.thermalEmergencyActive` forever and every snapshot reporting a thermal
    /// emergency that is no longer happening, which is `CLAUDE.md` rule 6 reached through a
    /// lifecycle event. `stop()` deliberately does not clear the latch (releasing § 3 on a
    /// machine nobody has read since it was above its ceiling is worse), so the answer is to
    /// say so loudly and let [#103](https://github.com/blamechris/Aeolus/issues/103) own the
    /// restart.
    func thermalSupervisorStopped(whileLatched: Bool) {
        emit(
            whileLatched ? .fault : .notice,
            whileLatched
                ? """
                Thermal emergency supervisor stopped **while § 3 was latched**. Nothing else \
                releases the latch, so manual fan control stays refused and the snapshot \
                keeps reporting an emergency until the helper restarts.
                """
                : "Thermal emergency supervisor stopped. Nothing is sampling critical "
                    + "temperatures until it starts again."
        )
    }

    /// A cycle produced no reading while the latch was engaged.
    ///
    /// The latch is **held**, not released. Stated in the log because "the override is
    /// still on and we cannot currently see why" is exactly the state an operator would
    /// otherwise mistake for a stuck mechanism.
    func thermalEmergencyHeldThroughUnreadableCycle(detail: String) {
        emit(
            .fault,
            """
            Thermal emergency latch held through an unreadable cycle: \(detail). A cycle \
            that cannot read is never a reason to release.
            """
        )
    }

    /// A cycle produced no reading while the latch was clear.
    ///
    /// Persistent read failure is treated as divergence — restore and report — by the
    /// reclamation watchdog in
    /// [#126](https://github.com/blamechris/Aeolus/issues/126), which owns the reconnect
    /// and the escalation. This line is what makes a single blind cycle visible in the
    /// meantime rather than silent.
    func thermalEmergencyCycleUnreadable(detail: String) {
        emit(
            .notice,
            """
            Thermal emergency cycle could not read a critical temperature: \(detail). The \
            latch is clear and stays clear; persistent failure is #126's to escalate.
            """
        )
    }

    /// One decimal place, so a log line does not carry a firmware float's full mantissa.
    private static func celsius(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    /// Caps the key list so one pathological cycle cannot write an unbounded line into a
    /// root daemon's log. The count above is the number that matters; the names are a hint
    /// for whoever is diagnosing it.
    private static func describe(_ keys: [SMCKey]) -> String {
        let names = keys.map(\.rawValue).sorted()
        guard names.count > 8 else { return names.joined(separator: ", ") }
        return names.prefix(8).joined(separator: ", ") + " and \(names.count - 8) more"
    }
}

// MARK: - docs/SAFETY.md § 5

// § 5's log lines live in an extension rather than in the struct body above, and in **this
// file** rather than a new one.
//
// The extension is because `SafetyLog`'s body crossed SwiftLint's `type_body_length` limit
// — the same pressure that split `ThermalEmergencyReportingTests` out of
// `ThermalEmergencyTests`. An extension's body is measured separately from the type it
// extends, so this is a real fix rather than a suppression.
//
// It is in this file because `emit` is `private`, and `private` in Swift is **file**-scoped.
// Moving these lines to `SafetyLogReclamation.swift` compiled until it did not: every one of
// them failed with "'emit' is inaccessible due to 'private' protection level". The available
// answers were to widen `emit` to `internal` — which would let any file in `AeolusHelper`
// emit an arbitrary line into the safety log, and the whole point of routing every line
// through named methods is that the vocabulary is fixed and reviewable — or to keep the
// extension beside the thing it extends. The encapsulation is worth more than the file
// boundary.
//
// The rule every line below follows: each interpolated value is helper-authored or
// firmware-derived — a fan index, a rounded RPM, a count, or a `FanControlPlaneError`'s own
// description — never client-chosen text. That is what keeps them safe to mark `.public`,
// exactly as this type's header requires.

extension SafetyLog {

    // MARK: - docs/SAFETY.md § 5

    /// The system has taken a fan back.
    ///
    /// `.fault`, for `thermalEmergencyEngaged`'s reason inverted: a client is about to lose
    /// fans it did nothing wrong to lose, and this time Aeolus is not the one taking them.
    /// The line is emitted on the **transition** — `ReclamationLedger.markReclaimed(fanAt:)`
    /// reports it — so a watchdog polling at 1 Hz against a fan the OS is holding says this
    /// once rather than once a second.
    ///
    /// ## The second sentence takes the commanded target, because it used not to
    ///
    /// It read *"Aeolus asked for a speed the firmware is not holding"* unconditionally, and
    /// that is false on the one path this line most needs to be trusted on: `.modeReclaimed`
    /// and `.targetUnreadable` are both decided before
    /// `ReclamationWatchdog.primaryDivergence(of:against:)` consults the commanded target, so
    /// a fan registered and never commanded reaches here with **no speed ever put on the
    /// wire** — and told an operator otherwise, in a `.fault` line, about a fan the user had
    /// asked nothing of. `CLAUDE.md` rule 6 is about not claiming control that is not held;
    /// a diagnostic that invents a request nobody made is the same defect wearing a log
    /// line's clothes, and it sends the reader looking for a write that never happened.
    ///
    /// `commanded` is the last step put on the wire, or `nil` when nothing has been.
    func reclamationDetected(
        fan: Int, divergence: ReclamationDivergence, commanded: CommandedTarget?
    ) {
        let consequence =
            if let commanded {
                """
                Aeolus asked for \(Int(commanded.rpm.rounded())) RPM and the firmware is not \
                holding it
                """
            } else {
                """
                no speed had been commanded on this fan yet, so it was taken back before \
                Aeolus asked it for anything
                """
            }
        emit(
            .fault,
            """
            Reclamation detected on fan \(fan): \(divergence.summary). \(consequence), so \
            the fan is reported as reclaimed by the system from this point.
            """
        )
    }

    /// § 5 declined to re-assert because § 3 is holding.
    ///
    /// The precedence engine's first production ruling, and worth a line of its own: an
    /// operator seeing a divergence with no re-assert attempt is entitled to know that it
    /// was a decision rather than a failure.
    ///
    /// **It does not say the system reclaimed the fan, and an earlier version did.** A
    /// latched machine is exactly where § 5 should expect to find a fan reading automatic:
    /// `ThermalEmergency.fire(_:from:)` restores every fan it bridges. Attributing that to
    /// the OS was a false `.fault` line about Aeolus's own thermal override doing its job.
    func reclamationYieldedToThermalEmergency(fan: Int, divergence: ReclamationDivergence) {
        emit(
            .fault,
            """
            Fan \(fan) diverged — \(divergence.summary) — while the thermal emergency latch \
            is engaged, which is where § 3 leaves a fan it has just bridged and restored. \
            Aeolus does not fight for the fans above the ceiling: a more competent \
            authority, one that can also throttle the SoC, got there first. Handing this fan \
            to § 3 rather than re-asserting, and **not** recording it as reclaimed by the \
            system.
            """
        )
    }

    /// The secondary signal fired: this fan is not reaching the speed it was told to.
    ///
    /// `.notice`, not `.fault`, and that is the whole point of the rework this line came
    /// from. Reaching the secondary signal means the primary converged — `F<n>Md` reads
    /// manual and `F<n>Tg` reads back exactly what was commanded — so Aeolus **is** still in
    /// control of this fan and nothing has been reclaimed. What the user is being told is
    /// that a fan cannot reach its target, which is a hardware observation, not a safety
    /// event. Nothing is restored, no lease is revoked, and `isReclaimedBySystem` stays
    /// false, because all three would be claims that are not true.
    func reclamationFanNotReachingTarget(
        fan: Int, actual: Double, commanded: Double, dwellCycles: Int
    ) {
        emit(
            .notice,
            """
            Fan \(fan) has turned at \(Int(actual.rounded())) RPM against a commanded \
            \(Int(commanded.rounded())) RPM for \(dwellCycles) consecutive cycles. Its \
            target reads back correctly, so Aeolus still holds the fan and the firmware is \
            honouring the request — the fan is not reaching it. Nothing is being taken back.
            """
        )
    }

    /// A fan left the registry while § 5 was part-way through examining it.
    ///
    /// The ordinary cause is a lease ending — released, expired, or torn down by connection
    /// death — during one of the SMC reads this mechanism suspends in. It is not a fault:
    /// the lease core has already restored the fan, and § 5 stopping is correct.
    ///
    /// It is logged because the alternative is silence on a path that used to be a defect.
    /// Acting on the pre-read copy reported an ordinary lease expiry as a reclamation and
    /// revoked whatever lease happened to be live; a reader diagnosing that would need to
    /// see that the abandonment happened at all.
    func reclamationFanReleasedMidExamination(fan: Int, during: String) {
        emit(
            .notice,
            """
            Fan \(fan) was released during \(during), so § 5 abandoned this examination. \
            The lease core owns the restore for a fan that left this way; nothing is \
            recorded as reclaimed.
            """
        )
    }

    /// § 3 latched while § 5 was mid-re-assert, so the re-assert was undone.
    ///
    /// The compensating half of `ReclamationWatchdog.reassert(_:fanAt:attempt:)`. Check and
    /// act cannot be made atomic across two actors, so the ruling is verified again after
    /// the writes and this is what happens when it changed underneath them.
    func reclamationUndoneAfterEmergencyLatched(fan: Int) {
        emit(
            .fault,
            """
            The thermal emergency latch engaged while § 5 was re-asserting fan \(fan), so \
            the re-assert is being undone and the fan returned to automatic control. Level 2 \
            outranks level 3, and nothing else would have corrected this: § 3 empties its \
            own registry as it fires, so its next cycle would not have bridged this fan.
            """
        )
    }

    /// The supervisor was cancelled while § 5 was mid-re-assert, so the write did not happen.
    ///
    /// `ReclamationSupervisor.stop()` cancels without awaiting, so a sweep can resume from a
    /// read inside a supervisor that has already stopped. Re-engaging manual control from
    /// there would leave a fan off Apple's thermal management with nothing left watching it
    /// ([#144](https://github.com/blamechris/Aeolus/issues/144)).
    ///
    /// **This line says what is known and stops there, because it once said more.** It read
    /// "the fan is left on automatic control", which is true of exactly one of the three
    /// divergences that reach here. `ReclamationDivergence.modeReclaimed` is the firmware
    /// reporting automatic control, so for that case it held; `.targetDiverged` is a fan
    /// still *off* automatic control holding a target Aeolus never commanded, and
    /// `.targetUnreadable` is a fan whose state could not be read at all. On a sleep/wake
    /// stop-start catching a diverged fan, the old wording told an operator the fan had been
    /// handed back to the system while it was pinned at a speed nobody chose — a claim of
    /// control state that nothing had verified, which is `CLAUDE.md` rule 6 read from the
    /// other side.
    func reclamationAbandonedOnCancellation(fan: Int) {
        emit(
            .notice,
            """
            § 5 stopped short of re-asserting fan \(fan): the supervisor driving this sweep \
            was cancelled before the write, so nothing was written. The fan is in whatever \
            state the firmware last put it in — which is not necessarily automatic control, \
            since a fan whose target diverged is still off it — and the lease TTL is the \
            surviving backstop until the supervisor is started again.
            """
        )
    }

    /// The mode write landed and the target write did not.
    ///
    /// The worst reachable state in the project — a fan off Apple's thermal management
    /// holding a speed nobody chose — so it is `.fault` and it is followed immediately by a
    /// restore rather than by another attempt.
    func reclamationReassertHalfLanded(fan: Int, detail: String) {
        emit(
            .fault,
            """
            § 5 took fan \(fan) off automatic control and then could not command a target: \
            \(detail). The fan is off Apple's thermal management holding a speed nobody \
            chose, which is not a state to spend another attempt on — restoring it now.
            """
        )
    }

    /// Fans dropped from § 5's registry because the revocation that just ran took their
    /// leases too.
    ///
    /// `revokeEveryLease(because:)` is whole-machine, so every other fan § 5 was watching is
    /// now unleased. Dropping only the fan that diverged left the siblings registered, and
    /// the next cycle re-engaged manual control on a fan with no lease behind it.
    func reclamationSiblingsReleased(fans: [Int]) {
        emit(
            .notice,
            """
            § 5 also stopped watching fan(s) \
            \(fans.map(String.init).joined(separator: ", ")): the revocation that just ran \
            dropped every lease on the machine, so these are unleased and back on automatic \
            control. They are not recorded as reclaimed — they were given up, not taken.
            """
        )
    }

    /// The terminal restore was refused, so the fan may still be pinned.
    ///
    /// The one outcome § 5 cannot fix. ADR 0007's keystone makes the restore the action that
    /// must always be available, and a firmware that refuses it is the case the ADR names as
    /// defeating everything in E5. Saying so is all that is left.
    func reclamationFanMayStillBePinned(fan: Int) {
        emit(
            .fault,
            """
            Fan \(fan) may still be under manual control at a speed Aeolus is no longer \
            tracking: the restore verb was refused, and it is the action every other \
            mechanism here falls back to. Check the fan physically, and see docs/RECOVERY.md.
            """
        )
    }

    /// A bounded re-assert landed on the wire.
    func reclamationReasserted(fan: Int, rpm: Double, attempt: Int, budget: Int) {
        emit(
            .notice,
            """
            Reclamation on fan \(fan): re-asserted \(Int(rpm.rounded())) RPM, attempt \
            \(attempt) of \(budget). The next cycle's read-back decides whether it held.
            """
        )
    }

    /// The re-assert budget is spent and § 5 is falling back.
    func reclamationBudgetExhausted(
        fan: Int, attempts: Int, divergence: ReclamationDivergence
    ) {
        emit(
            .fault,
            """
            Reclamation on fan \(fan) survived \(attempts) re-assert attempt(s) — \
            \(divergence.summary). The budget is spent: the fan goes back to automatic \
            control and every lease is revoked, rather than Aeolus continuing a contest it \
            is losing while reporting a speed nothing is honouring.
            """
        )
    }

    /// A re-assert could not obtain a believable envelope, so it restored instead.
    ///
    /// `docs/SAFETY.md` § 2's closing rule reached from § 5: the only action a fan with
    /// untrusted bounds is subject to is the bounds-free restore verb.
    func reclamationReassertHadNoEnvelope(fan: Int, detail: String) {
        emit(
            .fault,
            """
            Reclamation on fan \(fan): its envelope could not be read or was refused \
            (\(detail)), so there is no range to clamp a re-assert into. Restoring to \
            automatic instead of commanding — a re-assert without bounds is not a write \
            this project makes.
            """
        )
    }

    /// Divergence on a fan registered but not yet commanded, inside the registration grace.
    ///
    /// `.notice` rather than `.fault`: the ordinary reading of this line is that a client
    /// has just been granted a fan and the first `F<n>Tg` write has not followed yet, so the
    /// firmware has not had a chance to agree that the fan is Aeolus's. Nothing is wrong
    /// until the grace runs out, and if it does, `reclamationHadNothingToReassert(fan:)`
    /// says so at the level that finding deserves.
    ///
    /// The transition only — one line per grace, not one per cycle, which is #124's
    /// constraint on a 1 Hz supervisor.
    func reclamationAwaitingItsFirstCommand(fan: Int, divergence: ReclamationDivergence) {
        emit(
            .notice,
            """
            Fan \(fan) is under manual control with no target commanded on it yet, and \
            \(divergence.summary). Waiting up to \
            \(ReclamationLimits.blindCyclesBeforeDivergence) cycles for the first command \
            before treating that as a reclamation.
            """
        )
    }

    /// Divergence with nothing to re-assert to.
    func reclamationHadNothingToReassert(fan: Int) {
        emit(
            .notice,
            """
            Reclamation on fan \(fan) before any target was commanded on it. There is no \
            speed to re-assert, so the fan goes back to automatic control and the lease is \
            revoked.
            """
        )
    }

    /// A write on § 5's path did not land.
    ///
    /// `detail` is helper-authored — a `FanControlPlaneError`'s own description — never
    /// client-chosen text, which is what keeps the whole line safe to mark `.public`.
    func reclamationWriteFailed(verb: String, fan: Int, detail: String) {
        emit(
            .fault,
            """
            Reclamation watchdog could not \(verb) fan \(fan): \(detail). The attempt is \
            spent; the budget is what bounds the trying, and restore is the floor.
            """
        )
    }

    /// A cycle could not read one held fan. The first of a run only — see
    /// `ReclamationWatchdog.cycleCouldNotSee(fanAt:detail:)`.
    func reclamationCycleUnreadable(fan: Int, detail: String) {
        emit(
            .notice,
            """
            Reclamation watchdog could not read fan \(fan): \(detail). One unreadable cycle \
            changes nothing; \(ReclamationLimits.blindCyclesBeforeDivergence) in a row is \
            divergence.
            """
        )
    }

    /// A held fan became readable again after a run of blind cycles.
    ///
    /// The closing half of "log the transition, not the state". Without it a reader sees a
    /// fan go quiet and never sees it come back.
    func reclamationTelemetryRecovered(fan: Int, afterCycles: Int) {
        emit(
            .notice,
            "Reclamation watchdog can read fan \(fan) again after \(afterCycles) "
                + "unreadable cycle(s)."
        )
    }

    /// Read failure on a held fan has become persistent, and is now treated as divergence.
    ///
    /// ADR 0007's hole 2: `docs/SAFETY.md` § 5 covers divergence of values and nothing
    /// covered the inability to obtain them, while a lease keeps the fans pinned.
    func reclamationBlindnessEscalated(fan: Int, afterCycles: Int, detail: String) {
        emit(
            .fault,
            """
            Reclamation watchdog has not read fan \(fan) for \(afterCycles) consecutive \
            cycles: \(detail). Being unable to read is divergence too — attempting a \
            reconnect, then restoring to automatic whatever it answers.
            """
        )
    }

    /// The reconnect attempt returned without throwing.
    ///
    /// Deliberately **not** phrased as a recovery. Nothing has been read since, so the only
    /// claim available is that the call did not throw — and the watchdog restores anyway.
    func reclamationReconnected(fan: Int) {
        emit(
            .notice,
            """
            Reclamation watchdog reconnected to the SMC while escalating fan \(fan). That \
            the call returned is not evidence that reading works; only the next read is, \
            and the restore does not wait for it.
            """
        )
    }

    /// The reconnect attempt failed, or this build has no reconnect at all.
    func reclamationReconnectFailed(fan: Int, detail: String) {
        emit(
            .fault,
            """
            Reclamation watchdog could not reconnect to the SMC while escalating fan \
            \(fan): \(detail). Restoring to automatic regardless — the restore verb needs \
            no working read, which is the whole reason it is the terminal action.
            """
        )
    }

    /// A fan went back to automatic control because the helper could not see it.
    func reclamationRestoredBlindFan(fan: Int) {
        emit(
            .fault,
            """
            Fan \(fan) restored to automatic control because the helper cannot read its \
            state. A pinned fan on a machine nobody is watching is the state a lease exists \
            to prevent, so the lease is revoked rather than left to its TTL.
            """
        )
    }

    /// A fan the ledger had given up on is Aeolus's again.
    ///
    /// Deliberately says neither "reclaimed" nor "blind": `ReclamationLedger` records either
    /// cause and this line is emitted when *whichever* one was recorded is cleared. Naming
    /// the reclamation here would attribute a blind episode's recovery to the operating
    /// system, which is the same conflation #140 removed from `isReclaimedBySystem`.
    func reclamationResolved(fan: Int) {
        emit(
            .notice,
            "Fan \(fan) is no longer reported as taken from Aeolus."
        )
    }

    /// § 5's supervisor stopped.
    ///
    /// `.fault` when fans are still being watched, for `thermalSupervisorStopped(whileLatched:)`'s
    /// reason: nothing else notices a reclamation, so a loop that stops while fans are held
    /// leaves them pinned with no mechanism watching for the firmware taking them back.
    func reclamationSupervisorStopped(fansHeld: Int) {
        emit(
            fansHeld > 0 ? .fault : .notice,
            fansHeld > 0
                ? """
                Reclamation watchdog supervisor stopped with \(fansHeld) fan(s) still under \
                manual control. Nothing is now watching for the system taking them back, and \
                the lease TTL is the only surviving backstop until the helper restarts.
                """
                : "Reclamation watchdog supervisor stopped. No fan is under manual control, "
                    + "so there is nothing it would have been watching."
        )
    }
}

// MARK: - docs/SAFETY.md § 4

// § 4's lines, in a third extension for the two reasons the § 5 block above states: the
// struct body is already at SwiftLint's `type_body_length` limit, and `emit` is `private`,
// which in Swift is file-scoped — so these have to be *here* and cannot be *in the body*.
//
// They are `SafetyLog` lines rather than `LeaseLog` ones because they answer this log's
// question rather than that one's. A reader looking at § 4 is not asking "why are the fans
// not where I left them" — `releaseEveryLease()` already writes that answer through
// `LeaseLog`. They are asking whether the mechanism that hands the fans back before a sleep
// ran at all, which is *"was the mechanism that protects them actually watching?"*.
//
// The interpolation rule is the same and is met the same way: a `Duration` this module chose
// and an error's own description. Nothing a client wrote reaches a line here.

extension SafetyLog {

    /// The system is going to sleep and is waiting on this process.
    ///
    /// `.notice`, and it is the line that makes the budget legible afterwards: an operator
    /// reading a `.fault` five seconds later needs to be able to see when the clock started.
    func sleepIsComing(budget: Duration) {
        emit(
            .notice,
            """
            System will sleep: dropping every lease and returning every fan to automatic \
            control before allowing the power change. The system waits at most \(budget) \
            for this, after which it is allowed to sleep regardless and the lease TTL is \
            the only surviving backstop.
            """
        )
    }

    /// The machine-wide keystone restore landed before the sleep.
    func handedEveryFanBackBeforeSleep() {
        emit(
            .notice,
            "Every fan returned to automatic control before sleep, and the Apple Silicon "
                + "force key cleared with them."
        )
    }

    /// The machine-wide keystone restore did not land.
    ///
    /// `.fault` — `SafetyLog.Level`'s own definition of the level is *"§ 3 engaged or
    /// released, or a write on its path did not land"*, and this is the second half of that
    /// for § 4. On a build with no SMC write path this fires on **every** sleep with
    /// `controlPathNotBuilt`, truthfully: the helper really cannot hand a fan back, and a
    /// log that said otherwise would be the claim `FanWriteCapability` exists to stop making.
    func couldNotHandEveryFanBackBeforeSleep(_ error: any Error) {
        emit(
            .fault,
            """
            The machine-wide restore before sleep did not land: \
            \(String(describing: error)). Any fan still off automatic control stays there \
            across the sleep, and the lease TTL is what takes it back.
            """
        )
    }

    /// The system was allowed to sleep with the handback complete.
    func allowingSleepAfterHandback() {
        emit(
            .notice,
            "Allowing the system to sleep: the handback finished inside its budget."
        )
    }

    /// The budget ran out with the handback still in flight, and the system was allowed to
    /// sleep anyway.
    ///
    /// `.fault`, and it is the line § 4 exists to be able to write. Holding the sleep open
    /// indefinitely is not the safer option — the kernel would sleep the machine on its own
    /// timeout and this process would learn nothing — so the helper gives up the wait
    /// deliberately and says so, which is the difference between a bound and a hang.
    ///
    /// **This line named § 1's TTL as the backstop until a review showed it could not be.**
    /// `handBackEveryFan()` empties the lease table before it restores, so by the time this
    /// line can be written there is no lease left to expire. Corrected in place rather than
    /// quietly rewritten: an operator reading a root daemon's log on a hot laptop is owed the
    /// mechanism that will actually act, and there is no worse place for a comforting name.
    /// `SystemPowerLimits.acknowledgementBudget` carries the full account.
    ///
    /// - Parameters:
    ///   - budget: how long the handback was waited for before the wait was given up.
    ///   - abandoned: the fans recorded as abandoned handbacks by decision D17, named rather
    ///     than counted so the line identifies which fan to go and look at.
    func allowingSleepWithHandbackOutstanding(
        after budget: Duration, abandoning abandoned: Set<Int>
    ) {
        emit(
            .fault,
            """
            Allowing the system to sleep with the handback still outstanding after \
            \(budget). Fan(s) \(Self.describeFans(abandoned)) may cross the sleep still under \
            manual control, and are now refused a new lease durably. What can still act: \
            the parked restore may yet land, § 3 takes any such fan to full scale if it \
            comes back above the thermal ceiling, and startup reconciliation returns it to \
            automatic at the next helper start. § 1's TTL cannot — this handback dropped \
            every lease before it wrote. See docs/SAFETY.md § 4 and docs/RECOVERY.md.
            """
        )
    }

    /// Fan indices for a log line, or a phrase for the empty set.
    ///
    /// "none" rather than an empty list, because the empty case is meaningful here: the
    /// budget expired with nothing outstanding at the lease core, which means whatever is
    /// parked is the machine-wide keystone rather than a fan this helper held.
    private static func describeFans(_ fans: Set<Int>) -> String {
        fans.isEmpty
            ? "none (the keystone restore is what is outstanding)"
            : fans.sorted().map(String.init).joined(separator: ", ")
    }

    /// The machine woke, and the helper wrote nothing.
    ///
    /// Logged precisely because nothing happened. `docs/SAFETY.md` § 4's *"After wake:
    /// **nothing.** The helper does not re-assert"* is a claim about an absence, and an
    /// absence with no line in `log show` is indistinguishable from a helper that never
    /// heard the wake at all.
    func wokeWithoutWriting() {
        emit(
            .notice,
            """
            System woke. Writing nothing: a client that still wants the fans asks for them \
            again through the ordinary acquisition path, with the same authorisation check, \
            the same bounds gate and a fresh lease.
            """
        )
    }

    /// This process cannot hear the system's power events at all.
    ///
    /// `.fault`, because § 4 is now absent rather than degraded: nothing will hand the fans
    /// back before a sleep, and the TTL — which counts time asleep only if `ContinuousClock`
    /// advances across it — is all that is left.
    /// This process was never given anything to hear the system's power events through.
    ///
    /// `.fault`, and the same level as a refused registration deliberately: the consequence
    /// is identical — nothing returns the fans to automatic control before a sleep — and a
    /// quieter level would make the *absence* of § 4 the one state in this mechanism that
    /// does not announce itself. The sentence differs because the remedy does: a refusal is
    /// the system's answer, and this is the composition root's.
    func noSystemPowerObserver() {
        emit(
            .fault,
            """
            This helper was composed with no system power observer, so § 4 is absent rather \
            than degraded: nothing will return the fans to automatic control before this \
            machine sleeps. Every shipped daemon is built by HelperComposition.production, \
            which supplies one; a build reaching this line is a wiring fault, not a machine \
            that refused.
            """
        )
    }

    func systemPowerObserverUnavailable(_ error: any Error) {
        emit(
            .fault,
            """
            Could not register for system power notifications: \
            \(String(describing: error)). Nothing will return the fans to automatic control \
            before this machine sleeps, and § 1's TTL is the only remaining path back.
            """
        )
    }
}
