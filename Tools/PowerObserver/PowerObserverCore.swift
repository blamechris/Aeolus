import Foundation
import IOKit

/// The root power domain's message numbers, needed by a tool that must depend on
/// **nothing** in this package — not `SMCCore`, not `AeolusHelper` — so the derivation
/// `Sources/AeolusHelper/Lifecycle/SystemPowerObserver.swift` already carries is repeated
/// here rather than imported. See that file's `SystemPowerMessage` doc comment for why the
/// base cannot simply be written down: `IOKit/IOMessage.h` spells every one of these with a
/// macro Swift does not import, and the base is instead recovered from `kIOReturnError`,
/// which is built from the same `sys_iokit | sub_iokit_common` composition and does import.
///
/// This tool's whole reason to exist is to see what the helper's narrower vocabulary
/// throws away, so the set below is wider than `SystemPowerMessage`'s two cases — every
/// name `IOPMLib.h` documents as delivered to a registered `IORegisterForSystemPower`
/// client, not only the two the helper acts on.
enum PowerMessage {

    /// `sys_iokit | sub_iokit_common`, taken from the SDK by way of a constant that imports.
    static let base = UInt32(bitPattern: kIOReturnError) - 0x2bc

    /// `kIOMessageCanSystemSleep` — the idle-sleep *question*. Must be acknowledged.
    static let canSystemSleep = base | 0x270

    /// `kIOMessageSystemWillNotSleep` — a previous `canSystemSleep` was vetoed. No ack.
    static let systemWillNotSleep = base | 0x290

    /// `kIOMessageSystemWillSleep` — sleep is happening. Must be acknowledged.
    static let systemWillSleep = base | 0x280

    /// `kIOMessageSystemWillPowerOn` — early wake, before most hardware is usable. No ack.
    static let systemWillPowerOn = base | 0x320

    /// `kIOMessageSystemHasPoweredOn` — awake and usable. No ack.
    static let systemHasPoweredOn = base | 0x300
}

/// Maps a raw `IOMessage` to the name `IOKit/pwr_mgt/IOPMLib.h` and `IOMessage.h` document
/// for it, or `"unknown"`.
///
/// `"unknown"` is not a gap to close. It is the measurement this tool exists to make: any
/// message type `IORegisterForSystemPower` delivers that this table does not name is exactly
/// the kind of thing the helper's narrower vocabulary would have silently dropped, and NDJSON
/// carries the raw decimal and hex alongside the name for precisely that case — see
/// `PowerEventRecord`. Naming a code here that is not documented as reaching a registered
/// `IORegisterForSystemPower` client would replace one measured fact with a guess, so the
/// table stays limited to the five `IOPMLib.h` names that reach and are acknowledged from
/// that exact call.
enum PowerMessageName {

    static func name(for messageType: UInt32) -> String {
        switch messageType {
        case PowerMessage.canSystemSleep: return "kIOMessageCanSystemSleep"
        case PowerMessage.systemWillSleep: return "kIOMessageSystemWillSleep"
        case PowerMessage.systemWillNotSleep: return "kIOMessageSystemWillNotSleep"
        case PowerMessage.systemWillPowerOn: return "kIOMessageSystemWillPowerOn"
        case PowerMessage.systemHasPoweredOn: return "kIOMessageSystemHasPoweredOn"
        default: return "unknown"
        }
    }
}

/// Pure integer arithmetic over two monotonic nanosecond samples.
///
/// Taking nanosecond counts rather than a clock type is what makes this a function a test
/// can drive without a real clock: `DispatchTime.now().uptimeNanoseconds` on either side of
/// an acknowledgement is the only thing production ever hands it.
enum PowerLatency {

    /// Microseconds elapsed from `start` to `end`, truncating rather than rounding.
    static func microseconds(fromNanoseconds start: UInt64, toNanoseconds end: UInt64) -> Int {
        Int((end - start) / 1_000)
    }
}

/// The wall clock half of every record, formatted UTC ISO-8601 so a reader never has to
/// resolve a local time zone against a `pmset` log that is already UTC-agnostic in its own
/// way. Takes `date` as a parameter — defaulted to `Date()` in production, supplied
/// directly in a test — so the formatting is exercised without waiting on a real clock.
enum WallClock {
    static func iso8601UTC(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// One line of NDJSON: encode a value, and prove there is no embedded newline to break the
/// "one event, one line" contract a consumer streaming this tool's stdout depends on.
enum NDJSON {

    enum EncodingFailure: Error, Sendable {
        case notUTF8
    }

    /// `value`, encoded as one line of JSON with no trailing newline.
    ///
    /// `.sortedKeys` buys deterministic output — useful for a test asserting on the whole
    /// line — and costs nothing: NDJSON readers parse an object by key, never by position.
    static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingFailure.notUTF8
        }
        return text
    }
}

/// One power notification, as this tool reports it. Every field the brief asks for, and
/// nothing filtered: `kind` is always `"event"`, distinguishing this from the `start`,
/// `heartbeat` and `stop` lines below.
struct PowerEventRecord: Sendable {
    let kind = "event"

    /// The raw `messageType`, decimal and hex, so an unrecognised code is still fully
    /// legible without this tool being rebuilt to name it.
    let messageTypeDecimal: UInt32
    let messageTypeHex: String

    /// `PowerMessageName.name(for:)`'s answer — a documented name, or `"unknown"`.
    let name: String

    /// The `argument` IOKit handed the callback, as a plain integer. It is a token to
    /// acknowledge with, not a pointer to dereference, so it is converted at the boundary —
    /// see `SystemPowerObserver.swift`'s identical note.
    let argument: Int

    let monotonicNanoseconds: UInt64
    let wallClockUTC: String

    /// Microseconds from receipt to this process's own acknowledgement, or `nil` for a
    /// message this tool does not acknowledge — see `PowerMessage`'s per-case comments for
    /// which two those are.
    let ackLatencyMicroseconds: Int?

    let uid: UInt32
    let pid: Int32
}

extension PowerEventRecord: Encodable {

    private enum CodingKeys: String, CodingKey {
        case kind, messageTypeDecimal, messageTypeHex, name, argument, monotonicNanoseconds,
            wallClockUTC, ackLatencyMicroseconds, uid, pid
    }

    /// Written by hand rather than synthesized, for exactly one field:
    /// `encodeIfPresent` — what the synthesized conformance would call for an `Int?` — omits
    /// the key entirely when the value is `nil`. The brief asks for an explicit JSON `null`
    /// so a reader can tell "this tool saw no acknowledgement latency to report" from "this
    /// tool did not run long enough to know", and those are different facts about the same
    /// key rather than the same fact spelled two ways.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(messageTypeDecimal, forKey: .messageTypeDecimal)
        try container.encode(messageTypeHex, forKey: .messageTypeHex)
        try container.encode(name, forKey: .name)
        try container.encode(argument, forKey: .argument)
        try container.encode(monotonicNanoseconds, forKey: .monotonicNanoseconds)
        try container.encode(wallClockUTC, forKey: .wallClockUTC)
        try container.encode(ackLatencyMicroseconds, forKey: .ackLatencyMicroseconds)
        try container.encode(uid, forKey: .uid)
        try container.encode(pid, forKey: .pid)
    }
}

/// The one line emitted at launch: who is running this, and whether the helper is already
/// registered too. Never acted on — see `Tools/PowerObserver/README.md`.
struct PowerStartRecord: Encodable, Sendable {
    let kind = "start"
    let hostname: String
    let hwModel: String
    let osVersion: String
    let uid: UInt32
    let pid: Int32

    /// Whether `launchctl print system/com.blamechris.Aeolus.Helper` exited zero at launch.
    /// Recorded so a reader of the capture can tell "the helper was also registered" from
    /// "this tool's counts are the only registration in play" — never a gate on anything
    /// this tool does.
    let helperLoaded: Bool
}

/// The 1 Hz proof of life: a missed delivery is then distinguishable from a suspended
/// process, because the heartbeat itself would also stop.
struct PowerHeartbeatRecord: Encodable, Sendable {
    let kind = "heartbeat"
    let monotonicNanoseconds: UInt64
    let wallClockUTC: String
}

/// The line emitted on a clean `SIGINT`/`SIGTERM` exit: how many of each named (or
/// `"unknown"`) message type arrived across the run.
struct PowerStopRecord: Encodable, Sendable {
    let kind = "stop"
    let counts: [String: Int]
}

/// Per-message-type counts, kept as an actor so the IOKit delivery queue and the signal
/// queue can both record into it without a data race — the same shape
/// `docs/SAFETY.md` and `CLAUDE.md` rule 10 ask every actor in this project to have, even
/// though nothing here runs as root.
actor EventCounters {
    private var counts: [String: Int] = [:]

    /// Records one delivery of the message named `name` — `PowerMessageName.name(for:)`'s
    /// answer, `"unknown"` included, so an unrecognised code is counted rather than dropped.
    func increment(_ name: String) {
        counts[name, default: 0] += 1
    }

    /// A copy of the counts so far. Safe to call at any time, including from the stop
    /// handler while a delivery could in principle still be in flight.
    func snapshot() -> [String: Int] {
        counts
    }
}
