import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

// The `--json` shapes `status` defines and `set`/`auto` reuse for the fans they observe.
//
// Every `Encodable` here is written by hand, for the reason `ListCommand.KeyedValueJSON`
// gives: the synthesised conformance omits a `nil` field entirely, and a remote caller should
// be able to rely on every key being present, with `null` standing for "not present".

/// `fanctl status --json`. See `docs/CLI.md` for the field-by-field contract.
struct StatusDocumentJSON: Encodable {
    let observation: StatusCommand.Observation

    init(_ observation: StatusCommand.Observation) {
        self.observation = observation
    }

    private enum Keys: String, CodingKey {
        case schema, capturedAt, protocolVersion, clientProtocolVersion, helper
        case thermalEmergencyActive, lease, fans
    }

    func encode(to encoder: Encoder) throws {
        let snapshot = observation.snapshot
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
        try container.encode(snapshot.capturedAt, forKey: .capturedAt)
        try container.encode(snapshot.protocolVersion, forKey: .protocolVersion)
        try container.encode(AeolusXPCVersion.current, forKey: .clientProtocolVersion)
        try container.encode(observation.helper.map(HelperIdentityJSON.init), forKey: .helper)
        try container.encode(
            snapshot.isThermalEmergencyActive, forKey: .thermalEmergencyActive)
        try container.encode(snapshot.activeLease.map(LeaseJSON.init), forKey: .lease)
        try container.encode(snapshot.fans.map(ObservedFanJSON.init), forKey: .fans)
    }
}

/// The handshake's answer: who the helper says it is.
struct HelperIdentityJSON: Encodable {
    let reply: HelloReply

    init(_ reply: HelloReply) {
        self.reply = reply
    }

    private enum Keys: String, CodingKey {
        case build, minimumProtocolVersion, maximumProtocolVersion, capabilities
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(DisplayText.sanitised(reply.helperBuild), forKey: .build)
        try container.encode(
            reply.helperProtocolRange.minimumSupported, forKey: .minimumProtocolVersion)
        try container.encode(reply.helperProtocolRange.current, forKey: .maximumProtocolVersion)
        try container.encode(
            reply.capabilities.map(DisplayText.sanitised), forKey: .capabilities)
    }
}

/// A manual-control lease, whoever holds it.
struct LeaseJSON: Encodable {
    let lease: Lease

    init(_ lease: Lease) {
        self.lease = lease
    }

    private enum Keys: String, CodingKey {
        case id, holderDescription, expiresAt, timeToLive, isSelfRenewing
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(lease.id.uuidString, forKey: .id)
        try container.encode(
            DisplayText.sanitised(lease.holderDescription), forKey: .holderDescription)
        try container.encode(lease.expiresAt, forKey: .expiresAt)
        try container.encode(
            lease.timeToLive.isFinite ? lease.timeToLive : nil, forKey: .timeToLive)
        try container.encode(lease.isSelfRenewing, forKey: .isSelfRenewing)
    }
}

/// One fan as the helper observed it.
struct ObservedFanJSON: Encodable {
    let fan: FanState

    init(_ fan: FanState) {
        self.fan = fan
    }

    private enum Keys: String, CodingKey {
        case index, firmwareName, actualRPM, minimumRPM, maximumRPM, targetRPM, mode
        case isReclaimedBySystem, manualControl
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(fan.index, forKey: .index)
        try container.encode(fan.firmwareName.map(DisplayText.sanitised), forKey: .firmwareName)
        try container.encode(FanReadingJSON(fan.actualRPM), forKey: .actualRPM)
        try container.encode(FanReadingJSON(fan.minimumRPM), forKey: .minimumRPM)
        try container.encode(FanReadingJSON(fan.maximumRPM), forKey: .maximumRPM)
        // `FanState` already normalises a non-finite target to `nil`.
        try container.encode(fan.targetRPM, forKey: .targetRPM)
        try container.encode(fan.mode.rawValue, forKey: .mode)
        try container.encode(fan.isReclaimedBySystem, forKey: .isReclaimedBySystem)
        try container.encode(
            ManualControlJSON(fan.manualControlAvailability), forKey: .manualControl)
    }
}

/// `{ "value": Double?, "unavailableReason": String? }` — exactly one of them non-null.
struct FanReadingJSON: Encodable {
    let reading: FanReading

    init(_ reading: FanReading) {
        self.reading = reading
    }

    private enum Keys: String, CodingKey {
        case value, unavailableReason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        if let value = reading.value {
            try container.encode(value, forKey: .value)
            try container.encodeNil(forKey: .unavailableReason)
        } else {
            let reason = StatusCommand.unavailableReason(reading)
            try container.encodeNil(forKey: .value)
            try container.encode(DisplayText.sanitised(reason), forKey: .unavailableReason)
        }
    }
}

/// `{ "state": "available"|"unavailable", "reason", "summary", "advice" }`, the last three
/// `null` when available. `reason` is the wire value, stable for a caller to branch on.
struct ManualControlJSON: Encodable {
    let availability: ManualControlAvailability

    init(_ availability: ManualControlAvailability) {
        self.availability = availability
    }

    private enum Keys: String, CodingKey {
        case state, reason, summary, advice
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch availability {
        case .available:
            try container.encode("available", forKey: .state)
            try container.encodeNil(forKey: .reason)
            try container.encodeNil(forKey: .summary)
            try container.encodeNil(forKey: .advice)
        case .unavailable(let reason):
            let shown = StatusCommand.displayable(reason)
            try container.encode("unavailable", forKey: .state)
            try container.encode(shown.wireValue, forKey: .reason)
            try container.encode(shown.userFacingSummary, forKey: .summary)
            try container.encode(shown.recoveryAdvice, forKey: .advice)
        }
    }
}
