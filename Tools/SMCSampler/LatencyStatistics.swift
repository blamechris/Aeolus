// The arithmetic behind smc-sampler --latency's summary line: nearest-rank percentiles on both
// clocks, the ten slowest reads on each, and the sample-size honesty flags. Pure — no clock,
// no SMC — so Tests/SMCSamplerTests/LatencyStatisticsTests.swift can pin every edge of it. The
// loop that produces the reads is in LatencyMode.swift; see that file's header for what this
// mode is for.

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

/// Which of the two monotonic clocks a figure is on.
///
/// They differ across a sleep and agree otherwise. `SuspendingClock` does not advance while the
/// machine sleeps, and it is the clock ADR 0012 I3 ages a call on, so it is the one **D** is
/// compared against: a read in flight when the lid closes has a `continuous` duration equal to
/// the whole sleep and a `suspending` duration equal to what the SMC actually took.
enum LatencyClock: Sendable {
    case continuous
    case suspending

    func duration(of read: LatencySlowRead) -> Int64 {
        switch self {
        case .continuous: return read.continuousNanoseconds
        case .suspending: return read.suspendingNanoseconds
        }
    }
}

/// Minimum, the four percentiles and maximum of one clock's durations, over the completed
/// round trips. Every member is `nil` when there were none.
struct LatencyDistribution: Sendable, Equatable {
    let min: Int64?
    let p50: Int64?
    let p99: Int64?
    let p999: Int64?
    let p9999: Int64?
    let max: Int64?

    init(sortedAscending sorted: [Int64]) {
        min = sorted.first
        p50 = NearestRank.value(sortedAscending: sorted, partsPerTenThousand: NearestRank.p50)
        p99 = NearestRank.value(sortedAscending: sorted, partsPerTenThousand: NearestRank.p99)
        p999 = NearestRank.value(sortedAscending: sorted, partsPerTenThousand: NearestRank.p999)
        p9999 = NearestRank.value(sortedAscending: sorted, partsPerTenThousand: NearestRank.p9999)
        max = sorted.last
    }
}

/// The ten longest reads on one clock, longest first, ties to the earlier read. A later read
/// equal to the tenth never displaces it, which is what "ties to the earlier read" means for
/// an ordering the loop only ever appends to.
struct SlowestReads: Sendable {
    /// How many entries a list carries.
    static let capacity = 10

    private(set) var entries: [LatencySlowRead] = []
    private let clock: LatencyClock

    init(rankedBy clock: LatencyClock) {
        self.clock = clock
    }

    mutating func consider(_ entry: LatencySlowRead) {
        if entries.count < Self.capacity {
            entries.append(entry)
        } else {
            guard let tenth = entries.last,
                clock.duration(of: entry) > clock.duration(of: tenth)
            else { return }
            entries[entries.count - 1] = entry
        }
        entries.sort { lhs, rhs in
            let (left, right) = (clock.duration(of: lhs), clock.duration(of: rhs))
            return left != right ? left > right : lhs.index < rhs.index
        }
    }
}

/// The `latencySummary` line, written once at the end of a latency run — including a run a
/// signal cut short, for the reads done so far.
///
/// **Which clock sets D.** The `Suspending` figures. ADR 0012 I3 ages a call on
/// `SuspendingClock`, so a read that was in flight across a lid close is not a wedge, and its
/// `continuous` duration (the whole sleep) is not the number D has to clear. The `Continuous`
/// figures are here to find those reads: one whose continuous duration is far above its
/// suspending one spanned a sleep.
///
/// **Percentiles are over completed round trips only**: reads whose `status` is `ok`, or
/// `notDecodable` (the `READ_BYTES` returned and its value is not a number — still a round
/// trip, and the only kind a string or flag key can ever be). A `readFailed`, `unknownKey`,
/// `providerError` or `noOutcome` read is counted in `failureCount` and kept out, because
/// whether it made a round trip at all, or one that failed, is not something the status says
/// — a key that is not readable makes none, and would drag the median toward zero. They are
/// not hidden, though: `maxAllReads…` and both `slowest…` lists are over every read.
///
/// **p99.99 over fewer than 10,000 completed reads is the maximum.** Nearest rank puts it
/// at the last sample. `p9999Meaningful` says so in a field, and `p9999Note` in words,
/// because a number printed beside a name that promises more than the sample size can
/// deliver gets read as the name. The flag counts completed reads (`percentileSampleSize`),
/// not all reads, since that is what the percentile was computed over.
struct LatencySummaryRecord: Sendable {
    let kind = "latencySummary"
    let requestedCount: Int
    let count: Int
    /// Fewer reads were taken than requested: a signal ended the run early.
    let interrupted: Bool
    /// Reads whose status is `ok`.
    let okCount: Int
    /// Reads whose status is anything but `ok`, `notDecodable` included.
    let failureCount: Int
    let percentileBasis = "completed round trips (status ok or notDecodable), nearest-rank"
    /// How many reads the percentiles were computed over.
    let percentileSampleSize: Int
    let continuous: LatencyDistribution
    let suspending: LatencyDistribution
    /// The longest read of any status, on each clock: the failure that took seconds is here.
    let maxAllReadsContinuousNanoseconds: Int64?
    let maxAllReadsSuspendingNanoseconds: Int64?
    let p999Meaningful: Bool
    let p9999Meaningful: Bool
    let p9999Note: String?
    let slowestBySuspending: [LatencySlowRead]
    let slowestByContinuous: [LatencySlowRead]
    let warmup: [LatencyWarmupOutcome]
}

extension LatencySummaryRecord: Encodable {
    private enum CodingKeys: String, CodingKey {
        case kind, requestedCount, count, interrupted, okCount, failureCount, percentileBasis,
            percentileSampleSize
        case minContinuousNanoseconds, p50ContinuousNanoseconds, p99ContinuousNanoseconds,
            p999ContinuousNanoseconds, p9999ContinuousNanoseconds, maxContinuousNanoseconds
        case minSuspendingNanoseconds, p50SuspendingNanoseconds, p99SuspendingNanoseconds,
            p999SuspendingNanoseconds, p9999SuspendingNanoseconds, maxSuspendingNanoseconds
        case maxAllReadsContinuousNanoseconds, maxAllReadsSuspendingNanoseconds
        case p999Meaningful, p9999Meaningful, p9999Note
        case slowestBySuspending, slowestByContinuous, warmup
    }

    /// Written by hand so every statistic that has no value (no completed reads) is an
    /// explicit JSON `null`, not an absent key — see `LatencyReadRecord.encode(to:)`. The
    /// two distributions are flattened to `min…`/`p50…`/…/`max…` keys with the clock named
    /// in each, so a field can be read without knowing which object it came from.
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

        try container.encode(continuous.min, forKey: .minContinuousNanoseconds)
        try container.encode(continuous.p50, forKey: .p50ContinuousNanoseconds)
        try container.encode(continuous.p99, forKey: .p99ContinuousNanoseconds)
        try container.encode(continuous.p999, forKey: .p999ContinuousNanoseconds)
        try container.encode(continuous.p9999, forKey: .p9999ContinuousNanoseconds)
        try container.encode(continuous.max, forKey: .maxContinuousNanoseconds)

        try container.encode(suspending.min, forKey: .minSuspendingNanoseconds)
        try container.encode(suspending.p50, forKey: .p50SuspendingNanoseconds)
        try container.encode(suspending.p99, forKey: .p99SuspendingNanoseconds)
        try container.encode(suspending.p999, forKey: .p999SuspendingNanoseconds)
        try container.encode(suspending.p9999, forKey: .p9999SuspendingNanoseconds)
        try container.encode(suspending.max, forKey: .maxSuspendingNanoseconds)

        try container.encode(
            maxAllReadsContinuousNanoseconds, forKey: .maxAllReadsContinuousNanoseconds)
        try container.encode(
            maxAllReadsSuspendingNanoseconds, forKey: .maxAllReadsSuspendingNanoseconds)
        try container.encode(p999Meaningful, forKey: .p999Meaningful)
        try container.encode(p9999Meaningful, forKey: .p9999Meaningful)
        try container.encode(p9999Note, forKey: .p9999Note)
        try container.encode(slowestBySuspending, forKey: .slowestBySuspending)
        try container.encode(slowestByContinuous, forKey: .slowestByContinuous)
        try container.encode(warmup, forKey: .warmup)
    }
}

/// Folds `LatencyReadRecord`s into a `LatencySummaryRecord`, keeping only what the summary
/// needs — one `Int64` per clock per completed read, the counts, and the ten slowest reads on
/// each clock — so a run of millions of reads does not hold millions of records.
struct LatencyAccumulator: Sendable {
    private(set) var count = 0
    private var okCount = 0
    private var failureCount = 0
    private var completedContinuous: [Int64] = []
    private var completedSuspending: [Int64] = []
    private var maxAllContinuous: Int64?
    private var maxAllSuspending: Int64?
    private var slowestContinuous = SlowestReads(rankedBy: .continuous)
    private var slowestSuspending = SlowestReads(rankedBy: .suspending)

    mutating func record(_ read: LatencyReadRecord) {
        count += 1
        if read.status == LatencyReadRecord.okStatus {
            okCount += 1
        } else {
            failureCount += 1
        }
        if read.isCompletedRoundTrip {
            completedContinuous.append(read.continuousNanoseconds)
            completedSuspending.append(read.suspendingNanoseconds)
        }
        maxAllContinuous = max(maxAllContinuous ?? .min, read.continuousNanoseconds)
        maxAllSuspending = max(maxAllSuspending ?? .min, read.suspendingNanoseconds)
        let entry = LatencySlowRead(read)
        slowestContinuous.consider(entry)
        slowestSuspending.consider(entry)
    }

    func summary(requestedCount: Int, warmup: [LatencyWarmupOutcome]) -> LatencySummaryRecord {
        let sampleSize = completedContinuous.count
        let p9999Meaningful = NearestRank.isMeaningful(
            count: sampleSize, partsPerTenThousand: NearestRank.p9999)
        let needed = NearestRank.minimumMeaningfulSampleSize(
            partsPerTenThousand: NearestRank.p9999)

        return LatencySummaryRecord(
            requestedCount: requestedCount,
            count: count,
            interrupted: count < requestedCount,
            okCount: okCount,
            failureCount: failureCount,
            percentileSampleSize: sampleSize,
            continuous: LatencyDistribution(sortedAscending: completedContinuous.sorted()),
            suspending: LatencyDistribution(sortedAscending: completedSuspending.sorted()),
            maxAllReadsContinuousNanoseconds: maxAllContinuous,
            maxAllReadsSuspendingNanoseconds: maxAllSuspending,
            p999Meaningful: NearestRank.isMeaningful(
                count: sampleSize, partsPerTenThousand: NearestRank.p999),
            p9999Meaningful: p9999Meaningful,
            p9999Note: p9999Meaningful
                ? nil
                : "p99.99 is not meaningful at \(sampleSize) completed reads: it needs at "
                    + "least \(needed), and below that it is the maximum under another name",
            slowestBySuspending: slowestSuspending.entries,
            slowestByContinuous: slowestContinuous.entries,
            warmup: warmup)
    }
}
