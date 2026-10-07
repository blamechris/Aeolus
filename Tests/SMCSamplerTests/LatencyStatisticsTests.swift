import Foundation
import Testing

@testable import smc_sampler

/// Covers the arithmetic `--latency` summarises a run with: nearest-rank percentiles,
/// the failures-are-counted-but-not-percentiled rule, the ten-slowest selection, and the
/// "p99.99 is not meaningful below 10,000 samples" flag. All pure — no clock, no hardware.
@Suite("LatencyStatistics")
struct LatencyStatisticsTests {

    private static func read(
        _ index: Int, nanoseconds: Int64, status: String = "ok", key: String = "F0Ac",
        suspending: Int64? = nil, at: Int64? = nil
    ) -> LatencyReadRecord {
        LatencyReadRecord(
            index: index, key: key, status: status,
            failureReason: status == "ok" ? nil : "reason for \(status)",
            continuousNanoseconds: nanoseconds,
            suspendingNanoseconds: suspending ?? nanoseconds,
            atContinuousNanoseconds: at ?? Int64(index) * 1_000)
    }

    private static func summary(
        _ reads: [LatencyReadRecord], requested: Int? = nil,
        warmup: [LatencyWarmupOutcome] = []
    ) -> LatencySummaryRecord {
        var accumulator = LatencyAccumulator()
        for read in reads { accumulator.record(read) }
        return accumulator.summary(requestedCount: requested ?? reads.count, warmup: warmup)
    }

    // MARK: - Nearest rank

    /// The rank is `ceil(p * n)`. Done in floating point as `ceil(99.9 / 100 * Double(n))`,
    /// n = 1000 gives `999.0000000000001`, whose ceiling is 1000 — the maximum, not the
    /// p99.9 — and n = 2000 gives 1999 where the answer is 1998. That is the mutation these
    /// exact-boundary cases kill: swapping the integer arithmetic for that `Double` ceiling.
    @Test(
        "nearest-rank rank is ceil(p * n), exact at the boundaries a Double gets wrong",
        arguments: [
            (count: 1, partsPerTenThousand: 5_000, rank: 1),
            (count: 1, partsPerTenThousand: 9_999, rank: 1),
            (count: 2, partsPerTenThousand: 5_000, rank: 1),
            (count: 7, partsPerTenThousand: 5_000, rank: 4),
            (count: 100, partsPerTenThousand: 9_900, rank: 99),
            (count: 1_000, partsPerTenThousand: 9_990, rank: 999),
            (count: 2_000, partsPerTenThousand: 9_990, rank: 1_998),
            (count: 10_000, partsPerTenThousand: 9_990, rank: 9_990),
            (count: 10_000, partsPerTenThousand: 9_999, rank: 9_999),
            (count: 10_001, partsPerTenThousand: 9_999, rank: 10_000),
            (count: 9_999, partsPerTenThousand: 9_999, rank: 9_999),
        ])
    func rankIsExact(count: Int, partsPerTenThousand: Int, rank: Int) {
        #expect(
            NearestRank.rank(count: count, partsPerTenThousand: partsPerTenThousand) == rank)
    }

    @Test("nearest-rank value picks the element at that rank, and nil for no samples")
    func valueAtRank() {
        let sorted: [Int64] = [10, 20, 30, 40]
        #expect(NearestRank.value(sortedAscending: sorted, partsPerTenThousand: 5_000) == 20)
        #expect(NearestRank.value(sortedAscending: sorted, partsPerTenThousand: 9_999) == 40)
        #expect(NearestRank.value(sortedAscending: [], partsPerTenThousand: 5_000) == nil)
    }

    @Test("percentiles over 1...10000 are exactly the textbook nearest-rank values")
    func percentilesOverAKnownDistribution() {
        let reads = (1...10_000).map { Self.read($0 - 1, nanoseconds: Int64($0)) }
        let summary = Self.summary(reads)

        #expect(summary.continuous.min == 1)
        #expect(summary.continuous.p50 == 5_000)
        #expect(summary.continuous.p99 == 9_900)
        #expect(summary.continuous.p999 == 9_990)
        #expect(summary.continuous.p9999 == 9_999)
        #expect(summary.continuous.max == 10_000)
    }

    @Test("the arrival order of the reads does not change any percentile")
    func orderIndependence() {
        let durations = (1...2_000).map { Int64($0) }
        let ascending = durations.enumerated().map { Self.read($0.offset, nanoseconds: $0.element) }
        // A deterministic permutation: stride through the range with a step coprime to it.
        let shuffled = (0..<2_000).map { (position: Int) -> LatencyReadRecord in
            let value = durations[(position * 7) % 2_000]
            return Self.read(position, nanoseconds: value)
        }
        let ascendingSummary = Self.summary(ascending)
        let shuffledSummary = Self.summary(shuffled)
        #expect(
            ascendingSummary.continuous.p50 == shuffledSummary.continuous.p50)
        #expect(
            ascendingSummary.continuous.p99 == shuffledSummary.continuous.p99)
        #expect(
            ascendingSummary.continuous.p999 == shuffledSummary.continuous.p999)
        #expect(
            ascendingSummary.continuous.max == shuffledSummary.continuous.max)
        #expect(
            ascendingSummary.continuous.min == shuffledSummary.continuous.min)
    }

    // MARK: - Small samples

    @Test("no reads at all: counts are zero, every statistic is nil, nothing is meaningful")
    func emptyRun() {
        let summary = Self.summary([], requested: 50)

        // Not a collection: `empty_count` would have this say `isEmpty`, which it cannot.
        let readsTaken = summary.count
        #expect(readsTaken == 0)
        #expect(summary.okCount == 0)
        #expect(summary.failureCount == 0)
        #expect(summary.requestedCount == 50)
        #expect(summary.interrupted == true)
        #expect(summary.continuous.min == nil)
        #expect(summary.continuous.p50 == nil)
        #expect(summary.continuous.p9999 == nil)
        #expect(summary.continuous.max == nil)
        #expect(summary.maxAllReadsContinuousNanoseconds == nil)
        #expect(summary.slowestByContinuous.isEmpty)
        #expect(summary.p999Meaningful == false)
        #expect(summary.p9999Meaningful == false)
    }

    @Test("a single sample is every percentile at once")
    func singleSample() {
        let summary = Self.summary([Self.read(0, nanoseconds: 4_321)])

        #expect(summary.count == 1)
        #expect(summary.okCount == 1)
        #expect(summary.continuous.min == 4_321)
        #expect(summary.continuous.p50 == 4_321)
        #expect(summary.continuous.p99 == 4_321)
        #expect(summary.continuous.p999 == 4_321)
        #expect(summary.continuous.p9999 == 4_321)
        #expect(summary.continuous.max == 4_321)
        #expect(summary.slowestByContinuous.count == 1)
        #expect(summary.interrupted == false)
    }

    @Test("two samples: the median is the lower one under nearest rank")
    func twoSamples() {
        let summary = Self.summary([
            Self.read(0, nanoseconds: 900), Self.read(1, nanoseconds: 100),
        ])
        #expect(summary.continuous.p50 == 100)
        #expect(summary.continuous.p99 == 900)
        #expect(summary.continuous.min == 100)
        #expect(summary.continuous.max == 900)
    }

    // MARK: - Failures

    /// A failed read is counted, and it is kept out of the percentiles: how long a
    /// `READ_BYTES` took to *succeed* and how long one took to *fail* are different
    /// questions, and a fast failure (a zero-round-trip `notReadable`) would otherwise drag
    /// the median down. But a slow failure must still surface somewhere — it is the dark-wake
    /// case #296 asks about — so the all-reads maximum and the slowest list include it.
    @Test("failures are counted but excluded from the percentiles; a slow failure still shows")
    func failuresAreCountedNotPercentiled() {
        let reads = [
            Self.read(0, nanoseconds: 100),
            Self.read(1, nanoseconds: 9_999_999, status: "readFailed"),
            Self.read(2, nanoseconds: 300),
            Self.read(3, nanoseconds: 200),
            Self.read(4, nanoseconds: 5, status: "providerError"),
        ]
        let summary = Self.summary(reads)

        #expect(summary.count == 5)
        #expect(summary.okCount == 3)
        #expect(summary.failureCount == 2)
        #expect(summary.continuous.min == 100, "the fast failure (5) must not be the min")
        #expect(summary.continuous.p50 == 200)
        #expect(summary.continuous.max == 300, "the slow failure must not be the max")
        #expect(summary.maxAllReadsContinuousNanoseconds == 9_999_999)

        let top = summary.slowestByContinuous.first
        #expect(top?.index == 1)
        #expect(top?.status == "readFailed")
    }

    @Test("a run of nothing but failures has no percentiles but a full failure count")
    func allFailures() {
        let reads = (0..<4).map { Self.read($0, nanoseconds: 50, status: "unknownKey") }
        let summary = Self.summary(reads)

        #expect(summary.count == 4)
        #expect(summary.okCount == 0)
        #expect(summary.failureCount == 4)
        #expect(summary.continuous.p50 == nil)
        #expect(summary.continuous.max == nil)
        #expect(summary.maxAllReadsContinuousNanoseconds == 50)
    }

    // MARK: - Ten slowest

    @Test("the ten slowest reads are chosen from any position, slowest first, with offsets")
    func tenSlowestAreSelected() {
        // 25 reads, durations a permutation of 1...25; offsets recognisable per index.
        let durations = (0..<25).map { Int64(($0 * 7) % 25 + 1) }
        let reads = durations.enumerated().map {
            Self.read($0.offset, nanoseconds: $0.element * 10, at: Int64($0.offset) * 1_000_000)
        }
        let summary = Self.summary(reads)

        #expect(summary.slowestByContinuous.count == 10)
        // The ten largest durations are 25...16, slowest first.
        #expect(
            summary.slowestByContinuous.map(\.continuousNanoseconds)
                == (16...25).reversed().map { Int64($0) * 10 })
        for entry in summary.slowestByContinuous {
            #expect(entry.atContinuousNanoseconds == Int64(entry.index) * 1_000_000)
            #expect(durations[entry.index] * 10 == entry.continuousNanoseconds)
        }
    }

    @Test("fewer than ten reads: every read is in the slowest list")
    func fewerThanTenReads() {
        let reads = (0..<4).map { Self.read($0, nanoseconds: Int64(($0 + 1) * 100)) }
        let summary = Self.summary(reads)
        #expect(summary.slowestByContinuous.map(\.index) == [3, 2, 1, 0])
    }

    @Test("equal durations are tied by the earlier read, and a later tie never displaces one")
    func tiesPreferTheEarlierRead() {
        let reads = (0..<12).map { Self.read($0, nanoseconds: 777) }
        let summary = Self.summary(reads)
        #expect(summary.slowestByContinuous.map(\.index) == Array(0..<10))
    }

    @Test("a slow read that arrives last still displaces the tenth slowest")
    func lateSlowReadDisplaces() {
        var reads = (0..<20).map { Self.read($0, nanoseconds: Int64(100 + $0)) }
        reads.append(Self.read(20, nanoseconds: 1_000_000))
        let summary = Self.summary(reads)
        #expect(summary.slowestByContinuous.first?.index == 20)
        #expect(summary.slowestByContinuous.count == 10)
    }

    @Test("the slowest list carries the suspending duration and the status")
    func slowestCarriesBothClocksAndStatus() {
        let summary = Self.summary([
            Self.read(0, nanoseconds: 500, status: "readFailed", suspending: 123)
        ])
        let entry = summary.slowestByContinuous.first
        #expect(entry?.suspendingNanoseconds == 123)
        #expect(entry?.status == "readFailed")
        #expect(entry?.key == "F0Ac")
    }

    // MARK: - Sample-size honesty

    @Test("p99.99 is flagged not meaningful below 10,000 successful reads, and meaningful at it")
    func p9999FlagFlipsAtTenThousand() {
        let below = Self.summary((0..<9_999).map { Self.read($0, nanoseconds: Int64($0 + 1)) })
        #expect(below.p9999Meaningful == false)
        #expect(below.p9999Note != nil)
        // Below the threshold the "p99.99" is simply the maximum — that is what the flag
        // is warning about, and at the threshold it stops being true.
        #expect(below.continuous.p9999 == below.continuous.max)

        let at = Self.summary((0..<10_000).map { Self.read($0, nanoseconds: Int64($0 + 1)) })
        #expect(at.p9999Meaningful == true)
        #expect(at.p9999Note == nil)
        #expect(at.continuous.p9999 != at.continuous.max)
    }

    /// The flag is about how many reads the percentile was *computed over*, which excludes
    /// failures: 10,000 reads of which one failed leave 9,999 samples, and p99.99 over 9,999
    /// is the maximum again.
    @Test("the meaningful flag counts successful reads, not all reads")
    func flagCountsSuccessfulReadsOnly() {
        var reads = (0..<9_999).map { Self.read($0, nanoseconds: Int64($0 + 1)) }
        reads.append(Self.read(9_999, nanoseconds: 1, status: "readFailed"))
        let summary = Self.summary(reads)

        #expect(summary.count == 10_000)
        #expect(summary.okCount == 9_999)
        #expect(summary.percentileSampleSize == 9_999)
        #expect(summary.p9999Meaningful == false)
    }

    @Test("p99.9 is flagged not meaningful below 1,000 successful reads")
    func p999FlagFlipsAtOneThousand() {
        let below = Self.summary((0..<999).map { Self.read($0, nanoseconds: Int64($0 + 1)) })
        #expect(below.p999Meaningful == false)
        let at = Self.summary((0..<1_000).map { Self.read($0, nanoseconds: Int64($0 + 1)) })
        #expect(at.p999Meaningful == true)
    }

    // MARK: - Carried through

    @Test("the warm-up outcomes and the requested count are carried into the summary")
    func warmupAndRequestedCountAreCarried() {
        let warmup = [LatencyWarmupOutcome(key: "F0Ac", status: "readFailed")]
        let summary = Self.summary(
            [Self.read(0, nanoseconds: 1)], requested: 3, warmup: warmup)
        #expect(summary.warmup == warmup)
        #expect(summary.requestedCount == 3)
        #expect(summary.interrupted == true)
    }
}
