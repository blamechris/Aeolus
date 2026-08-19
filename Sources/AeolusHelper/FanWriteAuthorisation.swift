import FanKit

// The permit that stands between a firmware read and a firmware write. Three declarations
// that only make sense together, which is why they share a file — see
// docs/ADR/0008-write-authorisation.md for the decision and its named residual holes.
//
// The lock has two halves and BOTH are load-bearing. Neither is redundant, and a draft of
// this comment implied one of them was, which is the kind of sentence that gets a guard
// deleted by someone tidying up.
//
//  1. Every initialiser is `fileprivate`. Without it the mint is `internal` and any file in
//     the module can issue a permit for an arbitrary index with arbitrary bounds. `private`
//     would be wrong in the other direction — `FanEnvelope.commandable` is an extension on a
//     different type, and could no longer call it.
//  2. Every stored property is `private`, read back through a computed accessor. Without
//     that, half 1 is bypassable: Swift's "an initialiser in an extension must delegate" rule
//     is cross-*module*, not cross-*file*, so another file in this module could declare an
//     extension initialiser and assign `internal` stored properties directly — forging a
//     permit without ever calling the mint. `private` members are unreachable from another
//     file however the extension is written. A stored `var` would be worse still: it would
//     let another file re-point an already-minted, legitimately-read permit at a different
//     fan, which is the cross-fan defect this whole file exists to close.
//
// `WriteAuthorisationTests.anAuthorisationTypeCannotBeMintedElsewhere` asserts both halves
// and the expected number of stored properties, because no runtime test can see an access
// level and every one of these was live at some point in this PR's review.

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

    private let storedIndex: Int
    private let storedEnvelope: FanControlEnvelope

    /// The fan index, taken from the `FanEnvelope` the plane read — never from a parameter.
    var index: Int { storedIndex }

    /// The bounds that read declared, once they had passed #37's plausibility gate.
    var envelope: FanControlEnvelope { storedEnvelope }

    fileprivate init(index: Int, envelope: FanControlEnvelope) {
        self.storedIndex = index
        self.storedEnvelope = envelope
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

    private let storedFanIndex: Int
    private let storedTarget: FanTargetRPM

    /// The fan this speed was authorised for.
    var fanIndex: Int { storedFanIndex }

    /// The clamped speed. `FanKit`'s evidence that a validated envelope produced it.
    var target: FanTargetRPM { storedTarget }

    /// The speed to put on the wire.
    var rpm: Double { storedTarget.rpm }

    fileprivate init(fanIndex: Int, target: FanTargetRPM) {
        self.storedFanIndex = fanIndex
        self.storedTarget = target
    }
}

extension FanEnvelope {

    /// This fan's write permit, or the reason its declared bounds were refused.
    ///
    /// **The only place a permit is minted.** It runs `FanKit`'s gate on the bounds this
    /// value actually carries and stamps the result with the index this value actually
    /// carries; it invents neither. What makes it the only place is the `fileprivate`
    /// initialisers *and* the `private` stored properties together — see this file's header,
    /// which explains why removing either one opens a different route.
    ///
    /// A test that wants a permit builds a `FanEnvelope` and comes through here, which is
    /// the honest shape: faking a firmware reading looks like faking a firmware reading.
    var commandable: Result<CommandableFan, FanBoundsImplausibility> {
        FanControlEnvelope.validating(
            declaredMinimumRPM: minimumRPM,
            declaredMaximumRPM: maximumRPM
        ).map { CommandableFan(index: index, envelope: $0) }
    }
}
