/// One read verb: a fan's firmware-declared bounds, `F<n>Mn` and `F<n>Mx`.
///
/// ## Why a protocol of its own
///
/// So that `LeaseAuthority` can read a fan's bounds at grant time
/// ([#270](https://github.com/blamechris/Aeolus/issues/270)) without being handed anything
/// that reads a fan's mode, reconnects the SMC or commands a fan. It is the argument
/// `FanModeSensing` and `SMCConnectionRecovering` make, in the same direction: the lease core
/// needs one answer, and a seam that could also do more would be authority it has no use for
/// and a later edit could quietly spend.
///
/// `FanStateSensing` refines this, so every plane answers it and no separate production type
/// is needed — the split is about what a consumer can be given, not about what the hardware
/// offers. `Sendable`, because the lease core holds one across an actor boundary.
///
/// **An envelope is not a permit.** What the lease core does with the answer is judge it, with
/// `FanState.controlEnvelope(declaredMinimum:declaredMaximum:)`; turning a `FanEnvelope` into
/// the value a write verb takes is `apply`'s and § 5's, and `LeaseAuthorityAccessTests` holds the
/// lease core's files to naming neither that value nor the property that mints it.
protocol FanEnvelopeReading: Sendable {

    /// Reads one fan's firmware-declared envelope, `F<n>Mn` and `F<n>Mx`.
    ///
    /// Reported exactly as declared. Whether an envelope is *plausible* is
    /// `FanControlEnvelope.validating(...)`'s judgement, not this seam's, and this seam must
    /// not pre-empt it by rounding, flooring or omitting a declaration it dislikes.
    ///
    /// - Important: **A declared minimum of zero is accepted, not refused.** Some firmware
    ///   really does say it — `docs/RECOVERY.md` records that fans stopping at idle is
    ///   normal on many Macs — so refusing to lease such a fan would deny manual control on
    ///   legitimate hardware. What keeps `CLAUDE.md` rule 3 true there is the *floor*:
    ///   targets clamp to `[max(F0Mn, minimumManualRPM), F0Mx]`, so zero is uncommandable
    ///   whatever the firmware declares. The plausibility gate binds the **maximum**
    ///   instead. This paragraph exists because an earlier draft of this comment said the
    ///   opposite, and an implementer honouring it would have added a `> 0` refusal and
    ///   regressed every Mac whose fans idle at rest.
    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope
}
