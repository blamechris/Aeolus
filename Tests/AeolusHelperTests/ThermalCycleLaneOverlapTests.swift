import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 3 holds at most one request in its lane, and the scheduler says so when it does not (ADR
/// 0012's 2026-10-18 amendment).
///
/// Both lane bounds rest on § 3 being the lane's one producer, making one call at a time: a lane
/// turn waits for at most one turn in flight only while the lane holds at most one waiter. The
/// source censuses in `ThermalCycleLaneTripwireTests` hold who names the lane. This suite holds the
/// premise where it is spent: the scheduler counts lane requests outstanding, reports one that
/// arrives while another is (`SchedulerEvent.thermalCycleLaneOverlapped`) and admits it as
/// normal, and § 3's firing episode, run over a plane whose every call holds a real turn, never
/// makes it report. `ThermalCycleLaneCounterTests` holds the count's lifetime and its re-arming.
@Suite("§ 3's lane holds one request at a time", .timeLimit(.minutes(1)))
struct ThermalCycleLaneOverlapTests {

    /// The overlap reports `events` hold, as their `outstanding` counts.
    static func overlaps(in events: [SchedulerEvent]) -> [Int] {
        events.compactMap { event in
            if case .thermalCycleLaneOverlapped(let outstanding, _) = event { return outstanding }
            return nil
        }
    }

    private static func laneGrants(in events: [SchedulerEvent]) -> Int {
        events.filter { event in
            if case .turnGranted(.thermalCycle, _) = event { return true }
            return false
        }.count
    }

    // MARK: - The scheduler

    /// Two lane requests outstanding at once — one holding the connection, one queued behind it —
    /// are reported once, when the second arrives, and both are admitted and answered. Requests
    /// one after another, and lane requests among supervisor and snapshot ones, are not reported at
    /// all.
    ///
    /// **Mutation:** delete the `report(.thermalCycleLaneOverlapped(…))` call from
    /// `SMCReadScheduler.noteThermalCycleRequest()`. Run: red — nothing is reported.
    /// **Mutation:** in `endTurn(at:)`, do not count a lane request out. Run: red at the sequential
    /// requests, which then read as outstanding together.
    @Test("Two lane requests outstanding together are reported once, and both admitted")
    func twoOutstandingLaneRequestsAreReportedOnce() async throws {
        let observer = RecordingSchedulerObserver()
        let turns = TurnHolder(observer: observer)

        for _ in 0..<3 {
            _ = try await turns.holding(at: .thermalCycle) { 0 }
        }
        let alongside = (0..<4).map { index in
            observing {
                try await turns.holding(at: index.isMultiple(of: 2) ? .supervisor : .snapshot) {
                    index
                }
            }
        }
        _ = try await turns.holding(at: .thermalCycle) { 0 }
        for (index, work) in alongside.enumerated() {
            _ = try await finished("the request at \(index)", work)
        }
        #expect(Self.overlaps(in: observer.events).isEmpty, "\(observer.events)")

        let gate = CallGate()
        let holding = observing { try await turns.holding(at: .thermalCycle) { await gate.wait() } }
        await yieldUntil("the first lane request to hold the connection") { await gate.isWaiting }
        let queued = [observing { try await turns.holding(at: .thermalCycle) { 1 } }]
        await yieldUntil("the later request to queue in the lane") {
            await turns.scheduler.queuedTurns(at: .thermalCycle) == 1
        }
        await gate.open()
        _ = try await finished("the request holding the connection", holding)
        for (index, work) in queued.enumerated() {
            #expect(try await finished("queued lane request \(index)", work) == 1)
        }

        #expect(Self.overlaps(in: observer.events) == [2], "\(observer.events)")
    }

    // MARK: - § 3

    /// § 3's firing episode, composed over a plane whose every call holds a real scheduler turn:
    /// two leased fans engaged, a firing cycle whose firmware refuses every write — two bridge jobs
    /// and the revocation's three restore attempts on each fan, all refused — a latched cycle, then
    /// the machine cooling and the firmware relenting, the latch released, and § 3's own restores
    /// read back for both fans. Every one of § 3's requests is in the lane, and no two are ever
    /// outstanding together.
    ///
    /// **Not every path § 3 has.** A latched cycle that takes a fan back with writes, and a blind
    /// cycle, are not driven here. Both are sequential by inspection, inside `isCycling`:
    /// `takeBackAnythingEngagedSinceFiring()` awaits each fan's bridge and then the revocation,
    /// and a blind cycle reads nothing more and takes back what it finds the same way. The run-time
    /// report covers them in production.
    ///
    /// **Mutation:** in `ThermalEmergency.fire(_:from:)`, bridge the held fans in a task group.
    /// Run: red — two bridge jobs outstanding in the lane.
    /// **Mutation:** in `PlaneHandbackReadBack.handbackReadings(of:)`, read the fans in a task
    /// group. Run: red — two read-backs outstanding in the lane.
    @Test("§ 3's firing episode never has two requests in its lane")
    func sectionThreesEpisodeNeverOverlapsInItsLane() async throws {
        let observer = RecordingSchedulerObserver()
        let turns = TurnHolder(observer: observer)
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)],
            stages: [
                .at(44), .at(96, writes: .refused(reason: "the scripted firmware refuses")),
                .at(44),
            ])
        let helper = await Self.helper(over: firmware, turns: turns)

        let holder = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: holder)
        try await helper.authority.apply(
            [
                FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400)),
                FanSetting(fanIndex: 1, control: .fixed(rpm: 2_400)),
            ], leaseID: lease.id, from: holder)
        let beforeEpisode = observer.events.count

        await firmware.advance()
        await helper.thermalEmergency.cycle()
        #expect(await helper.latch.isActive, "the firing cycle did not fire")
        let bridges = await firmware.attempts.filter {
            if case .bridgeThenRestore = $0 { return true }
            return false
        }
        #expect(bridges.count == 2, "the firing cycle bridged \(bridges)")
        await helper.thermalEmergency.cycle()

        await firmware.advance()
        for _ in 0..<3 where await helper.latch.isActive {
            await helper.thermalEmergency.cycle()
        }
        #expect(await !helper.latch.isActive, "the latch never released")
        let beforeReadBack = await firmware.attempts.count
        await helper.thermalEmergency.cycle()
        let readBacks = await firmware.attempts.dropFirst(beforeReadBack).filter {
            if case .readControlState = $0 { return true }
            return false
        }
        #expect(readBacks.count == 2, "§ 3 read back \(readBacks)")

        let episode = Array(observer.events.dropFirst(beforeEpisode))
        let lane = Self.laneGrants(in: episode)
        // The firing cycle alone: its read, two bridges, three refused restores on each fan.
        #expect(lane >= 1 + 2 + 2 * RestoreLimits.attemptBudget, "\(lane) lane turns")
        #expect(
            Self.overlaps(in: observer.events).isEmpty,
            "§ 3 had two requests in its lane at once: \(Self.overlaps(in: observer.events))")
    }

    /// The composed graph over `firmware`, every call through it holding a turn of `turns`.
    private static func helper(
        over firmware: ScriptedControlPlane, turns: TurnHolder
    ) async -> HelperComposition<TurnTakingPlane> {
        let helper = HelperComposition(
            plane: TurnTakingPlane(scripted: firmware, turns: turns),
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 2),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        await helper.bindSafetyRegistries()
        return helper
    }

    // MARK: - The log

    /// The report becomes one `.fault` line in the safety log, and no other event writes one.
    ///
    /// **Mutation:** in `ThermalCycleLaneWatch.schedulerDidObserve(_:)`, return before logging.
    /// Run: red.
    @Test("The overlap is written to the safety log once, at fault")
    func theOverlapIsWrittenToTheSafetyLog() {
        let lines = RecordedLog()
        let watch = ThermalCycleLaneWatch(
            log: SafetyLog(recording: { level, line in lines.append(level, line) }))
        watch.schedulerDidObserve(.turnGranted(priority: .thermalCycle, queuedAt: .now))
        watch.schedulerDidObserve(.wholeReadSucceeded(priority: .thermalCycle))
        watch.schedulerDidObserve(
            .thermalCycleLaneOverlapped(outstanding: 2, overlappingArrivals: 1))

        let written = lines.lines(containing: "requests were outstanding at once")
        #expect(written.count == 1, "\(written)")
        #expect(written.first?.contains("1 request(s) have arrived") == true, "\(written)")
        #expect(lines.levels(containing: "requests were outstanding at once") == [.fault])
    }
}

/// Holds a call inside its turn until the test opens it.
private actor CallGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { waiter != nil }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
