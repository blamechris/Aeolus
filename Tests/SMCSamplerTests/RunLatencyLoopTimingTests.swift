import Foundation
import Testing

@testable import smc_sampler

/// Where `runLatencyLoop`'s two stamps sit, and what the figures it records are made of.
/// Everything here is exact or asserts a lower bound, except one test that asserts the
/// minimum over 200 reads; none asserts an upper bound on how long a read took, because a
/// test that does fails whenever the machine running it is busy.
@Suite("runLatencyLoop timing")
struct RunLatencyLoopTimingTests {

    // MARK: - On the real clocks

    /// Mutation this kills: taking the end timestamp before the provider call (or the start
    /// after it). The fake takes at least two milliseconds to answer a timed read, so a
    /// recorded duration below that means the clocks were not bracketing the call. Both
    /// clocks are asserted separately because each is read separately.
    @Test("each read's durations bracket the provider call on both clocks")
    func durationsBracketTheCall() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            if callNumber >= 1 { try await Task.sleep(nanoseconds: 2_000_000) }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()
        try await runLatencyLoopForTest(provider: provider, count: 3, sink: sink)

        let reads = try sink.records().prefix(3)
        for read in reads {
            let continuous = try #require(read["continuousNanoseconds"] as? Int)
            let suspending = try #require(read["suspendingNanoseconds"] as? Int)
            #expect(continuous >= 1_500_000, "continuous duration \(continuous) ns < 2 ms sleep")
            #expect(suspending >= 1_500_000, "suspending duration \(suspending) ns < 2 ms sleep")
        }
    }

    /// Only the first timed read is slow (call 0 is the warm-up, call 1 the first timed
    /// read), so the second read is issued about 50 ms after the first one *was* and about
    /// zero after it *finished*. An offset taken when a read ends instead of when it is
    /// issued would put the second read's offset almost on top of the first's, and the
    /// `at >= previousEnd` check below would fail.
    @Test("offsets are measured from the start instant, at the moment each read is issued")
    func offsetsAreFromTheStartInstant() async throws {
        let provider = ScriptedLatencyProvider { callNumber, _ in
            if callNumber == 1 { try await Task.sleep(nanoseconds: 50_000_000) }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()
        // The run "started" five seconds ago, so every offset must be at least five seconds.
        let start = ContinuousClock.now.advanced(by: .seconds(-5))
        try await runLatencyLoopForTest(
            provider: provider, count: 4, sink: sink, continuousStart: start)

        let reads = Array(try sink.records().prefix(4))
        var previousEnd = 0
        for read in reads {
            let at = try #require(read["atContinuousNanoseconds"] as? Int)
            let duration = try #require(read["continuousNanoseconds"] as? Int)
            #expect(at >= 5_000_000_000)
            // Reads are issued back to back, so each starts after the previous one ended.
            #expect(at >= previousEnd, "read starts at \(at) before the previous ended")
            previousEnd = at + duration
        }
    }

    /// The one edge a call log cannot see: time spent inside the span that is not an event —
    /// a delay, a blocking call — which moves neither the call order nor a clock that only the
    /// provider advances. This compares the loop's recorded duration with the provider's own
    /// view of the same read, on the real clock. The overhead is a few instructions, so the
    /// *smallest* of 200 is asserted to be far below any delay worth catching: a busy machine
    /// slowing one read, or most of them, is what taking the minimum is immune to.
    ///
    /// Mutation this kills: `usleep(20_000)` immediately before the end stamp, or right after
    /// the start stamp. Either puts at least 20 ms into every read's overhead.
    @Test("nothing but the call is inside the span: the loop's duration is the provider's own")
    func spanOverheadIsFarBelowAnyDelayWorthCatching() async throws {
        let start = ContinuousClock.now
        let provider = SpanReportingProvider(start: start)
        let sink = LatencyCapturingSink()

        try await runLatencyLoopForTest(
            provider: provider, count: 200, sink: sink, continuousStart: start)

        let reads = Array(try sink.records().prefix(200))
        let spans = Array(provider.spans.dropFirst())  // the first call is the warm-up
        try #require(reads.count == 200)
        try #require(spans.count == 200)

        var smallestOverhead = Int.max
        for (read, span) in zip(reads, spans) {
            let recorded = try #require(read["continuousNanoseconds"] as? Int)
            smallestOverhead = min(smallestOverhead, recorded - Int(span[1] - span[0]))
        }
        #expect(
            smallestOverhead < 10_000_000,
            "the loop timed at least \(smallestOverhead) ns more than the call, on every read")
    }

    // MARK: - On a clock only the test moves

    /// Mutation this kills: encoding, printing or writing a line before the end stamp, or a
    /// third clock read inside the span. The stamp is read exactly twice per read,
    /// immediately around the one provider call, and the line is written after both. The
    /// warm-up call comes first and is not stamped at all.
    @Test("per read: stamp, the one provider call, stamp, and only then the write")
    func theTimedSpanContainsNothingButTheCall() async throws {
        let log = EventLog()
        let timeline = FakeTimeline()
        let provider = ScriptedLatencyProvider { _, _ in
            log.add("call")
            return .success(1.0)
        }

        try await runLatencyLoopForTest(
            provider: provider, count: 2, sink: LoggingSink(log: log),
            now: {
                log.add("now")
                return timeline.stamp()
            })

        #expect(
            log.all == [
                "call",  // the warm-up, before anything is stamped
                "now", "call", "now", "write:read",
                "now", "call", "now", "write:read",
                "write:summary",
            ])
    }

    /// The same placement, as numbers: a clock that only the provider can move, so each
    /// duration is exactly what the call did to it. The second timed read is one that
    /// "slept" — a minute on the continuous clock and nearly nothing on the suspending one —
    /// and the offsets are where each read was issued. Each of these is exact, with no real
    /// time involved, so none can flake; and each moves under a different mutation (the
    /// clocks exchanged, the end stamp used as the offset, the start taken after the call).
    @Test("durations and offsets are exactly what the call did to each clock")
    func durationsAndOffsetsAreExact() async throws {
        let timeline = FakeTimeline()
        let provider = ScriptedLatencyProvider { callNumber, _ in
            switch callNumber {
            case 0: timeline.advance(continuous: 5_000, suspending: 5_000)  // warm-up
            case 1: timeline.advance(continuous: 1_000, suspending: 700)
            case 2: timeline.advance(continuous: 60_000_000_000, suspending: 400)  // a sleep
            default: timeline.advance(continuous: 2_500, suspending: 2_500)
            }
            return .success(1.0)
        }
        let sink = LatencyCapturingSink()

        try await runLatencyLoopForTest(
            provider: provider, count: 3, sink: sink,
            continuousStart: timeline.continuousBase, now: { timeline.stamp() })

        let records = try sink.records()
        func field(_ index: Int, _ name: String) throws -> Int {
            try #require(records[index][name] as? Int)
        }
        #expect(try field(0, "continuousNanoseconds") == 1_000)
        #expect(try field(0, "suspendingNanoseconds") == 700)
        #expect(try field(0, "atContinuousNanoseconds") == 5_000)
        #expect(try field(1, "continuousNanoseconds") == 60_000_000_000)
        #expect(try field(1, "suspendingNanoseconds") == 400)
        #expect(try field(1, "atContinuousNanoseconds") == 6_000)
        #expect(try field(2, "continuousNanoseconds") == 2_500)
        #expect(try field(2, "suspendingNanoseconds") == 2_500)
        #expect(try field(2, "atContinuousNanoseconds") == 60_000_006_000)

        let summary = try #require(records.last)
        #expect(summary["maxContinuousNanoseconds"] as? Int == 60_000_000_000)
        #expect(summary["maxSuspendingNanoseconds"] as? Int == 2_500)
        let bySuspending = try #require(summary["slowestBySuspending"] as? [[String: Any]])
        let byContinuous = try #require(summary["slowestByContinuous"] as? [[String: Any]])
        #expect(bySuspending.first?["index"] as? Int == 2)
        #expect(byContinuous.first?["index"] as? Int == 1)
    }
}
