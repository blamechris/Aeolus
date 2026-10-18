import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What the ladder's step 12 costs the snapshot path on a seam that can write, measured on the one
/// machine that can measure it ([#269](https://github.com/blamechris/Aeolus/issues/269)).
///
/// An extension of `HelperHardwareTests`, so it takes that suite's `.serialized` and its gate on
/// `Mac16,5`: the measurement contends for the one SMC, and a run beside the other hardware tests
/// would time them too. **Read-only.** The real read path and the real curated set are read
/// through one `SMCConnection`; the `.built` capability is a scripted reporter, the lease core is
/// `LeaseFixture`'s, and the keystone refuses without touching anything, so nothing here can write.
///
/// Three claims, each the bound #269's ruling set before merge:
///
/// - **Warm, the check adds under 1 ms at p50.** § 3's cycle is stood in for by a read of the
///   curated set recorded into the cache before each snapshot, as `ThermalEmergency` records, so
///   the snapshot's `sighting()` is served from memory. The check is timed where the snapshot
///   awaits it, and the snapshot is timed beside one on a `.notBuilt` seam, which asks nothing,
///   the two alternating which goes first.
/// - **Cold, at most one curated-set read per snapshot.** With nothing recording, each snapshot
///   follows an expiry of the cache's one-period bound.
/// - **With § 3 stopped, the `.supervisor` queue never holds more than one sighting read**,
///   however many snapshots are asked at once: a burst of concurrent snapshots on an expired cache,
///   with every `.supervisor` turn counted as the scheduler reports it, parked or in flight.
///
/// The counts are asserted, and are not moved by ordinary load. The durations are printed, and
/// the warm p50 is asserted only against the ruling's 1 ms, about three orders of magnitude above
/// what the check costs; a run under other builds measures them too (#227), so run it alone. The
/// two snapshot medians are printed for context and are not the check's cost: a snapshot here
/// spreads from about 0.5 s to over 1 s, and two identical `.notBuilt` series part at p50 by as
/// much as a `.built` and a `.notBuilt` one do.
extension HelperHardwareTests {

    /// Ten warm rounds, three cold snapshots and one burst of 16 are what the three counts need,
    /// and no more: this runs in every local `swift test` on `Mac16,5`. At 40, 10 and three bursts
    /// it took about 126 s; cut, 39 s run alone. The limit, about three times that, stops a wedged
    /// scheduler holding the whole run.
    @Test(
        "A built seam's snapshot asks § 3's cache once: cheap warm, one read cold, one in flight",
        .timeLimit(.minutes(2)))
    func theSnapshotsSightingIsCheapAndCoalesced() async throws {
        let rig = try SightingRig()
        // Discovery first, and one cold read with it: the claims are about the warm refresh.
        _ = try await rig.built.snapshot()

        let rounds = 10
        let warm = try await rig.warmRounds(rounds)
        let cold = try await rig.coldSnapshots(3)
        let bursts = try await rig.bursts(1, of: 16)

        print(
            """
            #269 snapshot sighting on \(HardwareIdentity.current().modelIdentifier ?? "?"), \
            \(ProcessInfo.processInfo.operatingSystemVersionString): \
            warm check p50 \(Self.percentile(0.5, of: warm.checks)), \
            p99 \(Self.percentile(0.99, of: warm.checks)), max \(warm.checks.max() ?? .zero) \
            over \(warm.checks.count), with \(warm.reads) curated reads; \
            warm snapshot p50 .built \(Self.percentile(0.5, of: warm.built)) against \
            .notBuilt \(Self.percentile(0.5, of: warm.notBuilt)); \
            cold check p50 \(Self.percentile(0.5, of: cold.checks)), \
            p99 \(Self.percentile(0.99, of: cold.checks)), curated reads per cold snapshot \
            \(cold.reads); bursts of 16: curated reads \(bursts.reads), peak .supervisor turns \
            parked or in flight \(bursts.peaks); \(await rig.cache.coalescedSightings) sightings \
            coalesced in all
            """)

        #expect(warm.checks.count == rounds, "a warm snapshot did not ask the cache exactly once")
        #expect(warm.reads == 0, "a warm snapshot read the curated set \(warm.reads) times")
        #expect(
            Self.percentile(0.5, of: warm.checks) < .milliseconds(1),
            "the warm check costs more than the 1 ms #269 allowed at p50")
        #expect(cold.reads.allSatisfy { $0 <= 1 }, "a cold snapshot read the set \(cold.reads)")
        #expect(cold.reads.contains(1), "no snapshot was cold, so the cold claim measured nothing")
        #expect(bursts.reads == [1], "the burst read the curated set \(bursts.reads) times")
        #expect(
            bursts.peaks.allSatisfy { $0 == 1 },
            "the .supervisor queue held \(bursts.peaks) sighting reads at once")
    }

    /// The nearest-rank percentile; `.zero` for no samples.
    fileprivate static func percentile(_ fraction: Double, of samples: [Duration]) -> Duration {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return .zero }
        return sorted[Int((fraction * Double(sorted.count - 1)).rounded())]
    }
}

/// The measured graph: the real read path and curated set over one connection, a `.built` and a
/// `.notBuilt` authority over them, and the counters every claim reads.
private struct SightingRig {
    let probe: SupervisorTurnProbe
    let curated: CuratedCriticalTemperatures<SMCFanControlPlane>
    let counted: CountingCriticalTemperatures
    let cache: CriticalTemperatureCache
    let timed: TimedSighting
    let built: SupervisedFanAuthority
    let notBuilt: SupervisedFanAuthority

    init() throws {
        let log = HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Hardware")
        let connection = SMCConnection()
        let probe = SupervisorTurnProbe()
        self.probe = probe
        let scheduler = SMCReadScheduler(
            provider: SMCSensorProvider(connection: connection), observer: probe)
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: connection)
        let critical = CriticalSensorSet.resolve(for: HardwareIdentity.current())
        try #require(!critical.isEmpty, "no curated critical set on the machine it was cut for")
        curated = CuratedCriticalTemperatures(
            plane: plane, set: critical,
            log: SafetyLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "Hardware"))
        counted = CountingCriticalTemperatures(curated)
        cache = CriticalTemperatureCache(source: counted)
        timed = TimedSighting(cache)
        let reading = ReadOnlyFanAuthority(
            provider: scheduler.snapshotReader,
            fanMode: SnapshotFanModeReads(provider: scheduler.snapshotReader), log: log,
            thermalEmergency: ThermalEmergencyLatch(), reclamation: ReclamationLedger(),
            writeCapability: LeaseFixture.writePathBuilt())
        let leases = LeaseFixture.authority(telemetry: cache)
        built = SupervisedFanAuthority(
            reading: reading, leases: leases, reconciliation: CompleteBaseline(),
            keystone: RefusingKeystone(), writeCapability: LeaseFixture.writePathBuilt(),
            telemetry: timed, control: NoLevelSix(), reclamation: NothingRecorded(), log: log)
        notBuilt = SupervisedFanAuthority(
            reading: reading, leases: leases, reconciliation: CompleteBaseline(),
            keystone: RefusingKeystone(), writeCapability: LeaseFixture.writePathNotBuilt(),
            telemetry: timed, control: NoLevelSix(), reclamation: NothingRecorded(), log: log)
    }

    /// A snapshot of each kind per round, alternating which goes first, each just after § 3's
    /// write path — a read of the curated set recorded into the cache — so the `.built` one is
    /// served from memory however long the one before it took, and both run after the same read.
    func warmRounds(_ rounds: Int) async throws -> WarmRounds {
        var checks: [Duration] = []
        var builtTimes: [Duration] = []
        var notBuiltTimes: [Duration] = []
        let readsBefore = counted.reads
        for round in 0..<rounds {
            let checksBefore = timed.durations.count
            for isBuilt in round.isMultiple(of: 2) ? [true, false] : [false, true] {
                let start = await cache.beganReading()
                let report = try await curated.readCriticalTemperatures()
                await cache.record(.sighted(report), since: start)
                let authority = isBuilt ? built : notBuilt
                let started = ContinuousClock.now
                _ = try await authority.snapshot()
                let took = ContinuousClock.now - started
                if isBuilt { builtTimes.append(took) } else { notBuiltTimes.append(took) }
            }
            checks += timed.durations.dropFirst(checksBefore)
        }
        return WarmRounds(
            checks: checks, reads: counted.reads - readsBefore, built: builtTimes,
            notBuilt: notBuiltTimes)
    }

    /// What the warm rounds measured: each `.built` snapshot's check, the curated reads issued,
    /// and each snapshot's duration by kind.
    struct WarmRounds {
        let checks: [Duration]
        let reads: Int
        let built: [Duration]
        let notBuilt: [Duration]
    }

    /// `.built` snapshots with nothing recording, the cache's bound expired before each.
    func coldSnapshots(_ count: Int) async throws -> (checks: [Duration], reads: [Int]) {
        var checks: [Duration] = []
        var reads: [Int] = []
        for _ in 0..<count {
            try await Task.sleep(for: .milliseconds(1_100))
            let readsBefore = counted.reads
            let checksBefore = timed.durations.count
            _ = try await built.snapshot()
            reads.append(counted.reads - readsBefore)
            checks += timed.durations.dropFirst(checksBefore)
        }
        return (checks, reads)
    }

    /// `width` `.built` snapshots at once on an expired cache, `count` times, with every
    /// `.supervisor` turn counted.
    func bursts(_ count: Int, of width: Int) async throws -> (reads: [Int], peaks: [Int]) {
        var reads: [Int] = []
        var peaks: [Int] = []
        let built = self.built
        for _ in 0..<count {
            try await Task.sleep(for: .milliseconds(1_100))
            probe.reset()
            let readsBefore = counted.reads
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<width { group.addTask { _ = try await built.snapshot() } }
                try await group.waitForAll()
            }
            reads.append(counted.reads - readsBefore)
            peaks.append(probe.peak)
        }
        return (reads, peaks)
    }
}

/// `SightednessProving` timed where the snapshot awaits it. A class, not an actor, so it adds no
/// hop of its own: the duration is the cache's answer as `isBlind()` sees it.
private final class TimedSighting: SightednessProving, @unchecked Sendable {
    private let wrapped: CriticalTemperatureCache
    private let lock = NSLock()
    private var recorded: [Duration] = []

    init(_ wrapped: CriticalTemperatureCache) { self.wrapped = wrapped }

    var durations: [Duration] { lock.withLock { recorded } }

    func sighting() async throws -> CriticalTemperatureReport {
        let started = ContinuousClock.now
        defer {
            let took = ContinuousClock.now - started
            lock.withLock { recorded.append(took) }
        }
        return try await wrapped.sighting()
    }
}

/// The curated set, counted: every read the cache issues through it.
private final class CountingCriticalTemperatures: CriticalTemperatureSensing, @unchecked Sendable {
    private let wrapped: any CriticalTemperatureSensing
    private let lock = NSLock()
    private var count = 0

    init(_ wrapped: some CriticalTemperatureSensing) { self.wrapped = wrapped }

    var reads: Int { lock.withLock { count } }

    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        lock.withLock { count += 1 }
        return try await wrapped.readCriticalTemperatures()
    }
}

/// Every `.supervisor` turn the scheduler reports, parked or in flight, and the most held at once.
private final class SupervisorTurnProbe: SchedulerObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [ContinuousClock.Instant] = []
    private var inFlight = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    func reset() { lock.withLock { highest = parked.count + inFlight } }

    func schedulerDidObserve(_ event: SchedulerEvent) {
        lock.withLock {
            switch event {
            case .waiterParked(priority: .supervisor, let queuedAt):
                parked.append(queuedAt)
            case .turnGranted(priority: .supervisor, let queuedAt):
                if let index = parked.firstIndex(of: queuedAt) { parked.remove(at: index) }
                inFlight += 1
            case .turnEnded(priority: .supervisor):
                inFlight -= 1
            default:
                return
            }
            highest = max(highest, parked.count + inFlight)
        }
    }
}

/// A completed reconciliation that refused nothing: the baseline the measured snapshot judges.
private struct CompleteBaseline: ReconciliationBaselineReporting {
    func baseline() async -> ReconciliationBaseline { .complete }
}

/// A keystone that refuses without touching anything; the measurement never asks it.
private struct RefusingKeystone: KeystoneRestoring {
    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        throw FanControlPlaneError.controlPathNotBuilt
    }
}
