import FanKit

/// The permit that stands between a firmware read and a firmware write.
///
/// Three declarations that only make sense together, and that is why they share a file:
/// both permit types have `fileprivate` initialisers, so `FanEnvelope.commandable` below is
/// the only mint anywhere in `Sources`, and moving any one of them elsewhere would open a
/// second route. See [ADR 0008](../../docs/ADR/0008-write-authorisation.md).

/// A fan that may be commanded: its index and its gated envelope, from the same read.
///
/// The only producer is `FanEnvelope.commandable`, and that is the whole design.
/// [ADR 0008](../../docs/ADR/0008-write-authorisation.md) calls this permit "stamped by the
/// read": `FanEnvelope` is what `readCriticalTemperatures`' sibling `readEnvelope(ofFan:)`
/// returns, and it already carries the index and the bounds that came back from **one**
/// subset read. Binding them here means the pairing "these bounds belong to fan *n*" is
/// established by the component that performed the read, rather than asserted by whoever
/// happens to be calling.
///
/// ## Why this is not in `FanKit`
///
/// The obvious alternative was to give `FanControlEnvelope` a fan index and let
/// `validating(forFan:…)` take it. ADR 0008 rejects that: `FanKit` never touches firmware,
/// so an index reaching it is a *caller's claim* that nothing can check — the same
/// substitution of prose for control that #108 was filed against, moved one module over
/// into a library every unprivileged client links. Authorisation vocabulary belongs where
/// `FanControlPlane` already puts privileged vocabulary; a type a client cannot name is a
/// type a client cannot reach, and one future `Codable` conformance cannot put this on the
/// wire because it is not there to conform.
struct CommandableFan: Sendable, Hashable {

    /// The fan index, taken from the `FanEnvelope` the plane read — never from a parameter.
    let index: Int

    /// The bounds that read declared, once they had passed #37's plausibility gate.
    let envelope: FanControlEnvelope

    fileprivate init(index: Int, envelope: FanControlEnvelope) {
        self.index = index
        self.envelope = envelope
    }

    /// Clamps a requested speed into this fan's envelope and stamps it with this fan.
    ///
    /// Total, like the clamp beneath it: whatever arrives, what comes back is finite and
    /// inside `[max(F<n>Mn, minimumManualRPM), F<n>Mx]`. It cannot fail, because a fan whose
    /// bounds could not be trusted never became a `CommandableFan` in the first place.
    func target(for requestedRPM: Double) -> AuthorisedFanTarget {
        AuthorisedFanTarget(fanIndex: index, target: envelope.target(for: requestedRPM))
    }
}

/// A speed that may be written, bound to the fan whose read supplied the bounds it was
/// clamped into.
///
/// ## What holding one proves
///
/// 1. A minimum/maximum pair passed #37's plausibility gate — finite, ascending,
///    non-negative, and inside `[minimumManualRPM, maximumPlausibleRPM]`.
/// 2. `rpm` was clamped into that pair's commandable range, so it is finite, never zero,
///    and never above the declared firmware maximum. `FanTargetRPM` carries that half and
///    is wrapped rather than restated, so there is one clamp in the project and not two.
/// 3. `fanIndex` and those bounds came out of the **same** `FanEnvelope` value, so the fan
///    written to and the envelope clamped into cannot disagree by accident.
///
/// ## What holding one does not prove
///
/// Both of these are named rather than papered over, because the defect that produced this
/// type was a doc comment claiming more than its type delivered.
///
/// - **Not firmware provenance.** `FanEnvelope`'s initialiser is internal, so code inside
///   `AeolusHelper` — and a test using `@testable` — can construct one from literals. This
///   design converts "skipped the gate by accident, in code that looks correct" into "faked
///   a firmware reading on purpose", which review can see. It does not make fabrication
///   impossible, and no in-process design can. Any `FanEnvelope(...)` outside
///   `SMCFanControlPlane.readEnvelope(ofFan:)` and the test target is a red flag by policy.
/// - **Not freshness.** Nothing expires a permit; a `CommandableFan` cached across sleep or
///   reclamation is still accepted. That is deliberate — `SAFETY.md` §3's emergency may hold
///   a permit taken at grant time so its maximum write needs no read while the machine is
///   above ceiling — and it rests on declared bounds being stable within a boot, which is
///   believed and unverified. Verifying it belongs in E4 bring-up (`docs/SMC-RESEARCH.md`).
struct AuthorisedFanTarget: Sendable, Hashable {

    /// The fan this speed was authorised for.
    let fanIndex: Int

    /// The clamped speed. `FanKit`'s evidence that a validated envelope produced it.
    let target: FanTargetRPM

    /// The speed to put on the wire.
    var rpm: Double { target.rpm }

    fileprivate init(fanIndex: Int, target: FanTargetRPM) {
        self.fanIndex = fanIndex
        self.target = target
    }
}

extension FanEnvelope {

    /// This fan's write permit, or the reason its declared bounds were refused.
    ///
    /// **The only place a permit is minted.** It runs `FanKit`'s gate on the bounds this
    /// value actually carries and stamps the result with the index this value actually
    /// carries; it invents neither. Both permit types have `fileprivate` initialisers, so
    /// within `Sources` there is no second route — and `@testable` does not widen
    /// `fileprivate`, so there is no second route from the test target either. A test that
    /// wants a permit builds a `FanEnvelope`, which is the honest shape: faking a firmware
    /// reading looks like faking a firmware reading.
    var commandable: Result<CommandableFan, FanBoundsImplausibility> {
        FanControlEnvelope.validating(
            declaredMinimumRPM: minimumRPM,
            declaredMaximumRPM: maximumRPM
        ).map { CommandableFan(index: index, envelope: $0) }
    }
}
