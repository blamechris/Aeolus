/// Whether the conformer behind the seam can put a write on the wire at all.
///
/// ## Why this exists, and why it is not a literal
///
/// Until this type, "this build cannot write" was spelled as a hard-coded refusal:
/// `ReadOnlyFanAuthority` threw `.manualControlUnavailable(reason: .writePathNotBuilt)` from
/// every control verb, and `ReadOnlyFanReport` wrote the same reason into every fan's
/// availability. That was true of the executable and it was **a claim nothing sourced from
/// the thing it was a claim about** — the same defect this repository has now corrected three
/// times in one file (`ReadOnlyFanAuthority`'s latch, its ledger, and its fan mode, each of
/// which was a literal that stayed true only until the mechanism behind it arrived).
///
/// [#103](https://github.com/blamechris/Aeolus/issues/103)'s adjudication decided the shape:
/// *"the read-only path survives as a capability gate on the seam, not a literal."* The
/// answer therefore comes from the conformer that would have to perform the write —
/// `SMCFanControlPlane` answers `.notBuilt` because `SMCConnection.write(_:to:)` is
/// `package`-scoped and throws and no write selector exists anywhere in `Sources`, and
/// `ScriptedControlPlane` answers `.built` because its scripted firmware really does take
/// writes. The day E3/E4 supply the three method bodies, one line moves and every gate that
/// reads it moves with it.
enum FanWriteCapability: Sendable, Hashable {

    /// The conformer has a write path. Every write verb on it may still refuse — a firmware
    /// that declines a mode write is an ordinary outcome — but the refusal will be the
    /// machine's, not the build's.
    case built

    /// The conformer has no write path of any kind. Every write verb answers
    /// `FanControlPlaneError.controlPathNotBuilt`, unconditionally, and no input can change
    /// that.
    case notBuilt
}

/// The one question a mechanism may ask a control plane **without touching hardware**.
///
/// ## Why it is a role of its own rather than a method on `FanControlPlane`
///
/// `FanControlPlane` refines this, so every plane answers it and no separate production type
/// is needed. The split is about what a *consumer* can be handed — the same argument
/// `FanStateSensing` makes for keeping `commandTarget(_:)` out of `ReclamationWatchdog`'s
/// hand. `LeaseAuthority` needs the answer and must not, in the process, acquire the ability
/// to command a fan: the lease core "owns no hardware and produces no `SystemSnapshot`", and
/// handing it a whole plane to read one property would undo that in a way no test could see.
///
/// ## It is synchronous, and that is the guarantee
///
/// `docs/SAFETY.md` § 3 is a precondition of § 1, so `LeaseAuthority.acquireLease` already
/// pays for a real 34-key SMC read (`refuseIfBlind`) before it grants. The capability
/// refusal must come **first**, before that read, because a build that cannot write has
/// nothing to learn from the machine — and a client on a blind machine told
/// `noThermalTelemetry` would retry, forever, into a refusal that was never about the
/// machine.
///
/// A synchronous, `nonisolated` getter is what makes "before any hardware round trip" a
/// property of the type rather than a rule about statement order. There is no `async` here
/// and there must not be one: an `async` accessor could read the SMC, and then the ordering
/// argument above would be a convention a future conformer could break silently.
protocol FanWriteCapabilityReporting: Sendable {

    /// Whether this conformer can write. Immutable for the life of the process: it is a
    /// property of the executable, not of the machine or of any fan on it.
    var writeCapability: FanWriteCapability { get }
}
