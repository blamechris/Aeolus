// The arithmetic behind smc-sampler --latency's summary line: nearest-rank percentiles, the
// ten slowest reads, and the sample-size honesty flags. Pure — no clock, no SMC — so
// Tests/SMCSamplerTests/LatencyStatisticsTests.swift can pin every edge of it. The loop that
// produces the reads is in LatencyMode.swift; see that file's header for what this mode is for.

/// Nearest-rank percentiles, in exact integer arithmetic.
///
/// A percentile is named by parts per ten thousand (`9_990` is p99.9) rather than by a
/// `Double`. The rank is `ceil(p * n)`, and the obvious floating-point spelling of it,
/// `ceil(99.9 / 100 * Double(n))`, is wrong on the round sample sizes a maintainer picks:
/// `99.9 / 100 * 1000` is `999.0000000000001`, whose ceiling is 1000 — the maximum, not the
/// 99.9th percentile — and the same happens at every multiple of 1000 up to at least 20,000
/// (`--count=10000` ranks p99.9 at 9991 instead of 9990). Integer arithmetic is exact.
enum NearestRank {
    static let scale = 10_000
    static let p50 = 5_000
    static let p99 = 9_900
    static let p999 = 9_990
    static let p9999 = 9_999

    /// The 1-based rank of the percentile among `count` sorted samples, `ceil(p * n)`
    /// clamped to `1...count`; `0` when there are no samples.
    static func rank(count: Int, partsPerTenThousand: Int) -> Int {
        guard count > 0 else { return 0 }
        let rank = (count * partsPerTenThousand + scale - 1) / scale
        return min(max(rank, 1), count)
    }

    /// The percentile's value in `sortedAscending`, or `nil` when it is empty.
    static func value(sortedAscending: [Int64], partsPerTenThousand: Int) -> Int64? {
        guard !sortedAscending.isEmpty else { return nil }
        let rank = rank(count: sortedAscending.count, partsPerTenThousand: partsPerTenThousand)
        return sortedAscending[rank - 1]
    }

    /// The fewest samples at which the percentile can be a value other than the maximum:
    /// below this, its rank is `count` and it is the maximum under another name.
    static func minimumMeaningfulSampleSize(partsPerTenThousand: Int) -> Int {
        let above = scale - partsPerTenThousand
        return (scale + above - 1) / above
    }

    static func isMeaningful(count: Int, partsPerTenThousand: Int) -> Bool {
        count >= minimumMeaningfulSampleSize(partsPerTenThousand: partsPerTenThousand)
    }
}

/// The `latencySummary` line, written once at the end of a latency run — including a run a
/// signal cut short, for the reads done so far.
///
/// **Percentiles are over successful reads only.** How long a `READ_BYTES` took to return a
/// value and how long one took to fail are different questions, and a failure that makes no
/// round trip at all (a key that is not readable) would otherwise drag the median toward
/// zero. Failures are counted, though, and `maxAllReadsContinuousNanoseconds` and
/// `slowest` are over every read, so a slow failure cannot hide.
///
/// **p99.99 over fewer than 10,000 successful reads is the maximum.** Nearest rank puts it
/// at the last sample. `p9999Meaningful` says so in a field, and `p9999Note` in words,
/// because a number printed beside a name that promises more than the sample size can
/// deliver gets read as the name. The flag counts successful reads (`percentileSampleSize`),
/// not all reads, since that is what the percentile was computed over.
struct LatencySummaryRecord: Sendable {
    let kind = "latencySummary"
    let requestedCount: Int
    let count: Int
    /// Fewer reads were taken than requested: a signal ended the run early.
    let interrupted: Bool
    let okCount: Int
    let failureCount: Int
    let percentileBasis = "successful reads only, nearest-rank"
    let percentileSampleSize: Int
    let minContinuousNanoseconds: Int64?
    let p50ContinuousNanoseconds: Int64?
    let p99ContinuousNanoseconds: Int64?
    let p999ContinuousNanoseconds: Int64?
    let p9999ContinuousNanoseconds: Int64?
    let maxContinuousNanoseconds: Int64?
    let maxAllReadsContinuousNanoseconds: Int64?
    let p999Meaningful: Bool
    let p9999Meaningful: Bool
    let p9999Note: String?
    let slowest: [LatencySlowRead]
    let warmup: [LatencyWarmupOutcome]
}

extension LatencySummaryRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, requestedCount, count, interrupted, okCount, failureCount, percentileBasis,
            percentileSampleSize, minContinuousNanoseconds, p50ContinuousNanoseconds,
            p99ContinuousNanoseconds, p999ContinuousNanoseconds, p9999ContinuousNanoseconds,
            maxContinuousNanoseconds, maxAllReadsContinuousNanoseconds,
            p999Meaningful, p9999Meaningful, p9999Note, slowest, warmup
    }

    /// Written by hand so every statistic that has no value (no successful reads) is an
    /// explicit JSON `null`, not an absent key — see `LatencyReadRecord.encode(to:)`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(requestedCount, forKey: .requestedCount)
        try container.encode(count, forKey: .count)
        try container.encode(interrupted, forKey: .interrupted)
        try container.encode(okCount, forKey: .okCount)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(percentileBasis, forKey: .percentileBasis)
        try container.encode(percentileSampleSize, forKey: .percentileSampleSize)
        try container.encode(minContinuousNanoseconds, forKey: .minContinuousNanoseconds)
        try container.encode(p50ContinuousNanoseconds, forKey: .p50ContinuousNanoseconds)
        try container.encode(p99ContinuousNanoseconds, forKey: .p99ContinuousNanoseconds)
        try container.encode(p999ContinuousNanoseconds, forKey: .p999ContinuousNanoseconds)
        try container.encode(p9999ContinuousNanoseconds, forKey: .p9999ContinuousNanoseconds)
        try container.encode(maxContinuousNanoseconds, forKey: .maxContinuousNanoseconds)
        try container.encode(
            maxAllReadsContinuousNanoseconds,
            forKey: .maxAllReadsContinuousNanoseconds)
        try container.encode(p999Meaningful, forKey: .p999Meaningful)
        try container.encode(p9999Meaningful, forKey: .p9999Meaningful)
        try container.encode(p9999Note, forKey: .p9999Note)
        try container.encode(slowest, forKey: .slowest)
        try container.encode(warmup, forKey: .warmup)
    }
}

/// Folds `LatencyReadRecord`s into a `LatencySummaryRecord`, keeping only what the summary
/// needs — one `Int64` per successful read, the failure count, and the ten slowest reads —
/// so a run of millions of reads does not hold millions of records.
struct LatencyAccumulator: Sendable {
    /// How many entries `slowest` carries.
    static let slowestCount = 10

    private(set) var count = 0
    private(set) var failureCount = 0
    private var okDurations: [Int64] = []
    private var maxAllReads: Int64?
    private var slowest: [LatencySlowRead] = []

    mutating func record(_ read: LatencyReadRecord) {
        count += 1
        if read.status == LatencyReadRecord.okStatus {
            okDurations.append(read.continuousNanoseconds)
        } else {
            failureCount += 1
        }
        maxAllReads = max(maxAllReads ?? .min, read.continuousNanoseconds)
        recordForSlowest(LatencySlowRead(read))
    }

    /// Keeps `slowest` the ten longest reads, slowest first, ties to the earlier read. A
    /// later read equal to the tenth never displaces it, which is what "ties to the earlier
    /// read" means for an ordering the loop only ever appends to.
    private mutating func recordForSlowest(_ entry: LatencySlowRead) {
        if slowest.count < Self.slowestCount {
            slowest.append(entry)
        } else {
            guard let tenth = slowest.last,
                entry.continuousNanoseconds > tenth.continuousNanoseconds
            else { return }
            slowest[slowest.count - 1] = entry
        }
        slowest.sort { lhs, rhs in
            lhs.continuousNanoseconds != rhs.continuousNanoseconds
                ? lhs.continuousNanoseconds > rhs.continuousNanoseconds
                : lhs.index < rhs.index
        }
    }

    func summary(requestedCount: Int, warmup: [LatencyWarmupOutcome]) -> LatencySummaryRecord {
        let sorted = okDurations.sorted()
        let sampleSize = sorted.count
        let p9999Meaningful = NearestRank.isMeaningful(
            count: sampleSize, partsPerTenThousand: NearestRank.p9999)
        let needed = NearestRank.minimumMeaningfulSampleSize(
            partsPerTenThousand: NearestRank.p9999)

        return LatencySummaryRecord(
            requestedCount: requestedCount,
            count: count,
            interrupted: count < requestedCount,
            okCount: sampleSize,
            failureCount: failureCount,
            percentileSampleSize: sampleSize,
            minContinuousNanoseconds: sorted.first,
            p50ContinuousNanoseconds: NearestRank.value(
                sortedAscending: sorted, partsPerTenThousand: NearestRank.p50),
            p99ContinuousNanoseconds: NearestRank.value(
                sortedAscending: sorted, partsPerTenThousand: NearestRank.p99),
            p999ContinuousNanoseconds: NearestRank.value(
                sortedAscending: sorted, partsPerTenThousand: NearestRank.p999),
            p9999ContinuousNanoseconds: NearestRank.value(
                sortedAscending: sorted, partsPerTenThousand: NearestRank.p9999),
            maxContinuousNanoseconds: sorted.last,
            maxAllReadsContinuousNanoseconds: maxAllReads,
            p999Meaningful: NearestRank.isMeaningful(
                count: sampleSize, partsPerTenThousand: NearestRank.p999),
            p9999Meaningful: p9999Meaningful,
            p9999Note: p9999Meaningful
                ? nil
                : "p99.99 is not meaningful at \(sampleSize) successful reads: it needs at "
                    + "least \(needed), and below that it is the maximum under another name",
            slowest: slowest,
            warmup: warmup)
    }
}
