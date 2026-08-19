import Foundation

/// The compiled-in limits every fan target is judged against.
///
/// Compiled in, never configurable, and — like `ThermalCeiling` — **tunable downward
/// only**. There is no XPC message that changes any of them and none may be added; see
/// `docs/SAFETY.md` and `CLAUDE.md` rules 3, 4 and 5.
public enum FanSafetyLimits {

    /// The slowest speed Aeolus will ever *command*.
    ///
    /// This is the constant that makes `CLAUDE.md` rule 3 — never 0 RPM, any path, any
    /// input, any configuration — actually hold. Clamping a target into `[F0Mn, F0Mx]`
    /// alone does not deliver it: `docs/RECOVERY.md` records that a fan reading zero at
    /// idle is normal on many Macs, so firmware may legitimately declare a minimum of
    /// zero, and a clamp whose floor is that declaration then permits commanding a stop.
    /// The commandable floor is therefore `max(F0Mn, minimumManualRPM)`, never `F0Mn`
    /// alone.
    ///
    /// **Why 100.** It has to separate "a fan turning slowly" from "a fan stopped", and it
    /// has to be low enough that it can never raise a target into audibility on hardware
    /// that did not ask for it. Real Macs declare minima far above it — `Mac16,5` declares
    /// 1350 — so on every machine this project has evidence of, this floor is inert and
    /// `F0Mn` governs. It only bites on firmware that declares a minimum below it, which
    /// is exactly the case rule 3 exists for. It is also the figure
    /// [#37](https://github.com/blamechris/Aeolus/issues/37) proposed as the bottom of the
    /// bounds-plausibility envelope, and the two are deliberately the *same* constant:
    /// `FanControlEnvelope` refuses any fan whose declared maximum falls below it, so the
    /// floor can never push a target above the firmware maximum. Two constants that must
    /// agree, with nothing enforcing that they do, is the disagreement this avoids.
    ///
    /// Non-zero is the load-bearing property; the exact figure is a judgement, and raising
    /// it would start refusing hardware rather than protecting it.
    public static let minimumManualRPM: Double = 100

    /// The fastest speed this project trusts as a real fan bound rather than a decode
    /// fault.
    ///
    /// `F<n>Mn` and `F<n>Mx` are `flt` keys and pass through the codec like anything else,
    /// and a byte-swapped `flt` is typically a denormal (≈ 0) or ~1e14 — see
    /// `docs/SMC-RESEARCH.md`. Either extreme defeats `CLAUDE.md` rule 4 at its root: a
    /// near-zero maximum collapses the clamp range toward a stop, and a ~1e14 maximum
    /// makes the ceiling meaningless. `Mac16,5` reports 1350 and 5777, and the fastest
    /// small fans in any Mac are a few thousand RPM, so 20,000 has wide margin over real
    /// hardware while rejecting both denormals and 1e14 outright.
    ///
    /// Defence in depth, not a substitute for correct decoding: it catches a *class* of
    /// error rather than a specific bug, which is what makes it worth keeping even once
    /// the codec is trusted.
    public static let maximumPlausibleRPM: Double = 20_000

    /// The fastest the control loop may change a fan's target, in RPM per second.
    ///
    /// `docs/SAFETY.md` § 8. A ceiling on a comfort mechanism: without it a curve with a
    /// steep segment near a threshold oscillates audibly and works the bearings.
    ///
    /// It shapes the control loop's output **only**, and never delays a safety actor's
    /// write — see [ADR 0007](../../docs/ADR/0007-safety-composition.md), which rejects
    /// ramp-capping the thermal emergency on the arithmetic (a full-scale ramp on this
    /// machine's 1350–5777 span would take 22 seconds) and on principle.
    public static let maximumRampRPMPerSecond: Double = 200

    /// The ramp rate actually used, given what a configuration asked for.
    ///
    /// `FanCurve.maximumRampRPMPerSecond` is **client data that crosses the privilege
    /// boundary inside a settings payload**, so it is governed by the same downward-only
    /// rule as a thermal ceiling (`docs/SAFETY.md` § 3) and clamped helper-side after it
    /// crosses, per `CLAUDE.md` rule 7. A configuration may ask the fans to move more
    /// gently than the compiled cap; it may not ask them to move more abruptly.
    ///
    /// A request that is not a rate at all — zero, negative, `-.infinity`, or NaN — falls
    /// back to the compiled cap rather than being honoured. `min(_:_:)` alone would not do
    /// that: every comparison with NaN is false, so `min(.nan, cap)` is `NaN`, and a NaN
    /// rate propagates into the control loop's arithmetic as a limit nothing can compare
    /// against. The fallback direction can never exceed the cap, so the downward-only rule
    /// holds by construction.
    ///
    /// One condition covers all four, and there is deliberately no separate finiteness
    /// check beside it: `requested > 0` is false for NaN as well — again because every
    /// comparison with NaN is false — and `+.infinity` needs no special case, since
    /// `min(.infinity, cap)` is the cap. A guard that no input can reach is a guard no
    /// test can kill, and this file would rather have one condition that earns its place.
    ///
    /// - Parameter requested: The rate a configuration asked for.
    /// - Returns: A finite, strictly positive rate no greater than
    ///   `maximumRampRPMPerSecond`.
    public static func effectiveRampRPMPerSecond(requested: Double) -> Double {
        guard requested > 0 else { return maximumRampRPMPerSecond }
        return min(requested, maximumRampRPMPerSecond)
    }
}

/// Why a fan's firmware bounds were refused, and with them any possibility of commanding
/// that fan.
///
/// The gate from [#37](https://github.com/blamechris/Aeolus/issues/37), which exists
/// because `CLAUDE.md` rule 4 — firmware bounds win — assumes the decoded bounds are
/// *real*. **No single codec error may silently become a clamp ceiling.**
///
/// Distinct from "no helper" and from "no such fan": the fan is right there, enumerated
/// and readable, and is refused anyway. On the wire that distinction is already spelled —
/// every case here means `ManualControlAvailability.unavailable(.boundsImplausible)`, and
/// `manualControlAvailability` below is that mapping written once so no producer can
/// invent a second answer for the same condition. This type explains *which* check failed,
/// for a log line and a fault detail; it never replaces that vocabulary.
///
/// Deliberately carries no values. The offending bounds are always in the caller's hand,
/// and a case carrying a `Double` could carry a NaN — which would make a synthesised `==`
/// report two identical refusals as different, the trap
/// `SMCFanEnumerationError.implausibleFanCount` had to give up `Equatable` for.
public enum FanBoundsImplausibility: Error, Sendable, Hashable, CustomStringConvertible {

    /// A bound was never measured: the key is absent on this machine, or the read failed.
    /// Not a decode fault — an absence — but the consequence is identical, because there
    /// is no envelope either way and inventing the missing half is exactly what
    /// `CLAUDE.md` rule 4 forbids.
    case notMeasured

    /// A bound decoded to NaN or an infinity. `SMCValue.scalar()` applies no finiteness
    /// guard, so this is a decode fault reaching the model rather than a hypothetical.
    case notFinite

    /// The declared minimum is below zero. A negative speed is not a measurement of
    /// anything a fan can do.
    case negativeMinimum

    /// The declared minimum is not below the declared maximum — inverted, or a single
    /// point. Either way there is no range to clamp into.
    case notAscending

    /// The declared maximum is below `FanSafetyLimits.minimumManualRPM`, so this fan
    /// cannot be commanded at all: honouring the 0-RPM floor would mean writing a target
    /// above what the firmware declared, and honouring the firmware maximum would mean
    /// commanding a speed below the floor. Refusing the fan is the only answer that breaks
    /// neither rule 3 nor rule 4.
    case maximumBelowFloor

    /// The declared maximum is above `FanSafetyLimits.maximumPlausibleRPM` — the ~1e14
    /// shape of a byte-swapped `flt`, and a ceiling that would make the clamp meaningless.
    case maximumAboveCeiling

    /// Text for a log line or an `AeolusXPCFault.boundsImplausible` detail.
    ///
    /// Describes the violation without quoting the values back. They are firmware-authored
    /// rather than client-chosen, so quoting them would be safe — but the caller has them
    /// and can log them alongside, and keeping the vocabulary value-free is what lets these
    /// strings be compared in a test.
    public var description: String {
        switch self {
        case .notMeasured:
            return "a firmware speed bound could not be read"
        case .notFinite:
            return "a firmware speed bound decoded to a non-finite value"
        case .negativeMinimum:
            return "the declared minimum speed is negative"
        case .notAscending:
            return "the declared minimum speed is not below the declared maximum"
        case .maximumBelowFloor:
            return
                "the declared maximum speed is below the slowest speed Aeolus will command"
        case .maximumAboveCeiling:
            return "the declared maximum speed is implausibly high"
        }
    }

    /// The availability every one of these implies.
    ///
    /// Spelled once, here, so the answer to "why can't I control this fan" cannot drift
    /// between the producer of a snapshot and the producer of a refusal. E2 shipped
    /// `ManualControlAvailability.Reason.boundsImplausible` for exactly this; nothing here
    /// invents a parallel vocabulary, and no protocol bump is involved.
    public var manualControlAvailability: ManualControlAvailability {
        .unavailable(.boundsImplausible)
    }
}

/// A speed Aeolus is willing to command, and the only shape one comes in.
///
/// There is no public initialiser and no `Codable` conformance, both deliberately: the
/// single way to obtain one is `FanControlEnvelope.target(for:)`. A value of this type is
/// therefore *evidence of the arithmetic* — that some validated envelope clamped this
/// request, so the number is finite, is not zero, and lies inside that envelope's
/// commandable range. A write path typed on `FanTargetRPM` cannot be handed a raw `Double`
/// that skipped the clamp.
///
/// ## What it does not prove, and where that half lives
///
/// **It does not say which fan the speed belongs to.** This type carries no fan identity and
/// neither does `FanControlEnvelope`, so "clamped through *this* fan's bounds" is not
/// something either of them can express. An earlier version of this comment claimed
/// otherwise — that a `FanTargetRPM` "cannot be handed a target for a fan whose bounds were
/// refused" — and it was false: any other fan's envelope produces one, as does a pair of
/// literals, since `validating(...)` is public and `FanKit` never touches firmware.
///
/// `FanKit` is pure by charter and cannot close that gap: an index reaching it would be a
/// caller's claim with nothing able to check it. The identity half is therefore
/// `AeolusHelper`'s, stamped from the plane's own read — see
/// [ADR 0008](../../docs/ADR/0008-write-authorisation.md) and `AuthorisedFanTarget`, which
/// wraps this type rather than restating it, so there is one clamp in the project. The
/// ungoverned-case ruling in [ADR 0007](../../docs/ADR/0007-safety-composition.md) — a fan
/// with no trustworthy envelope gets **no target write of any kind, ever** — is delivered
/// there, by a permit that cannot be minted for such a fan.
///
/// Adding `Codable` here would undo even the arithmetic half: a synthesised `init(from:)` is
/// a public initialiser taking an arbitrary number.
public struct FanTargetRPM: Sendable, Hashable {

    /// Stored `private`, not `public let`, and that is what makes the sentence above true.
    ///
    /// A `fileprivate` initialiser alone does not close the type: Swift's "an initialiser in
    /// an extension must delegate" rule is cross-*module*, so any other file **inside
    /// `FanKit`** could declare an extension initialiser assigning a `public let` directly —
    /// and because the property is public, the forged initialiser would be public API,
    /// reachable from every client module. `private` here is unreachable from another file
    /// however the extension is written, which is the difference between a guarantee and a
    /// convention. `WriteAuthorisationTests` asserts it.
    private let clampedRPM: Double

    /// The speed to command, always finite and always inside the envelope that produced
    /// it.
    public var rpm: Double { clampedRPM }

    fileprivate init(clamped rpm: Double) {
        self.clampedRPM = rpm
    }
}

/// A fan's *trustworthy* speed envelope: the firmware bounds, once they have survived the
/// plausibility gate, plus the floor that keeps a target off zero.
///
/// This type is the whole of `docs/SAFETY.md` § 2 in one place, and it exists as a separate
/// type from `Fan` for one reason: `Fan` describes what firmware *declared*, garbage
/// included, while this describes what may be *commanded*. Only the second of those can
/// produce a target, and it can only be constructed by `validating(...)`. A caller holding
/// one has already passed the gate; a caller that did not pass it holds a
/// `FanBoundsImplausibility` and has nothing to write with.
///
/// ## Targets only, never observations
///
/// Nothing here reads, adjusts, or judges a measured speed. `F0Ac` was measured at
/// **1343.07 against a declared `F0Mn` of 1350** on this project's development machine, so
/// an observation below the declared minimum is a legitimate reading, not a fault —
/// `FanReading` and `SMCFanEnumeration` both state that rule, and clamping governs targets
/// on the write path alone.
public struct FanControlEnvelope: Sendable, Hashable {

    /// `F<n>Mn` as the firmware declared it.
    public let declaredMinimumRPM: Double

    /// `F<n>Mx` as the firmware declared it.
    public let declaredMaximumRPM: Double

    private init(declaredMinimumRPM: Double, declaredMaximumRPM: Double) {
        self.declaredMinimumRPM = declaredMinimumRPM
        self.declaredMaximumRPM = declaredMaximumRPM
    }

    /// The slowest speed that may be commanded: the firmware minimum, or
    /// `FanSafetyLimits.minimumManualRPM` when the firmware declared something below it.
    ///
    /// The `max` is the fix for the defect this type was written for. A configuration may
    /// narrow the usable range further; it may never widen it past this, and it is never
    /// trusted over the firmware.
    public var lowestCommandableRPM: Double {
        max(declaredMinimumRPM, FanSafetyLimits.minimumManualRPM)
    }

    /// The fastest speed that may be commanded. The firmware's declared maximum, with
    /// nothing added: rule 4 permits narrowing the firmware's range and nothing else.
    public var highestCommandableRPM: Double {
        declaredMaximumRPM
    }

    /// Judges a fan's declared bounds, and yields an envelope only if they can be trusted.
    ///
    /// Every check is a way the decoded bounds could fail to describe a real fan. They are
    /// ordered from the least specific to the most, so the reported reason is the most
    /// informative one that applies.
    ///
    /// The checks together guarantee the invariant every caller depends on:
    /// `lowestCommandableRPM <= highestCommandableRPM`, and both finite. That is why
    /// `maximumBelowFloor` is a rejection rather than something `target(for:)` handles —
    /// a fan whose whole declared range sits below the floor has no speed that satisfies
    /// both rule 3 and rule 4, and the honest answer is to refuse the fan.
    ///
    /// - Parameters:
    ///   - declaredMinimumRPM: `F<n>Mn` as decoded.
    ///   - declaredMaximumRPM: `F<n>Mx` as decoded.
    /// - Returns: The envelope, or the first check that failed.
    public static func validating(
        declaredMinimumRPM: Double,
        declaredMaximumRPM: Double
    ) -> Result<FanControlEnvelope, FanBoundsImplausibility> {
        guard declaredMinimumRPM.isFinite, declaredMaximumRPM.isFinite else {
            return .failure(.notFinite)
        }
        guard declaredMinimumRPM >= 0 else {
            return .failure(.negativeMinimum)
        }
        guard declaredMinimumRPM < declaredMaximumRPM else {
            return .failure(.notAscending)
        }
        guard declaredMaximumRPM >= FanSafetyLimits.minimumManualRPM else {
            return .failure(.maximumBelowFloor)
        }
        guard declaredMaximumRPM <= FanSafetyLimits.maximumPlausibleRPM else {
            return .failure(.maximumAboveCeiling)
        }
        return .success(
            FanControlEnvelope(
                declaredMinimumRPM: declaredMinimumRPM,
                declaredMaximumRPM: declaredMaximumRPM
            ))
    }

    /// Clamps a requested speed into this fan's commandable range.
    ///
    /// Total, by construction: whatever arrives, what comes back is finite and inside
    /// `[lowestCommandableRPM, highestCommandableRPM]`. Zero is unreachable, negatives are
    /// unreachable, and a value above the firmware maximum is unreachable.
    ///
    /// NaN is the one request the arithmetic cannot answer, and it resolves to the floor.
    /// `min(max(_:_:)_:)` alone returns it unchanged — every comparison with NaN is false,
    /// so both halves pass it straight through — which is how a garbage target reaches
    /// firmware wearing a clamp's approval. The floor is chosen over the ceiling because a
    /// bug that manifests as the quietest legal speed is survivable under the thermal
    /// override (`docs/SAFETY.md` § 3), which outranks manual control and is checked after
    /// this, while a bug that manifests as maximum speed is a machine that suddenly roars
    /// for no reason a user can see.
    ///
    /// The guard is narrowed to NaN rather than to every non-finite value on purpose. The
    /// infinities *do* have an unambiguous answer and the clamp already gives it —
    /// `+.infinity` lands on the ceiling, `-.infinity` on the floor — and flooring
    /// `+.infinity` instead would answer "as fast as you can" with the slowest legal
    /// speed, which is an inversion rather than a conservative default.
    ///
    /// This is the last line before firmware, not the only one. A request that is not a
    /// speed should have been *refused* further out, where the client can be told what was
    /// wrong with it — `AeolusXPCValidation`'s "refuse, never repair". Both exist because
    /// the outer refusal is a courtesy that can be forgotten and this cannot.
    ///
    /// - Parameter requestedRPM: The speed asked for, from any source.
    /// - Returns: A speed that may be written.
    public func target(for requestedRPM: Double) -> FanTargetRPM {
        guard !requestedRPM.isNaN else {
            return FanTargetRPM(clamped: lowestCommandableRPM)
        }
        let floored = max(requestedRPM, lowestCommandableRPM)
        return FanTargetRPM(clamped: min(floored, highestCommandableRPM))
    }
}
