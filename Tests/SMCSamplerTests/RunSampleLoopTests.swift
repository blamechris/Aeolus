import Foundation
import SMCCore
import Testing
import os

@testable import smc_sampler

/// A `SensorProvider` that answers every requested key with a fixed, always-successful
/// reading — the loop's own arithmetic (deltas, tick counting) is what these tests exercise,
/// not `SMCCore`'s decoding, so a canned reading is all a case here needs.
private struct FakeSensorProvider: SensorProvider {
    let identifier = "fake"
    var isAvailable: Bool { get async { true } }

    func readAll() async throws -> [SensorReading] { [] }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        keys.map { key in
            SensorReadOutcome(
                key: key,
                result: .success(
                    SensorReading(
                        key: key, value: 42.0, kind: .unknown, providerIdentifier: identifier)))
        }
    }
}

/// An in-memory `LineSink`, lock-protected the same way `StandardOutputSink` protects the
/// real file descriptor — `runSampleLoop` writes synchronously and this must be safe to read
/// back from a different task than the one driving the loop.
private final class CapturingSink: LineSink {
    private let lock = OSAllocatedUnfairLock<[String]>(initialState: [])

    func write(_ line: String) {
        lock.withLock { $0.append(line) }
    }

    var lines: [String] {
        lock.withLock { $0 }
    }
}

/// Decodes one NDJSON `sample` line's two delta fields, `nil` standing for a JSON `null` —
/// matching `NDJSONTests`' own `NSNull` check, just extracted for reuse across the
/// tick-0/tick-1 assertions below.
private func deltas(ofLine line: String) throws -> (continuous: Int64?, suspending: Int64?) {
    let data = try #require(line.data(using: .utf8))
    let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let continuous = decoded["continuousDeltaNanoseconds"]
    let suspending = decoded["suspendingDeltaNanoseconds"]
    return (
        continuous is NSNull ? nil : (continuous as? Int64 ?? Int64(continuous as? Int ?? 0)),
        suspending is NSNull ? nil : (suspending as? Int64 ?? Int64(suspending as? Int ?? 0))
    )
}

@Suite("runSampleLoop")
struct RunSampleLoopTests {

    /// Mutation this kills: deleting the two assignments that update
    /// `previousContinuous`/`previousSuspending` at the end of each iteration — the loop
    /// still runs and still emits the right *count* of lines, but every tick after the
    /// first would report a `null` delta instead of just tick 0. See the finding this suite
    /// was written to close: the rebuilt binary under that mutation emitted
    /// `continuousDeltaNanoseconds:null` on every tick, destroying the field the hardware
    /// checklist reads.
    @Test("tick 0's deltas are null and tick 1's carry a real number")
    func tick0DeltasAreNullTick1AreNot() async throws {
        let sink = CapturingSink()
        var options = CommandLineOptions()
        options.intervalSeconds = 0.001
        options.tickCount = 2

        try await runSampleLoop(
            provider: FakeSensorProvider(),
            keys: ["F0Ac"],
            options: options,
            sink: sink,
            continuousStart: ContinuousClock.now,
            suspendingStart: SuspendingClock.now,
            tickState: TickState())

        #expect(sink.lines.count == 2)

        let firstDeltas = try deltas(ofLine: sink.lines[0])
        #expect(firstDeltas.continuous == nil)
        #expect(firstDeltas.suspending == nil)

        let secondDeltas = try deltas(ofLine: sink.lines[1])
        #expect(secondDeltas.continuous != nil)
        #expect(secondDeltas.suspending != nil)
    }

    @Test("--count ticks emits exactly that many sample lines, then returns")
    func boundedCountEmitsExactlyThatManyLines() async throws {
        let sink = CapturingSink()
        var options = CommandLineOptions()
        options.intervalSeconds = 0.001
        options.tickCount = 3
        let tickState = TickState()

        try await runSampleLoop(
            provider: FakeSensorProvider(),
            keys: ["F0Ac"],
            options: options,
            sink: sink,
            continuousStart: ContinuousClock.now,
            suspendingStart: SuspendingClock.now,
            tickState: tickState)

        #expect(sink.lines.count == 3)
        #expect(await tickState.tickCount() == 3)
    }

    /// Cancellation between ticks — the loop's own documented contract — must return
    /// normally rather than propagate `CancellationError`, exactly as
    /// `Task.sleep`'s `catch is CancellationError { return }` promises. An unbounded
    /// `--count` (`nil`) is used so the only way this test's task ends is the cancellation
    /// itself, not exhausting a tick count.
    @Test("cancellation between ticks returns cleanly, without throwing")
    func cancellationBetweenTicksReturnsCleanly() async throws {
        let sink = CapturingSink()
        var options = CommandLineOptions()
        options.intervalSeconds = 10.0
        options.tickCount = nil

        let task = Task {
            try await runSampleLoop(
                provider: FakeSensorProvider(),
                keys: ["F0Ac"],
                options: options,
                sink: sink,
                continuousStart: ContinuousClock.now,
                suspendingStart: SuspendingClock.now,
                tickState: TickState())
        }

        // Give tick 0 time to run and the loop time to reach its (10-second) sleep before
        // cancelling — cancelling before the first tick has run would prove nothing about
        // cancellation *between* ticks specifically.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        // Must not throw: a throw here is exactly the regression this test exists to catch.
        try await task.value
        #expect(sink.lines.count == 1)
    }
}
