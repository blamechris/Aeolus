import Foundation

/// A named, one-click set of per-fan settings.
///
/// Presets are a paid feature in the app most people are switching from. Here they are
/// simply part of the product.
public struct Profile: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var fanSettings: [FanSetting]
    /// Conditions that activate this profile automatically. Empty means manual only.
    public var activationTriggers: [ActivationTrigger]

    public init(
        id: UUID = UUID(),
        name: String,
        fanSettings: [FanSetting],
        activationTriggers: [ActivationTrigger] = []
    ) {
        self.id = id
        self.name = name
        self.fanSettings = fanSettings
        self.activationTriggers = activationTriggers
    }
}

/// What a profile asks of one fan.
public struct FanSetting: Sendable, Hashable, Codable {
    public let fanIndex: Int
    public let control: Control

    public enum Control: Sendable, Hashable, Codable {
        /// Hand the fan back to Apple's thermal management.
        case automatic
        /// Hold a constant speed. Still clamped to the firmware envelope.
        case fixed(rpm: Double)
        /// Drive the fan from a curve.
        case curve(FanCurve)
    }

    /// `.fixed(rpm:)` is normalised through `normalizedControl(_:)` here, the same shape
    /// as `FanState.init` routing `targetRPM` through `normalizedTargetRPM(_:)`: a
    /// non-finite speed cannot be carried, so it is not carried, silently, by this
    /// initialiser in particular. `.curve` needs no equivalent handling — `FanCurve`
    /// sanitises itself on construction, so a `Control.curve` built here can never hold a
    /// non-finite point in the first place.
    public init(fanIndex: Int, control: Control) {
        self.fanIndex = fanIndex
        self.control = FanSetting.normalizedControl(control)
    }

    /// `.automatic` in place of a `.fixed(rpm:)` this project cannot honour.
    ///
    /// `.automatic` rather than, say, clamping the speed to some floor: we cannot honour a
    /// target that is not a number, and the honest answer to "hold a speed I cannot name"
    /// is to hand the fan back to the system, not to invent a number the caller never
    /// asked for. It is also the answer that keeps CLAUDE.md rule 6 — never claim control
    /// we do not have — true of this constructor specifically: a `.fixed(rpm: .nan)`
    /// stored as-is would be a setting that *looks* like a held speed and commands
    /// nothing, which is exactly the gap that rule exists to close. And it is a fallback
    /// toward the safe state in the same spirit as
    /// `FanCurve.effectiveHysteresisCelsius(requested:)` and
    /// `FanSafetyLimits.effectiveRampRPMPerSecond(requested:)`: every one of these routes
    /// a request that cannot be honoured toward the state this project is already willing
    /// to be in, rather than toward whichever value the arithmetic happens to produce.
    private static func normalizedControl(_ control: Control) -> Control {
        guard case .fixed(let rpm) = control, !rpm.isFinite else { return control }
        return .automatic
    }
}

extension FanSetting {

    /// Explicit rather than synthesised, so `init(from:)` below has keys to decode
    /// against, matching `FanCurve` and `FanState`.
    private enum CodingKeys: String, CodingKey {
        case fanIndex
        case control
    }

    /// Decoding **refuses** a non-finite `.fixed(rpm:)` rather than normalising it to
    /// `.automatic`, for the same refuse-at-the-boundary reason
    /// `FanCurve.init(from:)` gives for `points`: a client that sent a speed that is not a
    /// number should be told so, not answered with a setting that silently means something
    /// else than what it sent. `normalizedControl(_:)` above stays the answer for every
    /// route that isn't this decoder — a fallback a caller building settings in Swift
    /// benefits from without ever having asked a question a decoder could refuse.
    ///
    /// A synthesised `init(from:)` would have assigned `control` directly from whatever
    /// `Control`'s own synthesised decoding produced, which makes the guarantee "a decoded
    /// `.fixed` is always finite" true of settings built in Swift and false of settings
    /// that arrived as JSON — the same sentence `FanCurve.init(from:)` already makes about
    /// its own `points`, for the same reason: JSON is the only way a `FanSetting` ever
    /// reaches the helper.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let control = try container.decode(Control.self, forKey: .control)
        if case .fixed(let rpm) = control, !rpm.isFinite {
            throw DecodingError.dataCorruptedError(
                forKey: .control, in: container,
                debugDescription: "a fixed-speed control's rpm is not finite")
        }
        self.init(
            fanIndex: try container.decode(Int.self, forKey: .fanIndex),
            control: control
        )
    }
}

/// A condition that switches a profile on automatically.
///
/// - Note: The rules engine is E9b.
public enum ActivationTrigger: Sendable, Hashable, Codable {
    case onBatteryPower
    case onACPower
    case lidClosed
    case externalDisplayAttached
    /// Matches on process name, e.g. `Xcode`, `blender`, `ffmpeg`.
    case processRunning(name: String)
}
