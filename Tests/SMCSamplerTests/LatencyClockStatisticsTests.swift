import Foundation
import Testing

@testable import smc_sampler

/// What the summary says about the two clocks, and about which reads count as completed round
/// trips. The percentile arithmetic itself, the failure counting and the small-sample flags
/// are in `LatencyStatisticsTests`. All pure — no clock, no hardware.
@Suite("LatencyStatistics clocks and completed round trips")
struct LatencyClockStatisticsTests {

    private static func read(
        _ index: Int, nanoseconds: Int64, status: String = "ok", key: String = "F0Ac",
        suspending: Int64? = nil
    ) -> LatencyReadRecord {
        LatencyReadRecord(
            index: index, key: key, status: status,
            failureReason: status == "ok" ? nil : "reason for \(status)",
            continuousNanoseconds: nanoseconds,
            suspendingNanoseconds: suspending ?? nanoseconds,
            atContinuousNanoseconds: Int64(index) * 1_000)
    }

    private static func summary(_ reads: [LatencyReadRecord]) -> LatencySummaryRecord {
        var accumulator = LatencyAccumulator()
        for read in reads { accumulator.record(read) }
        return accumulator.summary(requestedCount: reads.count, warmup: [])
    }

    // MARK: - The suspending clock

    /// A read in flight when the lid closes has a continuous duration equal to the whole
    /// sleep and a suspending duration equal to what the SMC took. ADR 0012 I3 ages a call on
    /// the suspending clock, so that is the figure D is compared against, and the summary has
    /// to carry it. Here one read in 21 "slept" for a minute.
    @Test("each clock has its own percentiles, and a read that spanned a sleep moves only one")
    func clocksAreSummarisedIndependently() {
        var reads = (0..<20).map {
            Self.read($0, nanoseconds: Int64(1_000 + $0), suspending: Int64(1_000 + $0))
        }
        reads.append(Self.read(20, nanoseconds: 60_000_000_000, suspending: 1_020))
        let summary = Self.summary(reads)

        #expect(summary.continuous.max == 60_000_000_000)
        #expect(summary.suspending.max == 1_020)
        #expect(summary.suspending.min == 1_000)
        // 21 reads: rank 11 of the sorted suspending durations, 1_000...1_020.
        #expect(summary.suspending.p50 == 1_010)
        #expect(summary.suspending.p99 == 1_020)
        #expect(summary.suspending.p999 == 1_020)
        #expect(summary.suspending.p9999 == 1_020)
        #expect(summary.maxAllReadsContinuousNanoseconds == 60_000_000_000)
        #expect(summary.maxAllReadsSuspendingNanoseconds == 1_020)
    }

    @Test("the suspending percentiles are computed over the suspending durations, not re-used")
    func suspendingPercentilesUseSuspendingDurations() {
        // Suspending is exactly twice continuous, so any mix-up between the two shows.
        let reads = (1...100).map {
            Self.read($0 - 1, nanoseconds: Int64($0), suspending: Int64($0 * 2))
        }
        let summary = Self.summary(reads)

        #expect(summary.continuous.min == 1)
        #expect(summary.suspending.min == 2)
        #expect(summary.continuous.p50 == 50)
        #expect(summary.suspending.p50 == 100)
        #expect(summary.continuous.p99 == 99)
        #expect(summary.suspending.p99 == 198)
        #expect(summary.continuous.max == 100)
        #expect(summary.suspending.max == 200)
    }

    /// The summary is the first thing read. With a lid close producing a dozen straddlers,
    /// the continuous ranking is all straddlers and the one genuinely slow failure — 3 s, on
    /// both clocks — would be the thirteenth entry and fall off the list. Ranked by the clock
    /// D is compared against, it is first.
    @Test("a slow failure survives a dozen sleep-spanning reads in the suspending ranking")
    func slowFailureSurvivesStraddlersBySuspending() {
        var reads = (0..<12).map {
            Self.read($0, nanoseconds: 60_000_000_000, suspending: 200_000)
        }
        reads.append(
            Self.read(
                12, nanoseconds: 3_000_000_000, status: "readFailed", suspending: 3_000_000_000))
        let summary = Self.summary(reads)

        #expect(summary.slowestBySuspending.first?.index == 12)
        #expect(summary.slowestBySuspending.first?.status == "readFailed")
        #expect(summary.maxAllReadsSuspendingNanoseconds == 3_000_000_000)
        #expect(
            !summary.slowestByContinuous.contains { $0.index == 12 },
            "the continuous ranking is the one the straddlers fill")
        #expect(summary.slowestByContinuous.count == 10)
    }

    @Test("the suspending ranking keeps the same tie rule: the earlier read wins")
    func suspendingRankingTiesPreferTheEarlierRead() {
        let reads = (0..<12).map { Self.read($0, nanoseconds: Int64($0), suspending: 500) }
        let summary = Self.summary(reads)
        #expect(summary.slowestBySuspending.map(\.index) == Array(0..<10))
    }

    // MARK: - Completed round trips

    /// A `READ_BYTES` that returned a value which is not a number is a completed round trip:
    /// it is a latency sample for a string or flag key, and the only kind such a key can
    /// produce. It stays a non-`ok` status on the read line.
    @Test("a notDecodable read is a completed round trip: percentiled, and still not ok")
    func notDecodableIsPercentiledButNotOk() {
        let reads = [
            Self.read(0, nanoseconds: 100, status: "notDecodable", key: "RPlt", suspending: 90),
            Self.read(1, nanoseconds: 300, status: "notDecodable", key: "RPlt", suspending: 280),
            Self.read(2, nanoseconds: 200, key: "F0Ac", suspending: 180),
        ]
        let summary = Self.summary(reads)

        #expect(summary.count == 3)
        #expect(summary.okCount == 1)
        #expect(summary.failureCount == 2, "notDecodable is not ok, and is counted as such")
        #expect(summary.percentileSampleSize == 3)
        #expect(summary.continuous.min == 100)
        #expect(summary.continuous.p50 == 200)
        #expect(summary.continuous.max == 300)
        #expect(summary.suspending.max == 280)
    }

    @Test("a run of nothing but notDecodable reads still has percentiles")
    func onlyNotDecodableStillHasPercentiles() {
        let reads = (0..<3).map {
            Self.read($0, nanoseconds: Int64(200 + $0), status: "notDecodable", key: "RPlt")
        }
        let summary = Self.summary(reads)
        #expect(summary.okCount == 0)
        #expect(summary.percentileSampleSize == 3)
        #expect(summary.continuous.p50 == 201)
    }

    @Test("only ok and notDecodable are completed round trips")
    func completedRoundTripStatuses() {
        func completed(_ status: String) -> Bool {
            Self.read(0, nanoseconds: 1, status: status).isCompletedRoundTrip
        }
        #expect(completed("ok"))
        #expect(completed("notDecodable"))
        for status in ["readFailed", "unknownKey", "providerError", "noOutcome"] {
            #expect(!completed(status), "\(status) must not be percentiled")
        }
    }
}
