import Foundation
import SMCCore

// smc-sampler --latency: how long does one SMC round trip take?
//
// The ordinary mode records *when* each tick happened; this mode records *how long each
// read took*. It exists to give #296 a measured bound D for ADR 0012's watchdog (the H1
// hypothesis in docs/ADR/0012-a-round-trip-that-does-not-return-ends-the-helper.md): D must
// be at least 100x the observed maximum, so the maximum, and the tail below it, are the
// numbers wanted. See Tools/SMCSampler/README.md for the exact commands for each condition.
//
// Everything here reads through the same `SensorProvider` the ordinary mode uses. There is
// no second route to the SMC, and no route to its write path.

/// One timed read, as the NDJSON `read` line.
///
/// `continuousNanoseconds` and `suspendingNanoseconds` are the **duration of this read** on
/// each clock — unlike `SampleRecord`, whose fields of the same name are offsets since the
/// `start` line. They are recorded separately so a read that straddled a sleep shows as a
/// `continuousNanoseconds` far above its `suspendingNanoseconds`: ADR 0012 I3 ages a call in
/// flight on `SuspendingClock`, so that is the figure the watchdog would see, and the
/// continuous one is what a stopwatch would. `atContinuousNanoseconds` is when the read was
/// *issued*, as an offset on `ContinuousClock` from the `start` line, so a slow read can be
/// placed against a lid close or a `fanctl` walk.
struct LatencyReadRecord: Sendable, Equatable {
    /// The `status` of a read that returned a decoded value.
    static let okStatus = "ok"
    /// The `status` of a read whose `READ_BYTES` returned but whose value is not a number
    /// (a string or flag key, say). The round trip completed, so it is a latency sample; it
    /// is still reported as a non-`ok` status so the read line says what the value was not.
    static let notDecodableStatus = "notDecodable"

    /// Whether this read is a completed round trip, and so goes into the percentiles: `ok`,
    /// or `notDecodable`. Any other status is counted but kept out, because the status does
    /// not say whether a round trip was made at all (a key that is not readable makes none).
    var isCompletedRoundTrip: Bool {
        status == Self.okStatus || status == Self.notDecodableStatus
    }

    let kind = "read"
    let index: Int
    let key: String
    let status: String
    let failureReason: String?
    let continuousNanoseconds: Int64
    let suspendingNanoseconds: Int64
    let atContinuousNanoseconds: Int64
}

extension LatencyReadRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, index, key, status, failureReason, continuousNanoseconds,
            suspendingNanoseconds, atContinuousNanoseconds
    }

    /// Written by hand so a read that did not fail carries `"failureReason":null` rather
    /// than no such key — the same reason `SampleRecord.encode(to:)` documents. An absent
    /// key could equally mean a version of this tool that stopped reporting reasons.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(index, forKey: .index)
        try container.encode(key, forKey: .key)
        try container.encode(status, forKey: .status)
        try container.encode(failureReason, forKey: .failureReason)
        try container.encode(continuousNanoseconds, forKey: .continuousNanoseconds)
        try container.encode(suspendingNanoseconds, forKey: .suspendingNanoseconds)
        try container.encode(atContinuousNanoseconds, forKey: .atContinuousNanoseconds)
    }
}

/// How one key's untimed warm-up read ended. Reported in the summary so that "each timed
/// read is exactly one round trip" can be checked against the capture instead of taken on
/// trust. A warm-up that ended `"ok"` or `"notDecodable"` completed its `READ_BYTES`, so the
/// metadata is cached; any other status means it may not be.
///
/// `failureReason` is carried because the status alone cannot say which half failed. A
/// `readFailed` whose reason is a `READ_KEYINFO` error leaves the metadata uncached, so every
/// timed read of that key is itself a `READ_KEYINFO` trip; one whose reason is a `READ_BYTES`
/// error leaves it cached, and every timed read is a `READ_BYTES` trip that fails.
struct LatencyWarmupOutcome: Sendable, Equatable {
    let key: String
    let status: String
    let failureReason: String?

    init(key: String, status: String, failureReason: String? = nil) {
        self.key = key
        self.status = status
        self.failureReason = failureReason
    }
}

extension LatencyWarmupOutcome: Encodable {
    private enum CodingKeys: String, CodingKey {
        case key, status, failureReason
    }

    /// Written by hand for the explicit `"failureReason":null` — see
    /// `LatencyReadRecord.encode(to:)`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(status, forKey: .status)
        try container.encode(failureReason, forKey: .failureReason)
    }
}

/// One entry of a summary's list of slowest reads. Drawn from *every* read, failures
/// included: a read that took seconds to fail is exactly what a watchdog bound has to
/// survive, and hiding it behind "failures are not percentiled" would hide the finding.
struct LatencySlowRead: Sendable, Equatable, Encodable {
    let index: Int
    let key: String
    let status: String
    let continuousNanoseconds: Int64
    let suspendingNanoseconds: Int64
    let atContinuousNanoseconds: Int64

    init(_ read: LatencyReadRecord) {
        index = read.index
        key = read.key
        status = read.status
        continuousNanoseconds = read.continuousNanoseconds
        suspendingNanoseconds = read.suspendingNanoseconds
        atContinuousNanoseconds = read.atContinuousNanoseconds
    }
}

/// How one read's answer becomes the `status` and `failureReason` of its `read` line.
enum LatencyReadClassification {
    /// The provider itself threw — the connection could not be opened, say — rather than
    /// answering with a per-key outcome.
    static let providerErrorStatus = "providerError"
    /// The provider answered, but not for the key asked about. Never read as success.
    static let noOutcomeStatus = "noOutcome"

    /// The per-key statuses are `KeyReading`'s own (`ok`, `unknownKey`, `readFailed`,
    /// `notDecodable`), so the one vocabulary appears in both modes' output.
    static func classify(
        _ answer: Result<[SensorReadOutcome], Error>, key: String
    ) -> (status: String, failureReason: String?) {
        switch answer {
        case .failure(let error):
            return (providerErrorStatus, "\(error)")
        case .success(let outcomes):
            guard let outcome = outcomes.first(where: { $0.key == key }) else {
                return (noOutcomeStatus, "the provider returned no outcome for \(key)")
            }
            let reading = KeyReading.from(outcome)
            return (reading.status, reading.failureReason)
        }
    }
}

/// How `runLatencyLoop` waits between reads: nanoseconds in, throws `CancellationError` when
/// the surrounding task is cancelled.
typealias LatencySleep = @Sendable (UInt64) async throws -> Void

/// The production wait: `Task.sleep`.
func taskLatencySleep(nanoseconds: UInt64) async throws {
    try await Task.sleep(nanoseconds: nanoseconds)
}

/// One reading of both monotonic clocks, taken together.
struct LatencyStamp: Sendable {
    let continuous: ContinuousClock.Instant
    let suspending: SuspendingClock.Instant
}

/// How `runLatencyLoop` reads the clocks: once before a read and once after it, and at no
/// other time.
typealias LatencyNow = @Sendable () -> LatencyStamp

/// The production clocks.
func clockLatencyNow() -> LatencyStamp {
    LatencyStamp(continuous: ContinuousClock.now, suspending: SuspendingClock.now)
}

/// The latency loop: warm every key once, untimed; then take `count` timed single-key
/// reads, back to back unless `intervalSeconds` is positive; then write the summary.
///
/// ## Why timing one read times one round trip
///
/// `SMCConnection.read(_:)` looks the key's metadata (`READ_KEYINFO`) up in a cache first and
/// asks firmware only on a miss. Metadata is firmware-static and stays cached for the life of
/// the connection; *values* are never cached, so every read issues a fresh `READ_BYTES`. The
/// untimed warm-up read of each key is what moves its metadata from "miss" to "hit". After it,
/// one `read(keys: [key])` is exactly one `READ_BYTES` call — one `IOConnectCallStructMethod`
/// — and "time one read" and "time one round trip" are the same measurement. (On Apple
/// Silicon `F0Ac` is a four-byte `flt`; on Intel it is a two-byte `fpe2`. Either way it is a
/// non-empty readable value, so neither of the two cases that make no round trip applies to
/// it: a key that is not readable, or one declaring a zero-length value. If a `--keys` key
/// has either, its reads fail or finish implausibly fast, and the `warmup` field and the
/// per-read `status` say so.) The warm-up exists for this alone; its duration is never
/// recorded.
///
/// One key per call is the other half of it: `provider.read(keys:)` with several keys is
/// several round trips under one `await`, and timing that would report their sum.
///
/// The timed region is the `provider.read(keys:)` call, so it also contains the Swift around
/// the round trip — two actor hops, a dictionary, the outcome mapping — and whatever it costs
/// for the task to be woken when the call returns. This tool does not measure that cost, and
/// it need not be small: a paced run's median was observed at about twice a back-to-back
/// run's, which looks like wake-up latency inside the span. The figure is therefore an upper
/// bound on the round trip and never an underestimate, which is the direction a wedge bound
/// can safely err in. It is not the round trip itself.
///
/// ## What reaches the file, and when
///
/// A `read` line is written synchronously after the call returns and its end stamp is taken:
/// encoding it and the `write(2)` (under a lock shared with the heartbeat) happen between
/// reads, outside the timed span, so they inflate no figure — but "back to back" has a gap of
/// tens of microseconds between reads, and the loop is not hammering the SMC literally
/// continuously. It also means a read still in flight when the process is killed with
/// `SIGKILL`, or wedged inside the kernel, leaves **no line at all**: the evidence in that case
/// is `heartbeat` lines continuing with no further `read` lines.
///
/// ## Failures and signals
///
/// A failed read is data, not the end of the run: it is recorded with its status and reason
/// and the loop continues, because failing reads during a dark wake are one of the four
/// conditions #296 asks about. The two exceptions are a warm-up that *throws* (the SMC is not
/// reachable at all, so there is nothing to measure, and the error propagates like
/// `runSampleLoop`'s) and cancellation. Cancellation — what `installOrderlyExit` does on
/// `SIGINT`/`SIGTERM`/`SIGHUP` — is checked between reads, since back-to-back reads have no
/// `Task.sleep` to notice it, and a cancelled run still writes its summary for the reads done
/// so far. `main()` remains the one place that writes the `stop` line.
///
/// ## Seams
///
/// `sleep` is the wait between reads when `intervalSeconds` is positive: `Task.sleep` in
/// production. It is a parameter so tests can count the waits and make one throw, instead of
/// asserting on wall-clock time — an upper bound on elapsed time is a test that fails when
/// the machine running it is busy, and CI is exactly that.
///
/// `now` reads both clocks, and is called exactly twice per read: once immediately before the
/// provider call and once immediately after it. Tests give it a clock that only the fake
/// provider advances, and record the order of `now`, the call and the sink write, which pins
/// the placement of both stamps without asserting on time.
func runLatencyLoop(
    provider: some SensorProvider,
    keys: [String],
    count: Int,
    intervalSeconds: Double,
    sink: some LineSink,
    continuousStart: ContinuousClock.Instant,
    tickState: TickState,
    sleep: LatencySleep = taskLatencySleep,
    now: LatencyNow = clockLatencyNow
) async throws {
    var warmup: [LatencyWarmupOutcome] = []
    for key in keys {
        let outcomes = try await provider.read(keys: [key])
        let classified = LatencyReadClassification.classify(.success(outcomes), key: key)
        warmup.append(
            LatencyWarmupOutcome(
                key: key, status: classified.status, failureReason: classified.failureReason))
    }

    var accumulator = LatencyAccumulator()
    var index = 0

    while index < count, !keys.isEmpty, !Task.isCancelled {
        let key = keys[index % keys.count]

        let before = now()
        let answer: Result<[SensorReadOutcome], Error>
        do {
            answer = .success(try await provider.read(keys: [key]))
        } catch {
            answer = .failure(error)
        }
        let after = now()

        // A read cut short by cancellation was not a failed read; it is not a data point.
        if case .failure(let error) = answer, error is CancellationError { break }

        let classified = LatencyReadClassification.classify(answer, key: key)
        let record = LatencyReadRecord(
            index: index, key: key, status: classified.status,
            failureReason: classified.failureReason,
            continuousNanoseconds: ClockNanoseconds.nanoseconds(
                from: after.continuous - before.continuous),
            suspendingNanoseconds: ClockNanoseconds.nanoseconds(
                from: after.suspending - before.suspending),
            atContinuousNanoseconds: ClockNanoseconds.nanoseconds(
                from: before.continuous - continuousStart))

        accumulator.record(record)
        sink.write(try NDJSON.line(record))
        await tickState.recordTick()
        index += 1

        // Between reads and never after the last; and not at all when back to back.
        if index < count, intervalSeconds > 0 {
            do {
                try await sleep(SamplerInterval.clampedNanoseconds(forSeconds: intervalSeconds))
            } catch is CancellationError {
                break
            }
        }
    }

    sink.write(try NDJSON.line(accumulator.summary(requestedCount: count, warmup: warmup)))
}
