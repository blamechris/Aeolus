/// Every fan this machine exposes: the `FNum` count, the `F<n>Ac`/`F<n>Mn`/`F<n>Mx` keys
/// that follow from it, and the raw per-key outcome behind each one.
///
/// This is the *knowledge* of how a Mac's fans are discovered, held once because more than
/// one component depends on the answer being identical. `AeolusUI` renders the set,
/// `fanctl list` prints it, and the root helper enumerates it to serve `snapshot` — but the
/// helper's copy is also a **security input**:
/// `AeolusXPCValidation.validateFanIndices(_:enumeratedFanIndices:)` uses the enumerated
/// set to decide which fans a lease may cover. A copy that drifts inside a client is a
/// rendering bug; a copy that drifts inside the helper is a boundary bug — the set gating
/// leases would disagree with the set clients display. Hence one type, in `SMCCore`.
///
/// ## Why `SMCCore` and not `FanKit`
///
/// `AeolusXPC` depends on `FanKit`, so putting SMC-reading code in `FanKit` would
/// transitively couple the wire-contract target to IOKit. `FanKit` is pure with two named
/// exceptions and no IOKit, and that stays true. This is written against `SensorProvider`,
/// which already lives here, and key enumeration is `SMCCore`'s declared responsibility in
/// `docs/ARCHITECTURE.md`'s target table.
///
/// ## Read-side only
///
/// `public`, per `SMCCore`'s read-`public` / write-`package` rule: nothing here writes, and
/// nothing here may grow a write. The three keys are a fan's *observed* speed and its
/// firmware-*declared* bounds. `F<n>Tg` and `F<n>Md` — target and mode, the write path —
/// are deliberately absent, and adding them here would be a safety review rather than a
/// refactor.
///
/// ## Observations are never clamped
///
/// `F0Ac` was measured at **1343.07 against a declared `F0Mn` of 1350** on this project's
/// development hardware — see `docs/SMC-RESEARCH.md`, "Disagreement 3". A reading below the
/// declared minimum is a legitimate observation, not a fault. Nothing in this type compares
/// `actual` against `minimum`/`maximum`, and nothing nudges one toward the other: clamping
/// governs *targets* Aeolus writes, never values it reads. Any caller that assumes
/// `actual >= minimum` — a gauge, a health check, a "fan stopped" heuristic — is wrong on
/// real hardware, and no test here may encode that assumption either.
///
/// ## No `{fds`, and no architecture branch
///
/// `{fds`, the fan descriptor struct that could supply firmware-authored fan names, is
/// absent on `Mac16,5` (`docs/SMC-RESEARCH.md`) and is reported to exist on some Intel
/// Macs. That makes it an *extension point*, not a behaviour: this type does not read it
/// today and must not start reading it behind an architecture check. `CLAUDE.md` rule 9 —
/// key on the SMC's declared type, never on `uname -m`. If firmware names are ever wanted,
/// the way in is a `{fds` read whose absence simply means "no name", on every machine
/// alike.
///
/// ## Display names live above this type
///
/// There is no `"Fan 0"` here. A synthesised human label is presentation, and each client
/// already owns one (`fanctl`'s table, `AeolusUI`'s rows). What a caller gets from this
/// type is indices and raw `SensorReadOutcome`s: the per-key availability, undecorated, so
/// the decision about how to present a missing value stays with whoever is presenting it.
public struct SMCFanEnumeration: Sendable, Hashable {
    /// The enumerated fans, in index order. Empty on a genuinely fanless machine.
    public let fans: [Fan]

    public init(fans: [Fan]) {
        self.fans = fans
    }

    /// One enumerated fan: its index, and the raw outcome of each of its three keys.
    ///
    /// Deliberately not `FanKit.Fan` — that is a model with a curve and a clamp attached,
    /// and `FanKit` does not depend on `SMCCore`. This is the read, nothing more: three
    /// outcomes, each either a `SensorReading` or the reason there is none.
    ///
    /// A fan whose `F<n>Mx` is unreadable while `Ac` and `Mn` read fine still appears here,
    /// with `maximum` carrying the failure. Dropping the whole fan would hide two working
    /// readings; substituting a `0` would fabricate one.
    public struct Fan: Sendable, Hashable {
        public let index: Int
        /// `F<n>Ac` — the fan's measured speed. Never clamped into `[minimum, maximum]`;
        /// see the enclosing type's documentation for the 1343.07-against-1350 measurement
        /// that makes that rule load-bearing rather than pedantic.
        public let actual: SensorReadOutcome
        /// `F<n>Mn` — the firmware's *declared* minimum. A declaration, not a floor the
        /// observed speed is known to respect.
        public let minimum: SensorReadOutcome
        /// `F<n>Mx` — the firmware's *declared* maximum.
        public let maximum: SensorReadOutcome

        public init(
            index: Int,
            actual: SensorReadOutcome,
            minimum: SensorReadOutcome,
            maximum: SensorReadOutcome
        ) {
            self.index = index
            self.actual = actual
            self.minimum = minimum
            self.maximum = maximum
        }
    }
}

// MARK: - Derived views

extension SMCFanEnumeration {
    public var fanCount: Int { fans.count }

    /// Every enumerated index, in order.
    public var fanIndices: [Int] { fans.map(\.index) }

    /// Every enumerated index as a set, shaped for
    /// `AeolusXPCValidation.validateFanIndices(_:enumeratedFanIndices:)` — the E5 check
    /// that decides which fans a lease may cover.
    ///
    /// Offered as a named property rather than left to each caller to build, precisely
    /// because that call site is a privilege boundary: "which set was passed" should be one
    /// answer derived from one enumeration, not a per-caller construction that can quietly
    /// filter, reorder, or widen it.
    public var enumeratedFanIndices: Set<Int> { Set(fans.map(\.index)) }
}

// MARK: - Key naming

extension SMCFanEnumeration {
    /// The key the fan count is read from. Named rather than inlined so a caller reporting
    /// "no fans" can say which key it asked.
    public static let fanCountKey = "FNum"

    /// The largest `FNum` value this project trusts as a real fan count rather than a
    /// decode fault.
    ///
    /// One constant, held once. This value existed **twice** before this type did —
    /// `FanPoller.maxPlausibleFanCount` in `AeolusUI` and `ListCommand.maxPlausibleFanCount`
    /// in `fanctl`, each independently `64`, each carrying its own copy of the reasoning
    /// and its own `FNum` validation. Two constants that must agree, with nothing
    /// enforcing that they do, are a disagreement waiting to happen; both clients now
    /// enumerate through this type instead of restating either the number or the
    /// validation that uses it. It is the same defence `SMCConnection
    /// .maxPlausibleKeyCount` applies to `#KEY`, applied to `FNum`: a corrupted read
    /// must not become an unbounded enumeration.
    public static let maxPlausibleFanCount = 64

    /// `F<n>Ac` — fan `index`'s measured speed.
    ///
    /// Enumeration needs no `readAll()` at all, discovery included: the count comes from one
    /// small, well-known key, and every fan's three keys follow from it by a fixed naming
    /// convention. These three builders are that convention, written once.
    ///
    /// One caveat is worth stating rather than leaving to be discovered: an index of 10 or
    /// more produces a five-character string (`F10Ac`), which is not a well-formed SMC key —
    /// `SMCKey` requires exactly four ASCII characters — so such a fan enumerates with all
    /// three keys reported `.unknownKey` rather than silently vanishing. No Mac this project
    /// has evidence of comes close to ten fans; the behaviour is recorded here so that if
    /// one ever does, it surfaces as visible unavailability rather than as a mystery.
    public static func actualKey(forFan index: Int) -> String { "F\(index)Ac" }

    /// `F<n>Mn` — fan `index`'s firmware-declared minimum. See `actualKey(forFan:)`.
    public static func minimumKey(forFan index: Int) -> String { "F\(index)Mn" }

    /// `F<n>Mx` — fan `index`'s firmware-declared maximum. See `actualKey(forFan:)`.
    public static func maximumKey(forFan index: Int) -> String { "F\(index)Mx" }
}

// MARK: - Enumeration

extension SMCFanEnumeration {
    /// Enumerates every fan via targeted `SensorProvider.read(keys:)` subset reads.
    ///
    /// A missing or unreadable individual key — a machine reporting `F0Mn` but not `F0Mx` —
    /// is not fatal to the enumeration: it is carried on that fan as a failed
    /// `SensorReadOutcome` and every other value still comes back. Only a failure that makes
    /// enumeration itself impossible throws: no SMC at all, `FNum` unreadable, or `FNum`
    /// decoding to an implausible count.
    ///
    /// - Parameter provider: The sensor source to enumerate against. Written to the
    ///   protocol, not to `SMCSensorProvider`, so the whole of this logic is exercisable
    ///   with a fake and needs no hardware — see `Tests/SMCCoreTests/FanEnumerationTests`.
    /// - Returns: The fans found, with per-key outcomes. Zero fans is a legitimate result,
    ///   not an error; see `readFanCount(provider:)`.
    /// - Throws: `SMCFanEnumerationError`.
    public static func enumerate(provider: some SensorProvider) async throws -> Self {
        guard await provider.isAvailable else {
            throw SMCFanEnumerationError.noSMC
        }

        let fanCount = try await readFanCount(provider: provider)
        guard fanCount > 0 else { return SMCFanEnumeration(fans: []) }

        var keys: [String] = []
        keys.reserveCapacity(fanCount * 3)
        for index in 0..<fanCount {
            keys.append(actualKey(forFan: index))
            keys.append(minimumKey(forFan: index))
            keys.append(maximumKey(forFan: index))
        }

        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: keys)
        } catch {
            throw SMCFanEnumerationError.readFailed(
                context: "read fan speeds", reason: String(describing: error))
        }

        var outcomesByKey: [String: SensorReadOutcome] = [:]
        outcomesByKey.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            outcomesByKey[outcome.key] = outcome
        }

        return SMCFanEnumeration(
            fans: (0..<fanCount).map { index in
                Fan(
                    index: index,
                    actual: checked(actualKey(forFan: index), in: outcomesByKey),
                    minimum: checked(minimumKey(forFan: index), in: outcomesByKey),
                    maximum: checked(maximumKey(forFan: index), in: outcomesByKey)
                )
            })
    }

    /// Reads `FNum`, or `0` if this machine does not expose it at all.
    ///
    /// `.unknownKey("FNum")` — the key genuinely absent from this machine's table, as
    /// opposed to present-and-zero — is treated as "no fans", not as an error: reported (per
    /// community sources; see `docs/SMC-RESEARCH.md`) on some fanless Macs, whose firmware
    /// exposes no fan-count key at all. A fanless Air is a machine Aeolus must work on, not
    /// a machine it errors on. `.readFailed`/`.notDecodable` stay errors: those mean the key
    /// exists and something went wrong, which is worth surfacing rather than silently
    /// rendering as "no fans".
    private static func readFanCount(provider: some SensorProvider) async throws -> Int {
        let outcomes: [SensorReadOutcome]
        do {
            outcomes = try await provider.read(keys: [fanCountKey])
        } catch {
            throw SMCFanEnumerationError.readFailed(
                context: "read \(fanCountKey)", reason: String(describing: error))
        }

        guard let outcome = outcomes.first else {
            throw SMCFanEnumerationError.readFailed(
                context: "read \(fanCountKey)", reason: "no outcome returned")
        }

        let decoded: Double
        switch outcome.result {
        case .success(let reading):
            decoded = reading.value
        case .failure(.unknownKey):
            return 0
        case .failure(let failure):
            throw SMCFanEnumerationError.readFailed(
                context: "read \(fanCountKey)", reason: failure.readableDescription)
        }

        // Validated before conversion, not after. SMCValue.scalar() applies no finiteness
        // or magnitude guard on the way out of this module, so a byte-order fault could
        // hand back NaN, Inf, or a value nowhere near a real fan count. Int(exactly:) never
        // traps regardless, but checking the range first — rather than converting and then
        // inspecting the result — keeps the validation order honest about what is actually
        // being validated. This bound is what stands between a misdecoded FNum and an
        // enumeration sized by it.
        //
        // `isFinite` is redundant *for the outcome*, and this is recorded rather than
        // implied: deleting it changes no result, because every comparison with NaN is
        // false (so NaN fails `>= 0`) and both infinities fall outside the range. It was
        // the one clause in this file that mutation testing could not kill. It stays as
        // defence in depth — it is what still refuses a non-finite count if either bound
        // is ever loosened — and because the two implementations this type replaced spell
        // the check the same way; it is not load-bearing on its own today.
        guard decoded.isFinite, decoded >= 0, decoded <= Double(maxPlausibleFanCount),
            let fanCount = Int(exactly: decoded.rounded())
        else {
            throw SMCFanEnumerationError.implausibleFanCount(declared: decoded)
        }
        return fanCount
    }

    /// Returns the outcome recorded for `key`, with a *successful* read still checked for
    /// finiteness before it is trusted.
    ///
    /// `SMCValue.scalar()` applies no finiteness guard, so a byte-swapped `flt` can decode
    /// to `±.infinity` or `.nan` on an otherwise-successful read — and `Double.infinity ==
    /// Double.infinity.rounded()` is `true`, a genuine property rather than a bug, so a
    /// non-finite value can pass through arithmetic downstream without ever looking wrong.
    /// It is refused here, as a `.notDecodable` failure carrying the raw key, rather than
    /// propagated to a caller that will format, average, or graph it.
    ///
    /// This is the *only* adjustment made to a successful reading. In particular the value
    /// is never compared against, or moved toward, this fan's declared minimum or maximum —
    /// see the enclosing type's documentation on why an observation below `F<n>Mn` is real.
    private static func checked(
        _ key: String, in outcomes: [String: SensorReadOutcome]
    ) -> SensorReadOutcome {
        guard let outcome = outcomes[key] else {
            return SensorReadOutcome(
                key: key, result: .failure(.readFailed(reason: "no outcome returned")))
        }
        guard case .success(let reading) = outcome.result else { return outcome }
        guard reading.value.isFinite else {
            return SensorReadOutcome(
                key: key,
                result: .failure(
                    .notDecodable(
                        reason: "decoded to a non-finite value "
                            + "(\(describeNonFinite(reading.value))) — likely a byte-order "
                            + "fault; see docs/SMC-RESEARCH.md")))
        }
        return outcome
    }

    private static func describeNonFinite(_ value: Double) -> String {
        guard !value.isFinite else { return String(value) }
        return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity")
    }
}

// MARK: - Errors

/// The failures that stop fan enumeration outright, as distinct from a single key's failure
/// — which stops nothing and is carried on the fan as a failed `SensorReadOutcome`.
///
/// Deliberately **not** `Equatable`. `implausibleFanCount` exists to carry exactly the
/// values that break equality: `.nan != .nan`, so a synthesised `==` would report two
/// identical NaN-carrying errors as different. Tests pattern-match with `if case` instead,
/// which is honest about what is being compared.
public enum SMCFanEnumerationError: Error, Sendable, CustomStringConvertible {
    /// `SensorProvider.isAvailable` reported `false` — no `AppleSMC` service on this
    /// machine at all. Distinct from "this machine has no fans", which is a successful
    /// enumeration returning zero of them.
    case noSMC
    /// A whole-request failure from the provider, or a `FNum` read that failed for a reason
    /// other than the key being absent. Not a per-key failure — those never throw.
    case readFailed(context: String, reason: String)
    /// `FNum` decoded to something outside the range this project trusts as a real fan
    /// count — non-finite, negative, or above `SMCFanEnumeration.maxPlausibleFanCount`.
    /// Carries the offending decoded value.
    case implausibleFanCount(declared: Double)

    public var description: String {
        switch self {
        case .noSMC:
            return "no AppleSMC service on this machine"
        case .readFailed(let context, let reason):
            return "\(context): \(reason)"
        case .implausibleFanCount(let declared):
            return "\(SMCFanEnumeration.fanCountKey) decoded to an implausible fan count "
                + "(\(declared))"
        }
    }
}
