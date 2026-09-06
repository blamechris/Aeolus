// The values `docs/SAFETY.md` § 5 reasons in: why a fan is believed lost, and the
// numbers that decide when. Split from `ReclamationWatchdog.swift` because they are
// values rather than the mechanism — neither touches the actor's `private` state, so
// moving them costs none of the reentrancy reasoning that keeps `ThermalEmergency`
// whole. See [#128](https://github.com/blamechris/Aeolus/issues/128).

// MARK: - Why a fan is believed lost

/// What made this mechanism decide the system had taken a fan back.
///
/// An enum rather than a string, because two of these are asserted on by tests and all of
/// them end up in a `.fault` log line an operator reads. A bare "divergence detected" would
/// make "the target read back wrong" indistinguishable from "the target could not be read
/// at all", and those call for different diagnosis.
///
/// **Every case here is a *primary*-signal finding, and the secondary signal deliberately
/// has none.** There was an `actualShortfall` case, and it was the file's worst defect: it
/// let a sustained actual-RPM shortfall travel the same path as a genuine reclamation and
/// reach restore-plus-revoke on a fan whose `F<n>Tg` read back exactly what Aeolus
/// commanded. Reaching the secondary signal at all *means* the firmware is holding our
/// target — `ReclamationWatchdog.examine(fanAt:)` returns early on any primary divergence —
/// so a shortfall is a fan that cannot reach its speed, not a fan that was taken.
/// `ReclamationWatchdog.reportShortfall(_:fanAt:)` carries it, it emits its own log line,
/// and it never constructs one of these. Removing the case is what stops the two ever
/// sharing a path again.
enum ReclamationDivergence: Sendable, Hashable {

    /// `F<n>Md` reports automatic for a fan Aeolus is holding. The unambiguous signal.
    case modeReclaimed

    /// `F<n>Tg` could not be read. Divergence, never "no divergence" — see
    /// `FanRPMReadback`.
    case targetUnreadable(reason: String)

    /// `F<n>Tg` reads back something other than what was commanded. § 5's primary signal.
    case targetDiverged(commanded: Double, readBack: Double)

    /// One line for a log, and the reason this type is not a `String` in the first place.
    var summary: String {
        switch self {
        case .modeReclaimed:
            return "the firmware reports it on automatic control"
        case .targetUnreadable(let reason):
            return "its target could not be read (\(reason))"
        case .targetDiverged(let commanded, let readBack):
            return """
                its target reads back \(Int(readBack.rounded())) RPM against the \
                \(Int(commanded.rounded())) RPM last commanded
                """
        }
    }
}

// MARK: - The numbers

/// § 5's constants, with the reasoning that picked each one.
///
/// Compiled in and not configurable, for `SMCReadScheduler.maxKeysPerTurn`'s reason and
/// `CLAUDE.md` rule 5's: a configuration file that could widen a tolerance or lengthen a
/// dwell could stop this mechanism firing, and there is no safety limit worth having that a
/// settings payload can defeat.
///
/// These live in `AeolusHelper` rather than in `FanKit` beside `ThermalCeiling`, because no
/// client needs them: a ceiling is rendered in the UI and a re-assert budget is not.
enum ReclamationLimits {

    /// How far `F<n>Tg` may read back from what was commanded before it counts as
    /// divergence, in RPM.
    ///
    /// One RPM, which is a decode tolerance rather than a control tolerance. `F<n>Tg` is a
    /// firmware float and a value written as 2,400 may read back as 2,399.98; anything
    /// larger than this is the firmware holding a *different* number, not the same number
    /// rendered differently. Deliberately tight: this is the signal § 5 rests on, and a
    /// generous tolerance here is a reclamation the watchdog sleeps through.
    static let targetToleranceRPM: Double = 1

    /// How far below the commanded target `F<n>Ac` may sit before the dwell starts
    /// counting, as a fraction of the target.
    ///
    /// `docs/SMC-RESEARCH.md` measured `F0Tg` and `F0Ac` tracking about **1 %** apart on a
    /// slow warm-up on this project's development machine — 1350 → 2195 against
    /// 1343 → 2166. Twenty per cent is far outside that, and it needs to be: no write has
    /// ever been performed on this hardware, so the step response is unobserved and this
    /// signal is corroboration rather than evidence. The primary signal is the one that
    /// carries the mechanism.
    static let actualToleranceFraction: Double = 0.20

    /// How many consecutive cycles the actual speed must be short before the secondary
    /// signal fires.
    ///
    /// Five, which is five seconds at the supervisor's 1 Hz.
    ///
    /// **An earlier version of this comment had the causality backwards, and it was
    /// load-bearing.** It said a ramp is separated from a reclamation by "the primary signal
    /// converging", which suppresses nothing: the primary converging is the *precondition*
    /// for the secondary being evaluated at all, since
    /// `ReclamationWatchdog.examine(fanAt:)` returns early on primary divergence. A
    /// correctly-reading `F<n>Tg` is what gets you here, not what protects you.
    ///
    /// What this dwell actually buys is that a fan briefly short of its target — a ramp, a
    /// gust, one slow sample — is not reported as one that cannot reach it. Five seconds is
    /// long against the ~1 % steady-state coupling `docs/SMC-RESEARCH.md` measured and short
    /// against § 8's 22-second full-scale ramp, so a full-scale ramp under the governor
    /// **will** cross it and be reported. That is now acceptable, because the report is all
    /// that happens: since the shortfall path no longer reaches the terminal action, a line
    /// saying a fan is below its commanded speed during a long ramp is accurate rather than
    /// harmful. It was not acceptable when that path restored the fan and revoked the lease.
    ///
    /// ## The post-wake case, measured
    ///
    /// **A fan at rest reads exactly 0**, so any commanded target is a 100 % shortfall and this
    /// dwell is crossed with nothing wrong. On `Mac16,5` — read-only capture, 2026-09-05, see
    /// `docs/SMC-RESEARCH.md` — `F0Ac` and `F1Ac` read a true 0 for the whole of every dark wake
    /// and for **38 s after the user reopened the lid**, then took about **4 s** to spin up, the
    /// first non-zero sample being 109.13 RPM. So the false window is 38 s plus a spin-up on a
    /// full wake, and is bounded at roughly four seconds once the fan is turning.
    ///
    /// Anyone tuning this number should know that case exists rather than rediscover it, and
    /// should read the emitted line as the fan **having not reached** its target rather than
    /// being unable to: "cannot" is a hardware diagnosis, and a fan that has not started yet is
    /// not one.
    ///
    /// **This is a read-only observation of Apple's own controller, not a step response.** No
    /// write selector was issued at any point in that capture and this build has no write path,
    /// so nothing here may be quoted as Aeolus commanding a fan — and nothing here re-tunes this
    /// constant or any other. `docs/SAFETY.md` § 5 carries the same numbers.
    static let actualDwellCycles = 5

    /// How many times § 5 will try to take a fan back before falling back to restore.
    ///
    /// Three. Each attempt is a fresh envelope read plus two writes, so the budget bounds
    /// both the fighting and the reads it costs. The point of a budget rather than a retry
    /// loop is that a machine whose firmware silently discards every write must end up on
    /// automatic control with the user told, not in a contest it cannot win —
    /// `ScriptedControlPlane.WriteBehaviour.reverted` is exactly that machine.
    ///
    /// **It counts writes attempted, not sweeps entered.** `ReclamationWatchdog` spends an
    /// attempt at the point it decides to re-assert, which is before the envelope read that
    /// suspends, so an exit taken between the two has to give it back or the budget starts
    /// measuring something else. The cancellation guard in
    /// `ReclamationWatchdog.reassert(_:fanAt:attempt:)` is the only such exit and it refunds;
    /// every other early return there has either already written or has resolved the fan.
    /// The distinction is what stops repeated sleep/wake stop-starts exhausting a budget
    /// without a single `F<n>Md` reaching the firmware.
    static let reassertAttemptBudget = 3

    /// How many consecutive cycles § 5 may fail to confirm a fan is still Aeolus's before
    /// that becomes divergence.
    ///
    /// Three, so a single missed read — or two — changes nothing. Taking a fan from a
    /// client because one read failed would be over-firing on noise, and this mechanism has
    /// the luxury of waiting that § 3 does not: § 3 is watching a temperature that can rise
    /// in three seconds, and this is watching a fan that is already where it was put.
    ///
    /// **Two consumers, one question.** `ReclamationWatchdog.cycleCouldNotSee(fanAt:detail:)`
    /// counts cycles that could not read the fan at all;
    /// `ReclamationWatchdog.gracedBeforeItsFirstCommand(_:of:fanAt:)` counts cycles that read
    /// it but could not yet see it as manual-with-a-target, in the window between
    /// `engageManualControl` and the first `F<n>Tg` write. Both are "this mechanism cannot
    /// confirm the fan is ours", and both spend the same currency — a fan held for a bounded
    /// number of seconds before it is restored and reported — so a second constant would be
    /// two numbers answering one question, free to drift apart.
    static let blindCyclesBeforeDivergence = 3
}
