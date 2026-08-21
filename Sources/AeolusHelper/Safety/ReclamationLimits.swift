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
enum ReclamationDivergence: Sendable, Hashable {

    /// `F<n>Md` reports automatic for a fan Aeolus is holding. The unambiguous signal.
    case modeReclaimed

    /// `F<n>Tg` could not be read. Divergence, never "no divergence" — see
    /// `FanRPMReadback`.
    case targetUnreadable(reason: String)

    /// `F<n>Tg` reads back something other than what was commanded. § 5's primary signal.
    case targetDiverged(commanded: Double, readBack: Double)

    /// `F<n>Ac` has been short of the commanded target for the whole dwell. § 5's secondary
    /// signal, and the only one with a memory.
    case actualShortfall(actual: Double, commanded: Double, dwellCycles: Int)

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
        case .actualShortfall(let actual, let commanded, let dwellCycles):
            return """
                it has turned at \(Int(actual.rounded())) RPM against a commanded \
                \(Int(commanded.rounded())) RPM for \(dwellCycles) cycles
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
    /// Five, which is five seconds at the supervisor's 1 Hz. A fan spinning up from idle to
    /// maximum is the case this must not fire on, and § 8's ramp cap is 200 RPM/s against a
    /// 1350–5777 RPM span — a 22-second full-scale ramp — so a dwell alone cannot separate
    /// them and is not asked to. What separates them is that a ramp's *target* reads back
    /// correctly throughout, which is the primary signal converging; this dwell only stops
    /// the secondary from firing on the ordinary lag while it does.
    static let actualDwellCycles = 5

    /// How many times § 5 will try to take a fan back before falling back to restore.
    ///
    /// Three. Each attempt is a fresh envelope read plus two writes, so the budget bounds
    /// both the fighting and the reads it costs. The point of a budget rather than a retry
    /// loop is that a machine whose firmware silently discards every write must end up on
    /// automatic control with the user told, not in a contest it cannot win —
    /// `ScriptedControlPlane.WriteBehaviour.reverted` is exactly that machine.
    static let reassertAttemptBudget = 3

    /// How many consecutive unreadable cycles make a fan's read failure persistent.
    ///
    /// Three, so a single missed read — or two — changes nothing. Taking a fan from a
    /// client because one read failed would be over-firing on noise, and this mechanism has
    /// the luxury of waiting that § 3 does not: § 3 is watching a temperature that can rise
    /// in three seconds, and this is watching a fan that is already where it was put.
    static let blindCyclesBeforeDivergence = 3
}
