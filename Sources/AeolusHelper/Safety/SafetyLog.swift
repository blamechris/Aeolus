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
    /// true here and more so: `ThermalEmergency.cycle()` is the **only** caller of
    /// `ThermalEmergencyLatch.release()` anywhere in `Sources/`, so a loop that stops while
    /// latched leaves the latch engaged for the life of the process — `acquireLease`
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

    // MARK: - docs/SAFETY.md § 5

    /// The system has taken a fan back.
    ///
    /// `.fault`, for `thermalEmergencyEngaged`'s reason inverted: a client is about to lose
    /// fans it did nothing wrong to lose, and this time Aeolus is not the one taking them.
    /// The line is emitted on the **transition** — `ReclamationLedger.markReclaimed(fanAt:)`
    /// reports it — so a watchdog polling at 1 Hz against a fan the OS is holding says this
    /// once rather than once a second.
    func reclamationDetected(fan: Int, divergence: ReclamationDivergence) {
        emit(
            .fault,
            """
            Reclamation detected on fan \(fan): \(divergence.summary). Aeolus asked for a \
            speed the firmware is not holding, so the fan is reported as reclaimed by the \
            system from this point.
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

    /// A fan that was reported as reclaimed is Aeolus's again.
    func reclamationResolved(fan: Int) {
        emit(
            .notice,
            "Fan \(fan) is no longer reported as reclaimed by the system."
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
