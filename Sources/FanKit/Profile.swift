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

    public init(fanIndex: Int, control: Control) {
        self.fanIndex = fanIndex
        self.control = control
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
