import Foundation

/// A fan, as the firmware describes it.
///
/// `minimumRPM` and `maximumRPM` come from the hardware at runtime (`F0Mn` / `F0Mx`) and
/// are the only bounds that matter. A configuration file may narrow them; it may never
/// widen them, and it may never be trusted over the firmware. See `docs/SAFETY.md`.
///
/// This type describes what firmware *declared*, garbage included, and so carries no
/// clamp: a declaration is not yet an envelope. `controlEnvelope` is the judgement, and
/// `FanControlEnvelope` is the only type that can turn a request into a speed to write.
public struct Fan: Sendable, Hashable, Codable, Identifiable {
    public let index: Int
    public let minimumRPM: Double
    public let maximumRPM: Double
    /// A firmware-supplied name where one exists (`{fds` descriptor), otherwise `nil`.
    /// Never invented — an unnamed fan is shown as "Fan 1", not as a guess.
    public let firmwareName: String?

    public var id: Int { index }

    public init(index: Int, minimumRPM: Double, maximumRPM: Double, firmwareName: String? = nil) {
        self.index = index
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.firmwareName = firmwareName
    }

    /// This fan's commandable envelope, or the reason its declared bounds were refused.
    ///
    /// The gate is `FanControlEnvelope.validating(declaredMinimumRPM:declaredMaximumRPM:)`
    /// and this is simply that call spelled on the model, so no caller has to remember
    /// which of `minimumRPM`/`maximumRPM` goes where. A failure means manual control of
    /// this fan is `.unavailable(.boundsImplausible)`; see `FanBoundsImplausibility`.
    public var controlEnvelope: Result<FanControlEnvelope, FanBoundsImplausibility> {
        FanControlEnvelope.validating(
            declaredMinimumRPM: minimumRPM,
            declaredMaximumRPM: maximumRPM
        )
    }
}

/// What is currently driving a fan.
///
/// These cases describe the **fan**, not Aeolus. "Who is holding it" is a separate question
/// answered by `SystemSnapshot.activeLease` and `ManualControlAvailability`, and a client that
/// conflates the two will attribute another tool's manual hold to Aeolus — see `manualFixed`.
public enum FanControlMode: String, Sendable, Hashable, Codable {
    /// Apple's thermal management owns the fan. The default and the safe state.
    case automatic
    /// The fan is off the system's thermal management and is being held at a fixed speed.
    ///
    /// **By Aeolus under a lease, or by something else.** This case said "Aeolus is holding
    /// the fan at a constant speed under an active lease" until the helper began reporting the
    /// mode `F<n>Md` actually declares
    /// ([#148](https://github.com/blamechris/Aeolus/issues/148)); a fan another vendor's tool
    /// or a crashed previous helper left in manual now arrives here with `activeLease: nil`,
    /// which the old sentence made unreadable. Read `activeLease` and
    /// `manualControlAvailability` to tell the two apart: a fan Aeolus holds has a lease
    /// naming it, and one it merely observes does not.
    ///
    /// A clarification of what the firmware bit means, not a new meaning for the field — the
    /// wire value and its decoding are unchanged, so `AeolusXPCVersion` does not move.
    case manualFixed
    /// Aeolus is driving the fan from a curve under an active lease.
    ///
    /// Unlike `manualFixed` this one really is about Aeolus: a curve is Aeolus's own intent
    /// and no firmware bit expresses it, so nothing outside this project can put a fan here.
    case manualCurve
}

/// One per-fan RPM reading, or the reason it could not be produced — never a bare `0`
/// standing in for either.
///
/// ## Why this exists, and why it had to exist before #72 shipped
///
/// `FanPoller` is deliberately written so that a machine reporting `F0Mn` but not `F0Mx`
/// still enumerates that fan, with the missing key marked unavailable and every other
/// value rendering normally. The wire shape could not express that. `FanState` embedded a
/// `Fan`, whose `minimumRPM`/`maximumRPM` are non-optional, and carried a non-optional
/// `actualRPM` — so the first producer of a `SystemSnapshot` meeting a partially-readable
/// fan had exactly three options, and all of them are defects: omit the fan (hides
/// hardware that is right there), serve `0` (the fabricated-zero mode this project has
/// stamped out in three separate places, and which reads to a user as "this fan has
/// stopped"), or fail the entire snapshot over one bad key.
///
/// `AeolusXPCVersion`'s bump policy binds from the first *shipped* implementation, so this
/// reshape was free up to #72 and a version bump plus a migration afterwards.
///
/// An enum rather than two optional fields, matching the choice `AeolusUI`'s
/// `KeyedReading.Availability` already made for the same problem: it makes "a value and a
/// reason are mutually exclusive" a fact the type system enforces rather than a convention
/// every call site has to be trusted to honour. `(nil, nil)` and `(value, reason)` are both
/// unrepresentable.
///
/// The reason is **free-form diagnostic text and is never parsed.** Vocabulary that gates
/// behaviour is structured — that is `ManualControlAvailability`'s job, and a client
/// deciding what it may do consults that, not this string.
public enum FanReading: Sendable, Hashable {
    /// A value that has already passed the `isFinite` guard in `measured(_:)`. By
    /// **convention**, constructed only through `measured(_:)` — go there for the guard.
    ///
    /// That convention is not enforced by the type system: `measuredFinite` is a public
    /// enum case, and Swift cannot restrict a case's access below the enum's own level,
    /// so `FanReading.measuredFinite(.nan)` compiles from any module today, this one
    /// included. What enforces it is `MeasuredFiniteConstructionSiteTests` in
    /// `FanKitTests`, which fails the moment `measuredFinite(` is constructed anywhere
    /// under `Sources/` outside this file — a source-tripwire test, not a compiler
    /// guarantee. #96's acceptance criterion ("a test that fails if a producer is added
    /// without it") is that test, not this doc comment.
    case measuredFinite(Double)

    /// The key is absent on this machine, the read failed, or it decoded to something
    /// unusable including a non-finite `Double`.
    case unavailable(reason: String)

    /// Constructs a measured reading, or `.unavailable` when there is nothing finite to
    /// carry.
    ///
    /// A value that was read and decoded to a finite `Double` is **never clamped,
    /// floored, or adjusted** from what the hardware reported. `F0Ac` was measured at
    /// 1343.07 against a declared `F0Mn` of 1350 on this project's development machine: a
    /// reading below the declared minimum is a legitimate observation, not a fault.
    /// Clamping governs targets — `FanControlEnvelope.target(for:)`, on the write path —
    /// and never observations.
    ///
    /// `init(from:)` below has always refused a non-finite value; this is the
    /// construction-side twin of that guard. Without it, a producer that never goes
    /// through JSON — the control loop computing a target from curve arithmetic, for
    /// instance — could still hand a NaN or infinite `Double` to `AeolusXPCCoding`'s
    /// encoder, whose `nonConformingFloatEncodingStrategy` is `.throw`: one bad field then
    /// refuses the entire snapshot, every tick, rather than costing the one row it
    /// actually poisoned.
    public static func measured(_ value: Double) -> FanReading {
        guard value.isFinite else {
            return .unavailable(reason: "a fan reading must be finite, got \(value)")
        }
        return .measuredFinite(value)
    }

    /// The finite `Double`, or `nil` when unavailable.
    ///
    /// For call sites that only need "is there a number here". Anything that *renders*
    /// should switch on the case instead, so it still has "why is it missing" available at
    /// the point that has to say so.
    public var value: Double? {
        if case .measuredFinite(let value) = self { return value }
        return nil
    }
}

extension FanReading: Codable {
    private enum CodingKeys: String, CodingKey {
        case value
        case unavailableReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .measuredFinite(let value):
            try container.encode(value, forKey: .value)
        case .unavailable(let reason):
            try container.encode(reason, forKey: .unavailableReason)
        }
    }

    /// Decoding refuses anything that is not exactly one of the two shapes.
    ///
    /// Both fields present is a peer disagreeing with itself about whether it has a
    /// reading; neither present is the `(nil, nil)` shape `AeolusXPCProtocol` calls a
    /// protocol violation rather than an empty success. A value that is present but not
    /// finite is refused here rather than carried, because `Double`'s JSON round trip
    /// admits values `FanReading.measured` promises never to hold.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Double.self, forKey: .value)
        let reason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
        switch (value, reason) {
        case (let value?, nil):
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "a fan reading must be finite, got \(value)"
                )
            }
            self = .measuredFinite(value)
        case (nil, let reason?):
            self = .unavailable(reason: reason)
        case (nil, nil):
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription:
                    "a fan reading carries either a value or a reason it is unavailable, "
                    + "and this carries neither"
            )
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription:
                    "a fan reading carries either a value or a reason it is unavailable, "
                    + "and this carries both"
            )
        }
    }
}

/// A fan's state at one instant, as reported by the helper.
///
/// ## Why this does not embed a `Fan`
///
/// `Fan` is the *control* model: its bounds are non-optional and `controlEnvelope` depends
/// on them, which is how "never 0 RPM" and "never widen firmware bounds" end up enforced by
/// the type system rather than by vigilance. That strictness is correct and must stay.
///
/// This is the *report* model, and it has to be able to describe a fan whose bounds could
/// not be read. Embedding the strict type in the tolerant one forced a fabricated value at
/// exactly the moment honesty mattered. They are now separate, which additionally stops a
/// future change to `Fan` from silently becoming a protocol bump.
///
/// `fan` reconstructs the control model, and returns `nil` unless both bounds were really
/// measured — so it is not possible to reach the gate without the firmware bounds the gate
/// is supposed to judge. `controlEnvelope` folds the two steps together and is what a
/// caller that wants to *command* the fan should use.
public struct FanState: Sendable, Hashable, Codable {
    public let index: Int
    /// A firmware-supplied name where one exists (`{fds` descriptor), otherwise `nil`.
    /// Never invented — an unnamed fan is shown as "Fan 1", not as a guess.
    public let firmwareName: String?
    public let actualRPM: FanReading
    public let minimumRPM: FanReading
    public let maximumRPM: FanReading
    /// The speed the helper is currently asking for, or `nil` when it is asking for
    /// nothing. That distinction (an unset target vs. a reading that could not be
    /// produced) is what `FanReading` exists to make for `actualRPM`/`minimumRPM`/
    /// `maximumRPM`, each of which carries its `unavailable(reason:)` separately from
    /// `nil`-shaped "no value".
    ///
    /// `targetRPM` deliberately does **not** make that distinction. It is a bare
    /// `Double?`, and a non-finite value given to either initialiser is normalised to
    /// `nil` by `FanState.normalizedTargetRPM(_:)` rather than carried or reported —  so
    /// "no target is set" and "a producer computed a target that came out NaN or
    /// infinite" are indistinguishable on the wire, on purpose. The alternative is
    /// `AeolusXPCCoding`'s bare `JSONEncoder`, whose `nonConformingFloatEncodingStrategy`
    /// is `.throw`: a poisoned target that reached the encoder would refuse the *entire*
    /// snapshot, every tick, over one field nobody can currently act on anyway (there is
    /// no wire-level "target unavailable" state for a client to render). Diagnosing *why*
    /// a producer computed a non-finite target belongs at the producer's own call site —
    /// E5's control loop, once it is arithmetic rather than a fixed value — not on this
    /// field, which only has room to say "nothing" either way.
    public let targetRPM: Double?
    public let mode: FanControlMode
    /// `true` when the helper asked for manual control but the system has taken the fan
    /// back — the reclamation case from `docs/SAFETY.md`. Surfaced honestly rather than
    /// papered over: the UI must never claim control it does not have.
    ///
    /// **Narrower than "the helper lost this fan", and the narrowness is the contract.**
    /// § 5 also gives a fan up when it has gone blind on it, and that is not this: a helper
    /// that cannot read has learned nothing about who holds the fan, so reporting it here
    /// would claim a loss of control nothing has established and point the user at macOS's
    /// thermal behaviour instead of at a dead SMC connection. Blindness travels as
    /// `manualControlAvailability == .unavailable(.supervisorBlind)`. Any producer of this
    /// field that has both conditions in hand sets it for the reclamation alone.
    public let isReclaimedBySystem: Bool
    /// Whether this fan could be taken under a lease at all, and if not, why.
    ///
    /// Deliberately has no default. Every producer states it, because the two ways of
    /// being wrong are not symmetric: a forgotten `.available` is a UI offering control
    /// that does not exist, and there is no value that is safe to assume on a caller's
    /// behalf.
    public let manualControlAvailability: ManualControlAvailability

    /// The control model for this fan, or `nil` when the firmware bounds are not fully
    /// known.
    ///
    /// The `nil` is load-bearing rather than defensive: `Fan` is the only type carrying
    /// `controlEnvelope`, and a fan whose `F<n>Mn` or `F<n>Mx` did not read has no bounds
    /// to judge. Returning one anyway would mean inventing a bound, and an invented bound
    /// on the write path is how a fan ends up driven outside what the firmware declared. A
    /// caller that wants to control a fan must handle the `nil`; a caller that only wants
    /// to display one never needs this.
    public var fan: Fan? {
        guard let minimum = minimumRPM.value, let maximum = maximumRPM.value else {
            return nil
        }
        return Fan(
            index: index,
            minimumRPM: minimum,
            maximumRPM: maximum,
            firmwareName: firmwareName
        )
    }

    /// This fan's commandable envelope, or the reason there is none.
    ///
    /// One call for the question a would-be writer actually has, folding together the two
    /// ways a fan can have no envelope: a bound that never read (`.notMeasured`) and bounds
    /// that read but cannot be trusted. They are different conditions with the same
    /// consequence — no target may be produced, and manual control is
    /// `.unavailable(.boundsImplausible)` — and offering them as one answer is what stops a
    /// caller handling only the half it happened to think of.
    public var controlEnvelope: Result<FanControlEnvelope, FanBoundsImplausibility> {
        guard let fan else { return .failure(.notMeasured) }
        return fan.controlEnvelope
    }

    public init(
        index: Int,
        firmwareName: String? = nil,
        actualRPM: FanReading,
        minimumRPM: FanReading,
        maximumRPM: FanReading,
        targetRPM: Double?,
        mode: FanControlMode,
        isReclaimedBySystem: Bool,
        manualControlAvailability: ManualControlAvailability
    ) {
        self.index = index
        self.firmwareName = firmwareName
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = FanState.normalizedTargetRPM(targetRPM)
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
        self.manualControlAvailability = manualControlAvailability
    }

    /// `nil` when there is no target, and `nil` again when the target given is not
    /// finite — the two cases this field is meant to be unable to distinguish, because
    /// "no target is set" is the honest description of both. A NaN or infinite target
    /// reaching `AeolusXPCCoding`'s encoder would refuse the entire snapshot; landing it
    /// here instead means it never gets that far.
    private static func normalizedTargetRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

extension FanState {
    private enum CodingKeys: String, CodingKey {
        case index
        case firmwareName
        case actualRPM
        case minimumRPM
        case maximumRPM
        case targetRPM
        case mode
        case isReclaimedBySystem
        case manualControlAvailability
    }

    /// Routed through the memberwise initialiser so `targetRPM` gets the same
    /// `normalizedTargetRPM(_:)` guard here as it does in code — `AeolusXPCCoding`'s
    /// bare `JSONEncoder`/`JSONDecoder` cannot carry a literal NaN or infinity in valid
    /// JSON, but nothing says every future decoder configuration will share that
    /// property, and a synthesised `init(from:)` would have assigned the stored property
    /// directly, same as it did before this fix.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            index: try container.decode(Int.self, forKey: .index),
            firmwareName: try container.decodeIfPresent(String.self, forKey: .firmwareName),
            actualRPM: try container.decode(FanReading.self, forKey: .actualRPM),
            minimumRPM: try container.decode(FanReading.self, forKey: .minimumRPM),
            maximumRPM: try container.decode(FanReading.self, forKey: .maximumRPM),
            targetRPM: try container.decodeIfPresent(Double.self, forKey: .targetRPM),
            mode: try container.decode(FanControlMode.self, forKey: .mode),
            isReclaimedBySystem: try container.decode(Bool.self, forKey: .isReclaimedBySystem),
            manualControlAvailability: try container.decode(
                ManualControlAvailability.self, forKey: .manualControlAvailability)
        )
    }
}
