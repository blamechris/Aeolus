import FanKit
import Foundation
import SMCCore

// smc-sampler: a maintainer measurement tool, never shipped. See
// Tools/SMCSampler/README.md for what it is for and Package.swift's comment on this
// target for why it lives outside Sources/.
//
// Unlike Tools/PowerObserver, this tool depends on SMCCore and FanKit on purpose — its
// whole reason to exist is targeted subset reads of the SMC (#248). What it must never do
// is depend on AeolusHelper or touch the SMC write path; see
// Tests/SMCSamplerTests/ToolsSeamTests.swift for the tripwire that checks that against the
// source, and this file's own use of `SensorProvider.read(keys:)` — never
// `SMCConnection.write(_:to:)`, which SMCCore does not even export outside
// `@_spi(FanWrite)` — for why there is no route to a write here at all.

/// The default key set this tool samples when `--keys` is not given: this machine's
/// critical temperature cluster (mirroring
/// `Sources/AeolusHelper/Safety/CriticalSensorSet.swift`, resolved the same way — by
/// `HardwareIdentity.modelIdentifier`, never `uname -m`, per `CLAUDE.md` rule 9) plus every
/// enumerated fan's three keys.
///
/// ## Why this mirrors `CriticalSensorSet` rather than importing it
///
/// `CriticalSensorSet` is declared inside `Sources/AeolusHelper` and is not `public`, and
/// deliberately so — see that type's own documentation on why its initialiser is private
/// and no file outside the safety subsystem may construct one. Depending on `AeolusHelper`
/// from a tool under `Tools/` would also be exactly the coupling
/// `Tests/PowerObserverTests/ToolsSeamTests.swift` forbids for its own tool, and for the
/// same reason this one's own `ToolsSeamTests.swift` forbids it here: a maintainer
/// measurement tool has no business being able to reach the privilege boundary at all,
/// whether or not it happens to use that reach today.
///
/// `Tools/PowerObserver/PowerObserverCore.swift`'s `PowerMessage` enum already establishes
/// the pattern this follows: it re-derives the root power domain's message numbers rather
/// than importing `Sources/AeolusHelper/Lifecycle/SystemPowerObserver.swift`'s copy, for
/// the identical isolation reason. `criticalKeys(forModel:)` below is the same move applied
/// to the curated key list — a read-only mirror, kept deliberately small (one model, one
/// list) so a drift between the two is easy to notice and low-cost to fix, and never fed
/// back into any safety decision: this tool only ever prints what it reads.
enum MeasurementKeySet {

    /// `Mac16,5` (M4 Max, 12P/4E): the `TPD*`/`TRD*` die/package cluster.
    ///
    /// The exact key list `CriticalSensorSet.mac16x5` carries, as of the same
    /// 2026-08-20 enumeration `docs/SMC-RESEARCH.md` records — thirty-four keys, two
    /// prefixes times seventeen hexadecimal-digit-plus-`X` suffixes. Spelled out here
    /// again rather than generated from a shared table, matching
    /// `CriticalSensorSet.mac16x5`'s own comment that the list is a transcript of what
    /// enumeration returned, not a guess at a pattern — a second transcript of the same
    /// enumeration is not the kind of duplication this project's rules warn about; a third
    /// *derivation* of the pattern would be.
    private static let mac16x5CriticalKeys: [String] = {
        let suffixes = [
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "a", "b", "c", "d", "e", "f", "X",
        ]
        return ["TPD", "TRD"].flatMap { prefix in suffixes.map { prefix + $0 } }
    }()

    /// This machine's critical sensor keys, or the empty list for a machine nobody has
    /// measured — the same "blindness rather than a guess" answer
    /// `CriticalSensorSet.resolve(for:)` gives, since an unrecognised model has no curated
    /// set to mirror.
    static func criticalKeys(forModel model: String?) -> [String] {
        switch model {
        case "Mac16,5": return mac16x5CriticalKeys
        default: return []
        }
    }

    /// `F<n>Ac`/`F<n>Mn`/`F<n>Mx` for every fan index in `indices`, via the same key-naming
    /// convention `SMCFanEnumeration` already publishes — never a second copy of the
    /// convention itself, only of which indices to ask it for.
    static func fanKeys(forFanIndices indices: [Int]) -> [String] {
        indices.flatMap { index in
            [
                SMCFanEnumeration.actualKey(forFan: index),
                SMCFanEnumeration.minimumKey(forFan: index),
                SMCFanEnumeration.maximumKey(forFan: index),
            ]
        }
    }

    /// The default key set for `model`/`fanIndices`: critical keys first, then fan keys,
    /// with duplicates dropped and first-occurrence order preserved — a machine whose
    /// critical cluster happened to overlap a fan key (it never does today, but nothing
    /// requires that) would otherwise sample the same key twice per tick for no reason.
    static func defaultKeys(model: String?, fanIndices: [Int]) -> [String] {
        deduplicated(criticalKeys(forModel: model) + fanKeys(forFanIndices: fanIndices))
    }

    /// The keys this run will actually sample: `custom` verbatim (deduplicated, order
    /// preserved) when it is non-empty, the default set otherwise. `--keys` is meant to let
    /// a maintainer point this tool at an arbitrary key set for a specific question — see
    /// `Tools/SMCSampler/README.md` — not merely to narrow the default one, so an explicit
    /// but empty `--keys` (`--keys=`) is treated the same as omitting it rather than as a
    /// request to sample nothing forever.
    static func resolvedKeys(custom: [String], model: String?, fanIndices: [Int]) -> [String] {
        guard !custom.isEmpty else { return defaultKeys(model: model, fanIndices: fanIndices) }
        return deduplicated(custom)
    }

    private static func deduplicated(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(keys.count)
        for key in keys where seen.insert(key).inserted {
            result.append(key)
        }
        return result
    }
}

/// What `main()` derives from attempting fan enumeration before resolving the key set to
/// sample: the fan indices actually found (empty on failure), the human-readable
/// `keySource` string `SamplerStartRecord` records, and the
/// `fanEnumerationFailed`/`fanEnumerationFailureReason` pair that field's own documentation
/// explains the need for.
///
/// Pulled out of `SMCSamplerMain.swift` as a pure function over the already-caught
/// `Result`, the same move `b33abf8` made for `runSampleLoop` and for the identical
/// reason: `main()` is `@main` and unreachable by `@testable import`, so whatever decides
/// these three values has to live here to be exercised by anything other than `swift run`.
/// Before this existed, `SMCSamplerMain.swift:188-189` wired
/// `fanEnumerationFailed: fanEnumerationFailureReason != nil` directly against a local
/// variable no test could see — deleting that wiring left the full suite green.
struct FanEnumerationOutcome: Sendable, Equatable {
    let fanIndices: [Int]
    let keySource: String
    let fanEnumerationFailed: Bool
    let fanEnumerationFailureReason: String?

    /// `enumerationResult`: `.success(fanIndices)` when `SMCFanEnumeration.enumerate`
    /// returned normally, `.failure(error)` when it threw. `model` is
    /// `HardwareIdentity.current().modelIdentifier`, threaded through as a parameter
    /// rather than read again here so this stays a pure function of its inputs — the same
    /// reason `resolvedKeys(custom:model:fanIndices:)` above takes `model` rather than
    /// calling `HardwareIdentity.current()` itself.
    static func from(
        _ enumerationResult: Result<[Int], Error>,
        model: String?
    ) -> FanEnumerationOutcome {
        switch enumerationResult {
        case .success(let fanIndices):
            return FanEnumerationOutcome(
                fanIndices: fanIndices,
                keySource: "default(model:\(model ?? "unknown"),fans:\(fanIndices.count))",
                fanEnumerationFailed: false,
                fanEnumerationFailureReason: nil)
        case .failure(let error):
            return FanEnumerationOutcome(
                fanIndices: [],
                keySource: "default(model:\(model ?? "unknown"),fans:0)",
                fanEnumerationFailed: true,
                fanEnumerationFailureReason: "\(error)")
        }
    }
}

/// Parses `--keys=K1,K2,...` out of a raw comma-separated string into individual keys,
/// trimmed of surrounding whitespace and with empty entries dropped — so `--keys="F0Ac, F0Mn"`
/// and a trailing comma both behave the way a maintainer typing the flag by hand would
/// expect, rather than producing a spurious empty-string key that then reports
/// `.unknownKey("")` on every tick.
///
/// Malformed entries (not exactly four ASCII characters) are not filtered here — see
/// `CommandLineOptions.parse(_:)`'s documentation for why validation belongs to the caller,
/// not to this splitter.
enum KeyListParsing {
    static func parse(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// This process's command-line arguments, parsed into the three settings the brief calls
/// for: the tick interval, an optional tick count (run forever if omitted, the same
/// convention `fanctl watch --count` uses), and an optional custom key list. No
/// `ArgumentParser` dependency, matching `Tools/PowerObserver`'s own target, which takes no
/// arguments at all and depends on nothing beyond Foundation and IOKit; this tool's
/// dependency list is already wider (`SMCCore`, `FanKit`), and a hand-rolled parser over
/// three flags keeps it from growing a fourth dependency for a handful of `--flag=value`
/// pairs.
struct CommandLineOptions: Sendable, Equatable {
    var intervalSeconds: Double = 1.0
    var tickCount: Int?
    var keys: [String] = []

    enum ParseError: Error, Sendable, Equatable {
        case invalidInterval(String)
        case invalidCount(String)
        case malformedKey(String)
        case unrecognizedArgument(String)
    }

    /// Parses `arguments` (typically `CommandLine.arguments.dropFirst()`) into
    /// `CommandLineOptions`, or throws the first problem found. Recognises
    /// `--interval=<seconds>`, `--count=<n>`, and `--keys=<comma-separated keys>`, each also
    /// accepting a space instead of `=` (`--interval 2`) since that is the more common shape
    /// a maintainer types by hand. Every `--keys` entry is validated against `SMCKey`'s own
    /// four-ASCII-character rule at parse time — failing fast on a typo here is strictly
    /// better than discovering it as a `.unknownKey` on every tick of an unattended capture.
    static func parse(_ arguments: [String]) throws -> CommandLineOptions {
        var options = CommandLineOptions()
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            let (flag, inlineValue) = splitInlineValue(argument)

            func value() throws -> String {
                if let inlineValue { return inlineValue }
                let next = arguments.index(after: index)
                // A missing space-separated value is not only detectable at the end of
                // `arguments` — the very next token can itself be another flag
                // (`--interval --count 5`). A `--`-prefixed token is never a legitimate
                // value for any flag this parser recognises (a seconds count, a tick
                // count, or a comma-separated key list), so treating it as one silently
                // swallows the next flag and blames the wrong one for the resulting parse
                // failure. Reported the same way as the end-of-arguments case: the flag
                // that is missing its value, not the token that was almost consumed.
                guard next < arguments.endIndex, !arguments[next].hasPrefix("--") else {
                    throw ParseError.unrecognizedArgument(argument)
                }
                index = next
                return arguments[next]
            }

            switch flag {
            case "--interval":
                let raw = try value()
                guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
                    throw ParseError.invalidInterval(raw)
                }
                options.intervalSeconds = seconds
            case "--count":
                let raw = try value()
                guard let count = Int(raw), count > 0 else {
                    throw ParseError.invalidCount(raw)
                }
                options.tickCount = count
            case "--keys":
                let raw = try value()
                let parsed = KeyListParsing.parse(raw)
                for key in parsed where SMCKey(key) == nil {
                    throw ParseError.malformedKey(key)
                }
                options.keys = parsed
            default:
                throw ParseError.unrecognizedArgument(argument)
            }

            index = arguments.index(after: index)
        }

        return options
    }

    /// Splits `--flag=value` into `("--flag", "value")`, or returns `(argument, nil)` for a
    /// bare flag with no `=` — the space-separated form `parse(_:)` handles by consuming the
    /// following argument instead.
    private static func splitInlineValue(_ argument: String) -> (flag: String, value: String?) {
        guard let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (
            String(argument[argument.startIndex..<equals]),
            String(argument[argument.index(after: equals)...])
        )
    }
}

/// Pure integer arithmetic converting a `Duration` (as returned by subtracting two
/// `ContinuousClock.Instant`/`SuspendingClock.Instant` values) into nanoseconds.
///
/// Takes a `Duration` rather than the clock types themselves, which is what makes this
/// testable without a real clock: `Duration` is a plain value constructible from literal
/// seconds/attoseconds in a test, the same shape `PowerLatency.microseconds` in
/// `Tools/PowerObserver/PowerObserverCore.swift` takes raw nanosecond counts for.
enum ClockNanoseconds {
    /// `duration`'s length in nanoseconds, truncating any sub-nanosecond remainder.
    ///
    /// `Duration.components` gives `(seconds: Int64, attoseconds: Int64)`; one attosecond
    /// is 10^-18 s, so dividing by 10^9 converts the attosecond component to nanoseconds
    /// without ever materialising a `Double` and its rounding error. A negative duration
    /// (unreachable in production — every caller subtracts an earlier instant from a later
    /// one on a monotonic clock) still produces a signed answer rather than trapping,
    /// unlike `PowerLatency.microseconds`'s `UInt64` subtraction: `Duration.components` is
    /// already signed `Int64`, so there is no unsigned underflow to guard against here.
    static func nanoseconds(from duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }

    /// Nanoseconds elapsed from `start` to `end`, or `nil` if `end` is not after `start` —
    /// unreachable for a genuinely monotonic clock sampled in increasing tick order, but
    /// guarded rather than trusted for the same reason `PowerLatency.microseconds` guards
    /// its own unreachable branch: a `nil` delta is a visible, honest "this should not have
    /// happened" in the NDJSON rather than a negative number a reader might mistake for a
    /// clock that ran backwards by design.
    static func delta(from start: Int64, to end: Int64) -> Int64? {
        guard end >= start else { return nil }
        return end - start
    }
}

/// The wall clock half of every record — identical in shape and reasoning to
/// `Tools/PowerObserver/PowerObserverCore.swift`'s `WallClock`, and not shared with it for
/// the same reason `ToolsSeamScanner` is not shared: importing across `Tools/` targets
/// would recreate the coupling each tool's isolation tests exist to keep at zero.
enum WallClock {
    static func iso8601UTC(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// One line of NDJSON — identical in shape and reasoning to
/// `Tools/PowerObserver/PowerObserverCore.swift`'s `NDJSON`. See `WallClock`'s
/// documentation for why this is a second copy rather than a shared import.
enum NDJSON {
    enum EncodingFailure: Error, Sendable {
        case notUTF8
        case embeddedNewline
    }

    static func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingFailure.notUTF8
        }
        return try rejectingEmbeddedNewline(text)
    }

    static func rejectingEmbeddedNewline(_ text: String) throws -> String {
        guard !text.contains("\n") else { throw EncodingFailure.embeddedNewline }
        return text
    }
}

/// One key's outcome, as this tool reports it — `SensorReadOutcome`'s `Result` flattened
/// into a `status` string plus an optional value, because `Result<SensorReading,
/// SensorReadFailure>` has no `Encodable` conformance of its own and JSON has no sum type
/// to encode it as. `status` is always present; `value`/`kind` are present only on success,
/// and `failureReason` only on failure — the same "explicit absence, not a fabricated
/// number" rule `PowerEventRecord.ackLatencyMicroseconds` documents for its own optional
/// field.
struct KeyReading: Sendable, Hashable {
    let key: String
    let status: String
    let value: Double?
    let kind: String?
    let failureReason: String?

    /// Builds a `KeyReading` from one `SensorProvider.read(keys:)` outcome. `status` names
    /// are chosen to read plainly in a raw NDJSON line without a decoder: `"ok"`,
    /// `"unknownKey"`, `"readFailed"`, `"notDecodable"` — the same four cases
    /// `SensorReadFailure` already distinguishes, so a reader cross-referencing this
    /// against `SMCCore`'s own vocabulary finds the same four words.
    static func from(_ outcome: SensorReadOutcome) -> KeyReading {
        switch outcome.result {
        case .success(let reading):
            return KeyReading(
                key: outcome.key, status: "ok", value: reading.value,
                kind: reading.kind.rawValue, failureReason: nil)
        case .failure(.unknownKey):
            return KeyReading(
                key: outcome.key, status: "unknownKey", value: nil, kind: nil,
                failureReason: nil)
        case .failure(.readFailed(let reason)):
            return KeyReading(
                key: outcome.key, status: "readFailed", value: nil, kind: nil,
                failureReason: reason)
        case .failure(.notDecodable(let reason)):
            return KeyReading(
                key: outcome.key, status: "notDecodable", value: nil, kind: nil,
                failureReason: reason)
        }
    }
}

extension KeyReading: Encodable {
    private enum CodingKeys: String, CodingKey {
        case key, status, value, kind, failureReason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(status, forKey: .status)
        try container.encode(value, forKey: .value)
        try container.encode(kind, forKey: .kind)
        try container.encode(failureReason, forKey: .failureReason)
    }
}

/// The line emitted once at launch: hostname, hardware model, OS version, uid/pid, the
/// resolved interval, and — most importantly for reading the result later — the exact
/// key list this run is sampling and where it came from. A capture is only reproducible
/// and only auditable if the key list is recorded once, in the file, rather than left to
/// be reconstructed from "whatever the default was on the date this ran."
///
/// `fanEnumerationFailed`/`fanEnumerationFailureReason` exist because the invocation this
/// tool's own README documents — `swift run smc-sampler --interval=1 > capture.ndjson` —
/// captures stdout only. `SMCSamplerMain.swift` also writes a transient enumeration failure
/// to stderr, which that redirect never reaches, so without a field here the resulting file
/// would say `fans:0` whether enumeration failed transiently or the machine genuinely has
/// no fans — two situations a maintainer reading the file back later cannot tell apart,
/// even though the row 13 checklist entry that cites the file needs to. `Bool` rather than
/// an optional carrying the same information: a caller reading only `keySource`'s
/// `fans:0` cannot already distinguish the two cases, and a non-optional flag is present on
/// every start line, success included, rather than only surfacing on failure the way the
/// reason string does.
struct SamplerStartRecord: Encodable, Sendable {
    let kind = "start"
    let hostname: String
    let hwModel: String
    let osVersion: String
    let uid: UInt32
    let pid: Int32
    let intervalSeconds: Double
    let keys: [String]
    let keySource: String
    let fanEnumerationFailed: Bool
    let fanEnumerationFailureReason: String?
}

/// One tick: wall clock plus both monotonic clocks — `ContinuousClock`, which keeps
/// advancing across sleep, and `SuspendingClock`, which does not — each as nanoseconds
/// elapsed since the `start` line and as a delta from the previous tick (`nil` on tick 0,
/// where there is no previous tick). Both deltas together are what let a reader of this
/// capture see a sleep directly in the numbers: a `continuousDelta` far larger than
/// `suspendingDelta` on the same tick is a sleep `SuspendingClock` missed and
/// `ContinuousClock` did not — `wallClockUTC` (`Date`) advances across a sleep exactly as
/// `ContinuousClock` does, so it is not a clock this comparison is about — see
/// `docs/ADR/0007-safety-composition.md`'s assumption table and #210.
struct SampleRecord: Sendable {
    let kind = "sample"
    let tick: Int
    let wallClockUTC: String
    let continuousNanoseconds: Int64
    let continuousDeltaNanoseconds: Int64?
    let suspendingNanoseconds: Int64
    let suspendingDeltaNanoseconds: Int64?
    let readings: [KeyReading]
}

extension SampleRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, tick, wallClockUTC, continuousNanoseconds, continuousDeltaNanoseconds,
            suspendingNanoseconds, suspendingDeltaNanoseconds, readings
    }

    /// Written by hand, for the same reason `PowerEventRecord.encode(to:)` in
    /// `Tools/PowerObserver/PowerObserverCore.swift` is: the synthesized conformance would
    /// call `encodeIfPresent` for the two `Int64?` delta fields, which *omits the key
    /// entirely* when the value is `nil`. That would make tick 0's "no previous tick to
    /// diff against" indistinguishable from a future version of this tool that stopped
    /// computing deltas at all. An explicit JSON `null` says the first, plainly, forever.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(tick, forKey: .tick)
        try container.encode(wallClockUTC, forKey: .wallClockUTC)
        try container.encode(continuousNanoseconds, forKey: .continuousNanoseconds)
        try container.encode(continuousDeltaNanoseconds, forKey: .continuousDeltaNanoseconds)
        try container.encode(suspendingNanoseconds, forKey: .suspendingNanoseconds)
        try container.encode(suspendingDeltaNanoseconds, forKey: .suspendingDeltaNanoseconds)
        try container.encode(readings, forKey: .readings)
    }
}

/// The 1 Hz proof of life, both clocks — a missed sample tick is then distinguishable from
/// a suspended process, and a heartbeat gap that does not match a gap in `sample` ticks is
/// itself informative: it means the *read*, not the process, stalled.
struct SamplerHeartbeatRecord: Encodable, Sendable {
    let kind = "heartbeat"
    let wallClockUTC: String
    let continuousNanoseconds: Int64
    let suspendingNanoseconds: Int64
}

/// The line emitted on a clean `SIGINT`/`SIGTERM`/`SIGHUP` exit, or on reaching `--count`
/// ticks.
struct SamplerStopRecord: Encodable, Sendable {
    let kind = "stop"
    let totalTicks: Int
    let finalContinuousNanoseconds: Int64
    let finalSuspendingNanoseconds: Int64
}

/// How many ticks this run has completed so far, held as an actor so the sample loop and
/// the signal handler can both read it without a data race — the same shape
/// `Tools/PowerObserver/PowerObserverCore.swift`'s `EventCounters` uses for its own
/// cross-task count.
actor TickState {
    private var count = 0

    /// Called once per completed tick, from the sample loop only.
    func recordTick() { count += 1 }

    /// The count so far. Safe to call at any time, including from a signal handler's task
    /// while a tick could in principle still be in flight.
    func tickCount() -> Int { count }
}

/// The nanosecond duration `Task.sleep(nanoseconds:)` waits for a given `--interval`,
/// clamped rather than trapping — identical reasoning to
/// `Sources/fanctl/WatchCommand.swift`'s `SystemWatchClock.clampedNanoseconds(forSeconds:)`,
/// duplicated rather than imported because `fanctl` is a separate executable target this
/// tool has no reason to depend on for one clamp. `CommandLineOptions.parse(_:)` already
/// rejects a non-finite or non-positive `--interval`, but not one merely too large to
/// convert — see that type's sibling for the identical two-line-of-defence argument.
enum SamplerInterval {
    static func clampedNanoseconds(forSeconds seconds: Double) -> UInt64 {
        let nanoseconds = max(0, seconds * 1_000_000_000).rounded()
        return UInt64(exactly: nanoseconds) ?? UInt64.max
    }
}

/// What `runSampleLoop` needs from an output destination: one line, written synchronously.
/// `SMCSamplerMain.swift`'s `StandardOutputSink` is the production conformer; `RunSampleLoopTests`
/// supplies an in-memory one, which is the entire reason this protocol exists rather than the
/// loop taking `StandardOutputSink` directly — a concrete `FileHandle`-backed sink cannot be
/// asserted against without a subprocess, and `runSampleLoop` living in `SMCSamplerMain.swift`
/// (the `@main` file) could not be reached by `@testable import` at all.
protocol LineSink: Sendable {
    func write(_ line: String)
}

/// The tick loop: read the resolved key set, emit one `sample` line, wait `--interval`
/// seconds, repeat — until `--count` ticks have run (if given) or the surrounding `Task` is
/// cancelled. Modelled on `Sources/fanctl/WatchCommand.swift`'s `WatchCommand.run`: a single
/// read failure ends the loop with that error, exactly as one `fanctl list` invocation
/// would, and only cancellation between ticks is a *clean* stop.
///
/// Lives here rather than in `SMCSamplerMain.swift` so `RunSampleLoopTests` can drive it
/// against a fake `SensorProvider` and an in-memory `LineSink` via `@testable import
/// smc_sampler` — nothing in `@main`'s file is reachable that way. See that suite for the
/// tick-0-vs-tick-1 delta assertion and the exact double-stop-line regression this loop's
/// own history records (this function's documentation on cancellation, and
/// `installOrderlyExit`'s in `SMCSamplerMain.swift`).
func runSampleLoop(
    provider: some SensorProvider,
    keys: [String],
    options: CommandLineOptions,
    sink: some LineSink,
    continuousStart: ContinuousClock.Instant,
    suspendingStart: SuspendingClock.Instant,
    tickState: TickState
) async throws {
    var previousContinuous: Int64?
    var previousSuspending: Int64?
    var tick = 0

    while true {
        let outcomes = try await provider.read(keys: keys)

        let continuousNanoseconds = ClockNanoseconds.nanoseconds(
            from: ContinuousClock.now - continuousStart)
        let suspendingNanoseconds = ClockNanoseconds.nanoseconds(
            from: SuspendingClock.now - suspendingStart)

        let record = SampleRecord(
            tick: tick,
            wallClockUTC: WallClock.iso8601UTC(),
            continuousNanoseconds: continuousNanoseconds,
            continuousDeltaNanoseconds: previousContinuous.flatMap {
                ClockNanoseconds.delta(from: $0, to: continuousNanoseconds)
            },
            suspendingNanoseconds: suspendingNanoseconds,
            suspendingDeltaNanoseconds: previousSuspending.flatMap {
                ClockNanoseconds.delta(from: $0, to: suspendingNanoseconds)
            },
            readings: outcomes.map(KeyReading.from))

        sink.write(try NDJSON.line(record))
        await tickState.recordTick()

        previousContinuous = continuousNanoseconds
        previousSuspending = suspendingNanoseconds
        tick += 1

        if let count = options.tickCount, tick >= count {
            return
        }
        do {
            try await Task.sleep(
                nanoseconds: SamplerInterval.clampedNanoseconds(forSeconds: options.intervalSeconds)
            )
        } catch is CancellationError {
            return
        }
    }
}
