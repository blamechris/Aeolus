// Whether the helper reports a fan cleared back to automatic control: one definition, for every
// client that has to say so. Lifted out of `fanctl`'s `SafeState` for
// [#153](https://github.com/blamechris/Aeolus/issues/153), because the app is about to need the
// same judgement, and two copies would be two definitions of "cleared". The day they disagreed,
// one client would report fans fine that the other reported pinned.
//
// A move, not a redesign: the classification, its three classes and the reasoning for each are
// what `SafeState` decided on review of #321. `SafeState.clearance(of:)`, `SafeState.Clearance`
// and `SafeState.isCleared(_:)` remain, as delegates to what is here, so `fanctl auto` asks the
// same question it always did.
//
// In `FanKit` because it is a pure function of `ManualControlAvailability` and `FanState`, both of
// which live here, and because this target is the one the app, `fanctl` and `AeolusXPC` all link.
// `Sources/AeolusHelper` links it too and never calls this: nothing here decides what the helper
// does, only what a client may conclude from what the helper already reported.

extension ManualControlAvailability {

    /// What a fan's availability says about whether the helper has cleared it.
    public enum Clearance: Sendable, Hashable {
        /// A reason that waiting will not change, whatever the mode reads.
        case durable
        /// The helper has not established this fan's mode, or a restore of it is outstanding.
        /// Worth looking again.
        case pending
        /// Says nothing about whether the fan is back under automatic control: the mode decides.
        case silent
    }

    /// Classifies this availability.
    ///
    /// - **`durable`**: `foreignManualControl` ("nothing in Aeolus will change it, because
    ///   nothing in Aeolus put the fan there") and `restoreToAutomaticFailed` ("the firmware
    ///   never took the write").
    /// - **`pending`**: the reasons that mean the helper has not established the fan's mode, or
    ///   a restore is outstanding: `releaseInProgress`, `handbackUnconfirmed`,
    ///   `restoreToAutomaticUnconfirmed`, `systemSleeping`, `unknown` (which the type says is
    ///   never to be treated as available) and `supervisorBlind`. A blind fan's state is
    ///   *unknown*, not manual, so it is pending and not durable, even though reconciliation can
    ///   leave it so for the life of the process. A snapshot carries it for that reconciliation
    ///   refusal and, on a helper that can write, for a fan whose mode did not read on that
    ///   snapshot ([#360](https://github.com/blamechris/Aeolus/issues/360)); never for § 5's
    ///   ledger (#355). So a fan § 5 gave up blind that is *still* unreadable reads `automatic`
    ///   (#178's fallback) with `supervisorBlind` beside it, and is not cleared: `fanctl auto`
    ///   sends its restore and exits 8 rather than 0, which ADR 0013 rejects under "Exit 0 on
    ///   the mode alone". On a helper that cannot write, such a fan reads `writePathNotBuilt`,
    ///   which is silent: #178's gap.
    /// - **`silent`**: the reasons about manual control being *granted*, not about the fan:
    ///   `writePathNotBuilt` (every fan on today's helper), `boundsImplausible`,
    ///   `leaseHeldByAnotherClient` (a lease is judged from `SystemSnapshot.activeLease`),
    ///   `selfRenewalNotBuilt`, `noThermalTelemetry` and `reclaimedBySystem` (which no helper
    ///   on `main` publishes as an availability; `FanState.isReclaimedBySystem` carries the
    ///   fact). `available` is silent too: it says manual control could be taken, which is not a
    ///   statement about the mode.
    ///
    /// **Exhaustive over `Reason`, with no `default:` arm,** so a reason added to the vocabulary
    /// is a compile error here rather than a quiet "silent": the classification decides whether
    /// a client waits at all, or stops waiting, and a new reason has to be decided.
    /// `ManualControlAvailabilityClearanceTests` records what that holds and what it does not.
    public var clearance: Clearance {
        guard case .unavailable(let reason) = self else { return .silent }
        switch reason {
        case .foreignManualControl,
            .restoreToAutomaticFailed:
            return .durable
        case .releaseInProgress,
            .handbackUnconfirmed,
            .restoreToAutomaticUnconfirmed,
            .supervisorBlind,
            .systemSleeping,
            .unknown:
            return .pending
        case .writePathNotBuilt,
            .boundsImplausible,
            .leaseHeldByAnotherClient,
            .selfRenewalNotBuilt,
            .noThermalTelemetry,
            .reclaimedBySystem:
            return .silent
        }
    }
}

extension FanState {

    /// Whether the helper reports this fan as back under automatic control: its mode reads
    /// automatic **and** its availability is not a reason the helper has not cleared it.
    ///
    /// **Both fields, because the mode alone is not enough.** The helper reports an unreadable
    /// `F<n>Md` as `automatic` ([#178](https://github.com/blamechris/Aeolus/issues/178)), and on
    /// Intel the register does not exist, so `automatic` is also what a fan reads when nobody
    /// has looked. The availability is the field that says "the helper has not cleared this
    /// fan", and it says so whatever the mode reads.
    ///
    /// `.silent` is the only clearance that lets the mode speak for itself. Anything else is the
    /// helper saying something about the fan that a mode of `automatic` does not contradict,
    /// because `automatic` is also what an unread mode is reported as.
    ///
    /// **Still the helper reporting, not the fan being so.** A client that renders this says
    /// "the helper reports", never "the fan is". And it is about one fan: whether anything is
    /// leased is `SystemSnapshot.activeLease`, a separate fact this does not read.
    ///
    /// Named for clearance rather than for the mode: a name like `isReportedAutomatic` reads as
    /// `mode == .automatic`, which is the one reading this property exists to refuse.
    public var isClearedToAutomatic: Bool {
        mode == .automatic && manualControlAvailability.clearance == .silent
    }
}
