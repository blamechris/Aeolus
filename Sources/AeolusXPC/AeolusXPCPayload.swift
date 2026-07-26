import FanKit
import Foundation

/// Everything a client needs to render the current state of the machine.
public struct SystemSnapshot: Sendable, Hashable, Codable {
    public let protocolVersion: Int
    public let fans: [FanState]
    public let sensors: [SensorSample]
    /// The lease currently granting manual control, if any.
    public let activeLease: Lease?
    /// Set when the thermal emergency override is engaged. Clients must show this and
    /// must not present it as a normal user-selected state.
    public let isThermalEmergencyActive: Bool
    public let capturedAt: Date

    public init(
        protocolVersion: Int = AeolusXPCVersion.current,
        fans: [FanState],
        sensors: [SensorSample],
        activeLease: Lease?,
        isThermalEmergencyActive: Bool,
        capturedAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.fans = fans
        self.sensors = sensors
        self.activeLease = activeLease
        self.isThermalEmergencyActive = isThermalEmergencyActive
        self.capturedAt = capturedAt
    }
}

/// A decorated sensor reading as it crosses to a client.
public struct SensorSample: Sendable, Hashable, Codable {
    /// The raw SMC key. Always present, always displayable.
    public let key: String
    /// The catalog label, if the catalog knows this key on this machine.
    public let label: String?
    /// How much the label should be trusted. Shown in the UI; a guess is marked a guess.
    public let labelConfidence: LabelConfidence?
    public let value: Double
    public let unit: Unit

    public enum LabelConfidence: String, Sendable, Hashable, Codable {
        case verified
        case community
        case guess
    }

    public enum Unit: String, Sendable, Hashable, Codable {
        case celsius, rpm, watts, volts, amps, percent, unknown
    }

    public init(
        key: String,
        label: String?,
        labelConfidence: LabelConfidence?,
        value: Double,
        unit: Unit
    ) {
        self.key = key
        self.label = label
        self.labelConfidence = labelConfidence
        self.value = value
        self.unit = unit
    }
}

/// A client's request for manual control.
public struct LeaseRequest: Sendable, Hashable, Codable {
    public let holderDescription: String
    public let fanIndices: [Int]
    public let timeToLive: TimeInterval
    /// Asks the helper to keep renewing after the client exits. Still a lease.
    public let isSelfRenewing: Bool

    public init(
        holderDescription: String,
        fanIndices: [Int],
        timeToLive: TimeInterval = Lease.defaultTimeToLive,
        isSelfRenewing: Bool = false
    ) {
        self.holderDescription = holderDescription
        self.fanIndices = fanIndices
        self.timeToLive = timeToLive
        self.isSelfRenewing = isSelfRenewing
    }
}

/// Shared JSON coders so both sides of the boundary agree on date and key encoding.
public enum AeolusXPCCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
