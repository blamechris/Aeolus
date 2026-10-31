import SMCCore

// The values the write turns record and take, in a file of their own so `SMCWriteTurns.swift` stays
// inside `file_length`: what a step and a floor hold saw, for their log lines; the turn's own
// refusal; a target command's numbers; and where the turns log.

/// What one engagement step saw, for its log line (D3's "raw values read before and after").
struct StepTrace: Sendable {
    let fan: Int
    let firstStep: Bool
    var before = "not read"
    var modeWrite = "not issued"
    var after = "not read"
    var outcome = "unfinished"
}

/// What one engaged turn's floor hold saw, for its log line (ADR 0014's P1′ amendment: run 1
/// records the engaged turn's raw `F<n>Tg` and whether the floor was raised): the raw target, the
/// floor it was raised to, if it was, and how the hold ended.
struct FloorHoldTrace: Sendable {
    let fan: Int
    let key: SMCKey
    /// The target's bytes as read, or `unreadable` when the read itself failed.
    var raw = "unreadable"
    /// The floor the target was raised to, in whole RPM, or `nil` when the target held.
    var floorRaisedTo: String?
    var outcome = "unfinished"
}

/// A forward write the turn refused by its own rule, before its write call: a target below the
/// fan's floor, or a value that did not encode. Nothing was written. Every caller treats it as it
/// treats a refused command — the bridge restores, level 6 hands back, § 5 restores — and a
/// first step never throws it: before its first write call, a step's refusal is
/// `.failedBeforeFirstWrite`.
struct WriteTurnRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    let key: SMCKey
    let detail: String

    var description: String { "\(key): \(detail)" }
}

/// A target command's numbers, as the plane reads them out of its permit: the fan, the clamped
/// speed, and the floor the speed was clamped above (`AuthorisedFanTarget.lowestCommandableRPM`).
/// Not a permit: the turn body below the seam takes what the permit says, and
/// `WriteVerbAllowlistTests` holds every permit to the plane's verbs, which hand these on and keep
/// nothing.
struct TargetCommand: Sendable, Hashable {
    let fan: Int
    let rpm: Double
    let floor: Double
}

/// Where the write turns log, held by reference so every view of the plane logs through the one
/// instance (`PlaneViewTests` fails on a stored value a view would copy).
final class PlaneWriteLog: Sendable {
    let safety: SafetyLog

    init(_ safety: SafetyLog) {
        self.safety = safety
    }
}
