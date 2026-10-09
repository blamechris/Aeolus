// What § 5 keeps per fan. Split from `ReclamationWatchdog.swift` when ADR 0009 D2
// ([#180](https://github.com/blamechris/Aeolus/issues/180)) pushed that file past SwiftLint's
// 1000-line error, and it is the third split of the kind that file's `- Note:` allows: one that
// widens no state. This is a type, not state. `held` — the only place a `HeldFan` means
// anything — stays `private` to the actor, so moving the declaration from `private` to
// module-internal lets another file construct a value that nothing will accept, and reaches
// nothing the actor owns. [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest.

extension ReclamationWatchdog {

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
    ///
    /// ## Built once per registration
    ///
    /// Moved here from `manualControlEngaged(_:)` with #180, for the line budget this file's
    /// header describes. That method creates an entry only when there is not one already, so
    /// registering a fan twice without an intervening release keeps its `commanded` target,
    /// its grace counter, its re-assert attempts and its blind-cycle count. It used to build a
    /// fresh `HeldFan` unconditionally, and that was two defects rather than one:
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
    /// The refill point is a genuine release, and each one drops the entry:
    /// `manualControlReleased(fanAt:)` for a lease that ended, `finaliseRelease(fanAt:because:)`
    /// for a fan § 5 gave up, and `restoreAndForget(fanAt:)` for a fan § 3 holds or no live
    /// lease covers. A registration after any of them starts fresh, which is the case a fresh
    /// `HeldFan` is actually for.
    ///
    /// `ReclamationRegistrationWindowTests.reRegisteringMidGraceDoesNotRefillIt` and
    /// `.reRegisteringKeepsWhatWasCommanded` are the two halves.
    struct HeldFan: Sendable {
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
