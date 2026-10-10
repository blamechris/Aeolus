import AeolusXPC
import FanKit
import Foundation

// `fanctl set --json`: newline-delimited JSON, one event per line, in this order and no other.
//
//     started          once, after `apply` was accepted and a snapshot listed the lease
//     holding          after every successful heartbeat (the liveness signal, and the line a
//                      consumer that is not draining is found out by)
//     ended | failed   exactly one, on standard output if that is idle, otherwise on standard
//                      error as the same line (`SetOutput.deliverClosing`)
//
// Every line carries `schema`, `event` and `at`, and every key a shape defines is always
// present, `null` standing for "not present", as in `status --json`. See `docs/CLI.md` for the
// field-by-field contract.
//
// **No wall-clock end time, anywhere.** The hold is measured on a monotonic clock, so a step in
// the wall clock must not be able to make a document say when it will end: the events carry
// `durationSeconds` and `remainingSeconds`.

/// Every key any `set` event may carry, so the shapes share one spelling of each.
enum SetEventKey: String, CodingKey {
    case schema, event, at
    case leaseID, durationSeconds, remainingSeconds, fans
    case endedBecause, signal, releaseAccepted, capturedAt, snapshotFollowsRelease, listedLeaseID
    case failure
}

/// One fan the hold covers: what was asked for, what was sent, and what the helper reported.
///
/// `observed` is the helper's own report of the fan at the snapshot and reuses the shape
/// `status --json` defines. **`started` never implies the fan reached its speed:** `commandedRPM`
/// is the target that was sent, and the fan's speed is `observed.actualRPM`.
struct SetFanJSON: Encodable {
    let plan: SetFanPlan
    let observed: FanState?

    private enum Keys: String, CodingKey {
        case index, requested, commandedRPM, observed
    }

    private enum RequestedKeys: String, CodingKey {
        case unit, value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(plan.index, forKey: .index)
        var requested = container.nestedContainer(keyedBy: RequestedKeys.self, forKey: .requested)
        switch plan.requested {
        case .percent(let value):
            try requested.encode("percent", forKey: .unit)
            try requested.encode(value, forKey: .value)
        case .rpm(let value):
            try requested.encode("rpm", forKey: .unit)
            try requested.encode(value, forKey: .value)
        }
        try container.encode(plan.commandedRPM, forKey: .commandedRPM)
        try container.encode(observed.map(ObservedFanJSON.init), forKey: .observed)
    }
}

/// What every closing event, `ended` and `failed` alike, says about how the hold ended.
///
/// A `failed` event that never held anything carries it too, with `null` for what does not
/// exist: no lease ID, no release, no fans.
struct SetClosingFacts: Sendable {
    var leaseID: UUID?
    /// `durationElapsed | signal | parentExited | outputClosed | controlLost | refused`, or
    /// `null` when `fanctl` never tried to take control (the helper could not be reached, or
    /// answered something this build cannot read). A signal before the lease is `signal`.
    var endedBecause: String?
    /// `SIGINT`, `SIGTERM` or `SIGHUP`, whenever `endedBecause` is `signal`: the signal that
    /// ended the hold, before the lease was taken, while it was in flight, or while holding.
    var signal: String?
    /// Whether the helper accepted the request to release the lease. `false` is not "the lease
    /// is still there"; it is that no acceptance was heard.
    var releaseAccepted: Bool?
    /// When the helper captured the last snapshot `fans` and `listedLeaseID` come from.
    var capturedAt: Date?
    /// Whether that snapshot was read after the release, rather than before it. `false` means
    /// `capturedAt`, `listedLeaseID` and `fans[].observed` describe the helper **while the lease
    /// was still held**, and the closing text says that nothing is known after the release.
    var snapshotFollowsRelease: Bool?
    /// The lease the helper listed in that snapshot, whoever holds it.
    var listedLeaseID: UUID?
    var fans: [SetFanJSON]?

    static let none = SetClosingFacts()

    func encode(into container: inout KeyedEncodingContainer<SetEventKey>) throws {
        try container.encode(leaseID?.uuidString, forKey: .leaseID)
        try container.encode(endedBecause, forKey: .endedBecause)
        try container.encode(signal, forKey: .signal)
        try container.encode(releaseAccepted, forKey: .releaseAccepted)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(snapshotFollowsRelease, forKey: .snapshotFollowsRelease)
        try container.encode(listedLeaseID?.uuidString, forKey: .listedLeaseID)
        try container.encode(fans, forKey: .fans)
    }
}

/// `{"event": "started", ...}`
struct SetStartedEventJSON: Encodable {
    let at: Date
    let hold: SetCommand.Hold
    let snapshot: SystemSnapshot

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SetEventKey.self)
        try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
        try container.encode("started", forKey: .event)
        try container.encode(at, forKey: .at)
        try container.encode(hold.leaseID.uuidString, forKey: .leaseID)
        try container.encode(hold.durationSeconds, forKey: .durationSeconds)
        try container.encode(SetOutput.fans(of: hold, in: snapshot), forKey: .fans)
    }
}

/// `{"event": "holding", ...}`
struct SetHoldingEventJSON: Encodable {
    let at: Date
    let hold: SetCommand.Hold
    let snapshot: SystemSnapshot
    let remainingSeconds: Int

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SetEventKey.self)
        try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
        try container.encode("holding", forKey: .event)
        try container.encode(at, forKey: .at)
        try container.encode(hold.leaseID.uuidString, forKey: .leaseID)
        try container.encode(remainingSeconds, forKey: .remainingSeconds)
        try container.encode(SetOutput.fans(of: hold, in: snapshot), forKey: .fans)
    }
}

/// `{"event": "ended", ...}`: the hold ended and the helper reports the safe state. Exit 0.
struct SetEndedEventJSON: Encodable {
    let at: Date
    let facts: SetClosingFacts

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SetEventKey.self)
        try container.encode(HelperCommandOutput.schemaVersion, forKey: .schema)
        try container.encode("ended", forKey: .event)
        try container.encode(at, forKey: .at)
        try facts.encode(into: &container)
        try container.encodeNil(forKey: .failure)
    }
}
