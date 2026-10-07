import AeolusXPC
import FanKit
import Foundation

/// `fanctl auto --json`. See `docs/CLI.md` for the field-by-field contract.
///
/// One document whatever the exit code, as long as a snapshot was read: a non-zero exit after a
/// successful snapshot still carries `fans`, and `failure` says why. A run that could not read
/// a snapshot prints `HelperCommandOutput.FailureDocumentJSON` instead, which has no `fans` to
/// carry.
///
/// Written by hand, like every shape `status` defines, so every key is present and `null` means
/// "not present" — the synthesised conformance omits a `nil` field entirely.
struct AutoDocumentJSON: Encodable {
    let observation: AutoCommand.Observation

    init(_ observation: AutoCommand.Observation) {
        self.observation = observation
    }

    private enum Keys: String, CodingKey {
        case schema, restoreRequested, endedLease, lease, fans, failure
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
        try container.encode(observation.restoreRequested, forKey: .restoreRequested)
        try container.encode(observation.endedLease.map(LeaseJSON.init), forKey: .endedLease)
        try container.encode(observation.snapshot.activeLease.map(LeaseJSON.init), forKey: .lease)
        try container.encode(observation.snapshot.fans.map(ObservedFanJSON.init), forKey: .fans)
        try container.encode(
            observation.failure.map(HelperCommandOutput.FailureJSON.init), forKey: .failure)
    }
}
