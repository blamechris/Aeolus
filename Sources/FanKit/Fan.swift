import Foundation

/// A fan, as the firmware describes it.
///
/// `minimumRPM` and `maximumRPM` come from the hardware at runtime (`F0Mn` / `F0Mx`) and
/// are the only bounds that matter. A configuration file may narrow them; it may never
/// widen them, and it may never be trusted over the firmware. See `docs/SAFETY.md`.
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

    /// Clamps a requested speed into this fan's hardware envelope.
    ///
    /// Zero RPM is not reachable through this method and must not be reachable through
    /// any other: stopping a fan entirely is never something a user curve is allowed to
    /// ask for.
    public func clamp(_ requestedRPM: Double) -> Double {
        min(max(requestedRPM, minimumRPM), maximumRPM)
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

/// A fan's state at one instant, as reported by the helper.
public struct FanState: Sendable, Hashable, Codable {
    public let fan: Fan
    public let actualRPM: Double
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

    public init(
        fan: Fan,
        actualRPM: Double,
        targetRPM: Double?,
        mode: FanControlMode,
        isReclaimedBySystem: Bool,
        manualControlAvailability: ManualControlAvailability
    ) {
        self.fan = fan
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
        self.manualControlAvailability = manualControlAvailability
    }
}
