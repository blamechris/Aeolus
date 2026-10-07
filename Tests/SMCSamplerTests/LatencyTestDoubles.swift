import Foundation
import SMCCore
import Testing
import os

@testable import smc_sampler

// The fakes `runLatencyLoop`'s tests share. Every name carries "Latency" (or is otherwise
// specific to it) so none can shadow the private fakes `RunSampleLoopTests` keeps for itself.

/// A `SensorProvider` whose answer to every call is scripted by `(call number, key)`, and
/// which remembers the `keys` argument of every call it received. Call number 0 is the
/// first call of any kind, so the warm-up reads are the first `keys.count` calls and the
/// first timed read is call number `keys.count`.
final class ScriptedLatencyProvider: SensorProvider {
    typealias Behavior =
        @Sendable (_ callNumber: Int, _ key: String) async throws -> Result<
            Double, SensorReadFailure
        >

    let identifier = "scripted-latency"
    var isAvailable: Bool { get async { true } }

    private let log = OSAllocatedUnfairLock<[[String]]>(initialState: [])
    private let behavior: Behavior

    init(behavior: @escaping Behavior = { _, _ in .success(1.0) }) {
        self.behavior = behavior
    }

    /// The `keys` argument of every `read(keys:)` call, in the order received.
    var calls: [[String]] { log.withLock { $0 } }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        let callNumber = log.withLock { calls -> Int in
            calls.append(keys)
            return calls.count - 1
        }
        var outcomes: [SensorReadOutcome] = []
        for key in keys {
            let result = try await behavior(callNumber, key)
            outcomes.append(
                SensorReadOutcome(
                    key: key,
                    result: result.map {
                        SensorReading(
                            key: key, value: $0, kind: .unknown, providerIdentifier: identifier)
                    }))
        }
        return outcomes
    }
}

/// An in-memory `LineSink` that decodes what it was given.
final class LatencyCapturingSink: LineSink {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])
    func write(_ line: String) { lock.withLock { $0.append(line) } }
    var lines: [String] { lock.withLock { $0 } }

    /// Every line decoded as a JSON object.
    func records() throws -> [[String: Any]] {
        try lines.map { line in
            let data = try #require(line.data(using: .utf8))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}

/// Stands in for `Task.sleep` and remembers how long each wait was asked to be, without
/// waiting at all.
final class WaitRecorder: Sendable {
    private let log = OSAllocatedUnfairLock<[UInt64]>(initialState: [])

    var nanoseconds: [UInt64] { log.withLock { $0 } }

    /// A closure over `self`, so it can be passed where the loop wants a `LatencySleep`.
    var sleeper: LatencySleep {
        { [self] nanoseconds in log.withLock { $0.append(nanoseconds) } }
    }
}

/// An ordered record of what the loop did, shared by the fakes that observe it.
final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

/// A sink that only notes, in the shared log, that a line of a given kind was written.
final class LoggingSink: LineSink {
    private let log: EventLog
    init(log: EventLog) { self.log = log }

    func write(_ line: String) {
        if line.contains("\"kind\":\"read\"") {
            log.add("write:read")
        } else if line.contains("\"kind\":\"latencySummary\"") {
            log.add("write:summary")
        } else {
            log.add("write:other")
        }
    }
}

/// A pair of clocks that stand still until a test moves them. Real `Instant`s are used, offset
/// from a base by an exact number of nanoseconds, so the loop's arithmetic is the production
/// arithmetic and its results are exact.
final class FakeTimeline: Sendable {
    private let elapsed = OSAllocatedUnfairLock<[Int64]>(initialState: [0, 0])
    let continuousBase = ContinuousClock.now
    let suspendingBase = SuspendingClock.now

    /// Moves the continuous clock by `continuous` ns and the suspending clock by `suspending`.
    func advance(continuous: Int64, suspending: Int64) {
        elapsed.withLock {
            $0[0] += continuous
            $0[1] += suspending
        }
    }

    func stamp() -> LatencyStamp {
        let now = elapsed.withLock { $0 }
        return LatencyStamp(
            continuous: continuousBase.advanced(by: .nanoseconds(now[0])),
            suspending: suspendingBase.advanced(by: .nanoseconds(now[1])))
    }
}

/// A provider that answers every key and reports, for each call, the real time at which it
/// was entered and left, as nanoseconds on `ContinuousClock` from `start`. The loop's own
/// stamps must enclose these, and the difference is everything the loop timed besides the call.
final class SpanReportingProvider: SensorProvider {
    let identifier = "span-reporting"
    var isAvailable: Bool { get async { true } }

    private let start: ContinuousClock.Instant
    private let log = OSAllocatedUnfairLock<[[Int64]]>(initialState: [])

    init(start: ContinuousClock.Instant) { self.start = start }

    /// One `[entry, exit]` pair per call, in order.
    var spans: [[Int64]] { log.withLock { $0 } }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        let entry = ClockNanoseconds.nanoseconds(from: ContinuousClock.now - start)
        let outcomes = keys.map { key in
            SensorReadOutcome(
                key: key,
                result: .success(
                    SensorReading(key: key, value: 1, kind: .unknown, providerIdentifier: "span")))
        }
        let exit = ClockNanoseconds.nanoseconds(from: ContinuousClock.now - start)
        log.withLock { $0.append([entry, exit]) }
        return outcomes
    }
}

struct LatencyTestBoom: Error, CustomStringConvertible {
    var description: String { "Boom" }
}

/// `runLatencyLoop` with every seam defaulted to production, so a test names only the ones it
/// is about.
func runLatencyLoopForTest(
    provider: some SensorProvider,
    keys: [String] = ["F0Ac"],
    count: Int,
    intervalSeconds: Double = 0,
    sink: some LineSink,
    continuousStart: ContinuousClock.Instant = ContinuousClock.now,
    tickState: TickState = TickState(),
    sleep: @escaping LatencySleep = taskLatencySleep,
    now: @escaping LatencyNow = clockLatencyNow
) async throws {
    try await runLatencyLoop(
        provider: provider, keys: keys, count: count, intervalSeconds: intervalSeconds,
        sink: sink, continuousStart: continuousStart, tickState: tickState, sleep: sleep,
        now: now)
}
