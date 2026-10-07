import Foundation
import SMCCore
import Testing

@testable import smc_sampler

/// `runLatencyLoop`'s behaviour: what is warmed and what is timed, how failures and
/// cancellation end a run, and when it waits. Where its two clock stamps sit is in
/// `RunLatencyLoopTimingTests`; the fakes are in `LatencyTestDoubles`.
@Suite("runLatencyLoop")
struct RunLatencyLoopTests {

    // MARK: - Shape

    /// The central claim of the instrument: warm-up reads happen first, once per key, are
    /// not recorded, and every timed read is a single-key call — one key per call is what
    /// makes one timed read one `READ_BYTES` round trip.
    @Test("warm-up once per key, untimed and unrecorded; then one single-key call per read")
    func warmupThenSingleKeyCalls() async throws {
        let provider = ScriptedLatencyProvider()
        let sink = LatencyCapturingSink()
        let tickState = TickState()

        try await runLatencyLoopForTest(
            provider: provider, keys: ["F0Ac", "F1Ac"], count: 5, sink: sink,
            tickState: tickState)

        #expect(
            provider.calls == [
                ["F0Ac"], ["F1Ac"],  // warm-up
                ["F0Ac"], ["F1Ac"], ["F0Ac"], ["F1Ac"], ["F0Ac"],  // five timed reads
            ])
        #expect(provider.calls.allSatisfy { $0.count == 1 })

        let records = try sink.records()
        #expect(records.count == 6, "five read lines and one summary, nothing for the warm-up")
        #expect(records.prefix(5).allSatisfy { $0["kind"] as? String == "read" })
        #expect(records.last?["kind"] as? String == "latencySummary")
        #expect(records.prefix(5).map { $0["index"] as? Int } == [0, 1, 2, 3, 4])
        #expect(
            records.prefix(5).map { $0["key"] as? String }
                == ["F0Ac", "F1Ac", "F0Ac", "F1Ac", "F0Ac"])
        #expect(await tickState.tickCount() == 5)

        let summary = try #require(records.last)
        #expect(summary["count"] as? Int == 5)
        #expect(summary["okCount"] as? Int == 5)
        #expect(summary["requestedCount"] as? Int == 5)
        #expect(summary["interrupted"] as? Bool == false)
        let warmup = try #require(summary["warmup"] as? [[String: Any]])
        #expect(warmup.map { $0["key"] as? String } == ["F0Ac", "F1Ac"])
        #expect(warmup.allSatisfy { $0["status"] as? String == "ok" })
    }

    @Test("a count smaller than the key set reads only the first keys, but warms them all")
    func countSmallerThanKeySet() async throws {
        let provider = ScriptedLatencyProvider()
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(
            provider: provider, keys: ["F0Ac", "F1Ac", "F2Ac"], count: 1, sink: sink)
        #expect(provider.calls == [["F0Ac"], ["F1Ac"], ["F2Ac"], ["F0Ac"]])
        #expect(try sink.records().count == 2)
    }

    // MARK: - Failures

    @Test("a failed read is recorded with its status and reason, and the run carries on")
    func failedReadsAreRecordedAndTheRunContinues() async throws {
        // Call 0 is the warm-up; fail the second and fourth timed reads (calls 2 and 4).
        let provider = ScriptedLatencyProvider { callNumber, _ in
            [2, 4].contains(callNumber)
                ? .failure(.readFailed(reason: "firmware said no")) : .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 5, sink: sink)

        let records = try sink.records()
        #expect(records.count == 6)
        #expect(
            records.prefix(5).map { $0["status"] as? String }
                == ["ok", "readFailed", "ok", "readFailed", "ok"])
        #expect(records[1]["failureReason"] as? String == "firmware said no")
        #expect(records[0]["failureReason"] is NSNull)

        let summary = try #require(records.last)
        #expect(summary["count"] as? Int == 5)
        #expect(summary["okCount"] as? Int == 3)
        #expect(summary["failureCount"] as? Int == 2)
        #expect(summary["percentileSampleSize"] as? Int == 3, "readFailed is not percentiled")
    }

    @Test("a provider that throws mid-run is recorded as providerError, not fatal")
    func thrownErrorMidRunIsRecorded() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            if callNumber == 2 { throw LatencyTestBoom() }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 3, sink: sink)

        let records = try sink.records()
        #expect(records.prefix(3).map { $0["status"] as? String } == ["ok", "providerError", "ok"])
        #expect(records[1]["failureReason"] as? String == "Boom")
        #expect(records.last?["failureCount"] as? Int == 1)
    }

    /// A read that ends in `CancellationError` was interrupted, not slow and not failed. If
    /// it were recorded it would enter the failure count with a duration that is the time
    /// until the signal arrived, which is a number about the maintainer, not the SMC.
    @Test("a read that ends in CancellationError is not a data point, and ends the run")
    func cancellationErrorIsNotRecorded() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            if callNumber == 3 { throw CancellationError() }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 10, sink: sink)

        let records = try sink.records()
        #expect(records.count == 3, "two reads and the summary")
        #expect(records.prefix(2).allSatisfy { $0["status"] as? String == "ok" })
        let summary = try #require(records.last)
        #expect(summary["count"] as? Int == 2)
        #expect(summary["failureCount"] as? Int == 0)
        #expect(summary["interrupted"] as? Bool == true)
    }

    @Test("a warm-up that throws ends the run before any read is recorded")
    func warmupThrowEndsTheRun() async {
        let provider = ScriptedLatencyProvider { _, _ in throw LatencyTestBoom() }
        let sink = LatencyCapturingSink()
        await #expect(throws: LatencyTestBoom.self) {
            try await runLatencyLoopForTest(provider: provider, count: 3, sink: sink)
        }
        #expect(sink.lines.isEmpty)
    }

    /// A completed `READ_BYTES` whose value is not a number is still a round trip. The read
    /// line keeps the status that says what the value was not; the summary counts it as a
    /// failure, and percentiles it.
    @Test("a notDecodable read keeps its status on the line and still counts as a round trip")
    func notDecodableReadsAreLatencySamples() async throws {
        let provider = ScriptedLatencyProvider { _, _ in
            .failure(.notDecodable(reason: "RPlt is not numeric"))
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, keys: ["RPlt"], count: 4, sink: sink)

        let records = try sink.records()
        #expect(
            records.prefix(4).allSatisfy {
                $0["status"] as? String == "notDecodable"
                    && $0["failureReason"] as? String == "RPlt is not numeric"
            })
        let summary = try #require(records.last)
        #expect(summary["okCount"] as? Int == 0)
        #expect(summary["failureCount"] as? Int == 4)
        #expect(summary["percentileSampleSize"] as? Int == 4)
        #expect(summary["p50ContinuousNanoseconds"] is Int)
        #expect(summary["p50SuspendingNanoseconds"] is Int)
    }

    @Test("a warm-up failure carries its reason into the summary")
    func warmupFailureReasonIsCarried() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            callNumber == 0 ? .failure(.readFailed(reason: "firmware(code: 132)")) : .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 1, sink: sink)

        let summary = try #require(try sink.records().last)
        let warmup = try #require(summary["warmup"] as? [[String: Any]])
        #expect(warmup.first?["status"] as? String == "readFailed")
        #expect(warmup.first?["failureReason"] as? String == "firmware(code: 132)")
    }

    @Test("a warm-up that is merely refused is reported in the summary and the run carries on")
    func refusedWarmupIsReported() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            callNumber == 0 ? .failure(.unknownKey("F0Ac")) : .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 2, sink: sink)

        let summary = try #require(try sink.records().last)
        let warmup = try #require(summary["warmup"] as? [[String: Any]])
        #expect(warmup.first?["status"] as? String == "unknownKey")
        #expect(summary["okCount"] as? Int == 2)
    }

    // MARK: - Cancellation

    /// A signal cancels the surrounding task. Back-to-back reads have no `Task.sleep` to
    /// notice that, so the loop must check explicitly — and must still write the summary
    /// for the reads already done. The fake cancels the task from inside the fourth read,
    /// so the outcome is deterministic: exactly four reads recorded.
    @Test("cancellation between back-to-back reads stops the run and still writes the summary")
    func cancellationStopsBackToBackReadsAndWritesTheSummary() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            // Call 0 is the warm-up, so call 4 is the fourth timed read.
            if callNumber == 4 { withUnsafeCurrentTask { $0?.cancel() } }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()
        let tickState = TickState()

        let task = Task {
            try await runLatencyLoopForTest(
                provider: provider, count: 1_000, sink: sink, tickState: tickState)
        }
        try await task.value  // must not throw

        let records = try sink.records()
        #expect(records.count == 5, "four reads and the summary")
        let summary = try #require(records.last)
        #expect(summary["kind"] as? String == "latencySummary")
        #expect(summary["count"] as? Int == 4)
        #expect(summary["requestedCount"] as? Int == 1_000)
        #expect(summary["interrupted"] as? Bool == true)
        #expect(await tickState.tickCount() == 4)
    }

    /// `Task.sleep` reports cancellation by throwing `CancellationError`, which is what a
    /// signal during an explicit `--interval` wait turns into. The fake throws it on the
    /// first wait, so the run is cut short after exactly one read, with no real time involved.
    @Test("cancellation during an explicit --interval wait returns cleanly with the summary")
    func cancellationDuringIntervalWait() async throws {
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(
            provider: ScriptedLatencyProvider(), count: 5, intervalSeconds: 10, sink: sink,
            sleep: { _ in throw CancellationError() })

        let records = try sink.records()
        #expect(records.count == 2, "the first read and the summary")
        #expect(records.last?["kind"] as? String == "latencySummary")
        #expect(records.last?["count"] as? Int == 1)
        #expect(records.last?["interrupted"] as? Bool == true)
    }

    // MARK: - Pacing

    /// The waits are counted rather than timed. A test that asserted an upper bound on
    /// elapsed time failed on CI with 17 s elapsed for a 0.5 s wait, because the runner was
    /// busy; counting the calls to `sleep` cannot be slowed down by anything.
    @Test("an interval of zero reads back to back, without waiting")
    func zeroIntervalDoesNotWait() async throws {
        let sink = LatencyCapturingSink()
        let waits = WaitRecorder()
        try await runLatencyLoopForTest(
            provider: ScriptedLatencyProvider(), count: 20, intervalSeconds: 0, sink: sink,
            sleep: waits.sleeper)
        #expect(waits.nanoseconds.isEmpty)
        #expect(try sink.records().count == 21)
    }

    /// Between reads, never after the last: `count - 1` waits, each the whole interval. A
    /// trailing wait would add a full interval of dead time to every run for nothing.
    @Test("an explicit interval waits between reads, and not after the last one")
    func explicitIntervalWaitsBetweenReadsOnly() async throws {
        let sink = LatencyCapturingSink()
        let waits = WaitRecorder()
        try await runLatencyLoopForTest(
            provider: ScriptedLatencyProvider(), count: 3, intervalSeconds: 0.5, sink: sink,
            sleep: waits.sleeper)
        #expect(waits.nanoseconds == [500_000_000, 500_000_000])
    }

    /// The one test that uses the real clock, and it asserts only a lower bound: `Task.sleep`
    /// never returns early, however busy the machine is, so this cannot flake. It proves the
    /// production wait is wired to the interval at all.
    @Test("the production wait really waits at least the interval")
    func productionWaitIsRealAndAtLeastTheInterval() async throws {
        let sink = LatencyCapturingSink()
        let start = ContinuousClock.now
        try await runLatencyLoopForTest(
            provider: ScriptedLatencyProvider(), count: 2, intervalSeconds: 0.5, sink: sink)
        #expect(ContinuousClock.now - start >= .milliseconds(450))
    }
}
