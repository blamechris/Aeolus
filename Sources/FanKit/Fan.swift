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

    public init(
        fan: Fan,
        actualRPM: Double,
        targetRPM: Double?,
        mode: FanControlMode,
        isReclaimedBySystem: Bool
    ) {
        self.fan = fan
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.mode = mode
        self.isReclaimedBySystem = isReclaimedBySystem
    }
}
