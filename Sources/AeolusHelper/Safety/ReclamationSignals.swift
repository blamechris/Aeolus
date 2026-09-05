import FanKit

// `docs/SAFETY.md` § 5's two classifiers: given one `FanControlState` read back from the
// firmware and the `CommandedTarget` last put on the wire, has the fan been taken back, and
// is it turning as fast as it was told to.
//
// Split from `ReclamationWatchdog.swift` for `ReclamationLimits.swift`'s reason, and it is
// the same reason that bounds what may follow them here: both are `static` and pure, so
// neither reads or writes the actor's `held` registry and moving them costs none of the
// read-then-mutate reasoning that keeps `examine(fanAt:)` checkable. Everything still in
// that file either touches `held` or is `held` — see the `- Note:` on the actor, and
// [#128](https://github.com/blamechris/Aeolus/issues/128) for the rest of this space.
//
// They stay `static` members of `ReclamationWatchdog` rather than becoming a free namespace
// so that `Self.primaryDivergence(of:against:)` still reads as § 5 asking § 5 a question,
// and so every `primaryDivergence(of:against:)` reference in the surrounding prose and in
// `SafetyLog` still names the same symbol. `private` widens to module-internal as the price
// of the split, which reaches no state: there is none here to reach.
extension ReclamationWatchdog {

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
    static func primaryDivergence(
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
    static func actualShortfall(
        of state: FanControlState, against commanded: CommandedTarget?
    ) -> (actual: Double, commanded: Double)? {
        guard let commanded, case .rpm(let actual) = state.actualRPM else { return nil }
        let tolerance = commanded.rpm * ReclamationLimits.actualToleranceFraction
        guard commanded.rpm - actual > tolerance else { return nil }
        return (actual: actual, commanded: commanded.rpm)
    }
}
