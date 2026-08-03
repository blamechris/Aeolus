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
public enum FanControlMode: String, Sendable, Hashable, Codable {
    /// Apple's thermal management owns the fan. The default and the safe state.
    case automatic
    /// Aeolus is holding the fan at a constant speed under an active lease.
    case manualFixed
    /// Aeolus is driving the fan from a curve under an active lease.
    case manualCurve
}

/// Whether manual control of a fan can be taken at all right now, and if not, why.
///
/// This is not "is the fan under manual control" — that is `FanControlMode`. It is the
/// prior question: *could* a client acquire control of this fan if it asked? A client
/// that cannot tell the difference between "nothing is holding this fan" and "nothing
/// **can** hold this fan" ends up offering a slider that silently does nothing, which is
/// rule 6 ("never claim control you do not have") failing one step earlier than usual.
///
/// The reasons are named in fan-and-system terms rather than in terms of which binary is
/// installed. `FanKit` is a pure model target; "the helper build shipped without a write
/// path" is a fact about an executable, and modelling it here would make this type
/// describe the deployment rather than the machine.
///
/// New reasons may be added **within** a protocol version, precisely because an
/// unrecognised wire value decodes to `.unknown(_)` rather than failing: see
/// `AeolusXPCVersion`'s bump policy.
public enum ManualControlAvailability: Sendable, Hashable {
    /// The helper can take this fan under a lease.
    case available
    /// It cannot, for the stated reason.
    case unavailable(Reason)

    /// Why manual control of a fan is not available.
    public enum Reason: Sendable, Hashable {
        /// This build has no SMC write path at all. E2's state for every fan: the
        /// boundary exists, the thing behind it is inert, and saying so is the honest
        /// answer rather than a lease that would control nothing.
        case writePathNotBuilt
        /// The fan's firmware bounds (`F0Mn`/`F0Mx`) did not survive a plausibility
        /// check, so there is no envelope to clamp into. Distinct from "no helper" and
        /// from "no such fan": the fan is right there and is refused anyway.
        case boundsImplausible
        /// The system has taken this fan back and is not currently yielding it.
        case reclaimedBySystem
        /// A reason this build does not recognise, carried verbatim so a newer helper
        /// can explain itself to an older client without a protocol bump. Render it
        /// generically; never treat it as equivalent to `available`.
        case unknown(String)

        /// The string this reason travels as.
        public var wireValue: String {
            switch self {
            case .writePathNotBuilt: return "writePathNotBuilt"
            case .boundsImplausible: return "boundsImplausible"
            case .reclaimedBySystem: return "reclaimedBySystem"
            case .unknown(let raw): return raw
            }
        }

        /// Forward-tolerant by construction: this initialiser cannot fail, because a
        /// value from a newer peer is information, not an error. Round-tripping a known
        /// value always yields the known case, never `.unknown`.
        public init(wireValue: String) {
            switch wireValue {
            case Reason.writePathNotBuilt.wireValue: self = .writePathNotBuilt
            case Reason.boundsImplausible.wireValue: self = .boundsImplausible
            case Reason.reclaimedBySystem.wireValue: self = .reclaimedBySystem
            default: self = .unknown(wireValue)
            }
        }
    }
}

extension ManualControlAvailability: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State {
        static let available = "available"
        static let unavailable = "unavailable"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available:
            try container.encode(State.available, forKey: .state)
        case .unavailable(let reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason.wireValue, forKey: .reason)
        }
    }

    /// Decoding fails **closed**. An unrecognised state — a third state some future
    /// version grows — becomes `.unavailable(.unknown(_))`, never `.available`: the
    /// direction of that guess is the whole point, because guessing "available" hands a
    /// client permission it was never granted.
    ///
    /// A structurally broken payload (`unavailable` with no reason) still throws. Within
    /// a version the required fields of a known state cannot move — that is a bump — so
    /// their absence is corruption rather than a newer peer, and a snapshot that decodes
    /// to a wrong answer is worse than one that does not decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case State.available:
            self = .available
        case State.unavailable:
            let raw = try container.decode(String.self, forKey: .reason)
            self = .unavailable(Reason(wireValue: raw))
        default:
            self = .unavailable(.unknown(state))
        }
    }
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
    /// A value was read and decoded to a finite `Double`. **Never clamped, floored, or
    /// adjusted** from what the hardware reported. `F0Ac` was measured at 1343.07 against
    /// a declared `F0Mn` of 1350 on this project's development machine: a reading below
    /// the declared minimum is a legitimate observation, not a fault. Clamping governs
    /// targets — `FanControlEnvelope.target(for:)`, on the write path — and never
    /// observations.
    case measured(Double)

    /// The key is absent on this machine, the read failed, or it decoded to something
    /// unusable including a non-finite `Double`.
    case unavailable(reason: String)

    /// The finite `Double`, or `nil` when unavailable.
    ///
    /// For call sites that only need "is there a number here". Anything that *renders*
    /// should switch on the case instead, so it still has "why is it missing" available at
    /// the point that has to say so.
    public var value: Double? {
        if case .measured(let value) = self { return value }
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
        case .measured(let value):
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
            self = .measured(value)
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
    /// nothing. Distinct from an unavailable reading: "no target is set" is an answer,
    /// "the target could not be read" is not, and conflating them would let a fan under
    /// nobody's control render identically to one whose state is unknown.
    public let targetRPM: Double?
    public let mode: FanControlMode
    /// `true` when the helper asked for manual control but the system has taken the fan
    /// back — the reclamation case from `docs/SAFETY.md`. Surfaced honestly rather than
    /// papered over: the UI must never claim control it does not have.
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
        self.targetRPM = targetRPM
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
        self.manualControlAvailability = manualControlAvailability
    }
}
