import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// § 3's lane under load, on the production plane's write turns (#439's W4 and W5, #440's B4, the
/// B1 plan's C28): sustained supervisor readers and continuous snapshot reads contend for the one
/// connection while § 3 fires or an engagement polls, and § 3's turns are still each granted
/// behind at most the turn in flight.
///
/// The readers really contend: each is its own task looping `SMCReadScheduler.read` through the
/// fake, and every read holds its turn for `roundTrip` (`TurnHoldingProvider`), so while one
/// reader holds the turn the others are parked behind it — up to N − 2 supervisor waiters at
/// once, which each test asserts was the queue its lane waiters parked against. Whether a lane
/// turn waited for more than the turn in flight is read off the scheduler's own events: after a
/// lane waiter parks, the next turn granted must be its own.
@Suite("§ 3's lane under load, on the production plane", .timeLimit(.minutes(1)))
struct ProductionLaneLoadTests {

    /// A flag the load loops poll.
    final class Stop: Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        var isSet: Bool { flag.withLock { $0 } }
        func set() { flag.withLock { $0 = true } }
    }

    /// The log range a mid-firing effect covered, recorded from inside it.
    final class Spawned: Sendable {
        private let recorded = OSAllocatedUnfairLock<Range<Int>?>(initialState: nil)
        func record(_ range: Range<Int>) { recorded.withLock { $0 = range } }
        var range: Range<Int>? { recorded.withLock { $0 } }
    }

    /// How long every read holds its turn: a round trip's order of magnitude, and long enough that
    /// a parked reader is a continuation, not a task spinning on the pool.
    static let roundTrip: Duration = .milliseconds(1)

    /// A machine whose reads hold their turns for `roundTrip`.
    static func machine(unlock: FirmwareSMC.Unlock = .naive) async -> ProductionWriteMachine {
        await ProductionWriteMachine(unlock: unlock, readsHold: roundTrip)
    }

    /// `readers` supervisor readers and one snapshot reader, each looping until `stop` — or, if a
    /// test never sets it, for no longer than `abandonedAfter`.
    static func load(
        _ readers: Int, on machine: ProductionWriteMachine, until stop: Stop
    ) -> [Task<Void, Never>] {
        let scheduler = machine.scheduler
        let deadline = ContinuousClock.now + abandonedAfter
        let snapshotKeys =
            CriticalSensorSet.mac16x5.keys.map(\.rawValue) + [
                "F0Ac", "F1Ac", "F0Tg", "F1Tg", "F0Mn", "F1Mn", "F0Mx", "F1Mx", "FNum",
            ]
        var tasks = (0..<readers).map { _ in
            Task {
                while !stop.isSet, ContinuousClock.now < deadline {
                    _ = try? await scheduler.read(keys: ["F1Ac"], at: .supervisor)
                }
            }
        }
        tasks.append(
            Task {
                while !stop.isSet, ContinuousClock.now < deadline {
                    _ = try? await scheduler.snapshotReader.read(keys: snapshotKeys)
                }
            })
        return tasks
    }

    /// The load's backstop: past this, a reader stops whether or not its test set `stop`.
    static let abandonedAfter: Duration = .seconds(30)

    /// How many supervisor waiters were parked each time a lane waiter parked — the queue § 3's
    /// turns were granted past. A grant of a supervisor turn while none is parked is a turn
    /// granted at once, with nobody waiting, so it takes nothing off the count.
    static func supervisorWaitersAtLaneParks(in events: [SchedulerEvent]) -> [Int] {
        var parked = 0
        var atLaneParks: [Int] = []
        for event in events {
            switch event {
            case .waiterParked(.supervisor, _): parked += 1
            case .turnGranted(.supervisor, _): parked = max(0, parked - 1)
            case .waiterParked(.thermalCycle, _): atLaneParks.append(parked)
            default: break
            }
        }
        return atLaneParks
    }

    /// Every lane waiter in `events` whose next granted turn was not its own: a lane turn that
    /// waited for more than the turn in flight.
    static func laneWaitsPastTheTurnInFlight(in events: [SchedulerEvent]) -> [Int] {
        var late: [Int] = []
        for (index, event) in events.enumerated() {
            guard case .waiterParked(.thermalCycle, _) = event else { continue }
            let next = events[(index + 1)...].first {
                if case .turnGranted = $0 { return true }
                return false
            }
            guard case .turnGranted(.thermalCycle, _)? = next else {
                late.append(index)
                continue
            }
        }
        return late
    }

    static func overlaps(in events: [SchedulerEvent]) -> Int {
        events.filter {
            if case .thermalCycleLaneOverlapped = $0 { return true }
            return false
        }.count
    }

    static func laneGrants(in events: [SchedulerEvent]) -> Int {
        events.filter {
            if case .turnGranted(.thermalCycle, _) = $0 { return true }
            return false
        }.count
    }

    // MARK: - W4 / B4

    /// A firing cycle with every write refused, under `outstanding` reads — N − 1 sustained
    /// supervisor readers and § 3 — with continuous snapshots, and with the firing's own lease's
    /// TTL sweep and a § 5 revocation of it landing mid-firing, after § 3's first bridge job and
    /// before its second (#440's B4):
    /// - the TTL sweep wins the lapsed lease and hands both fans back at `.supervisor`, and § 5's
    ///   revocation finds the lease gone;
    /// - every lane turn is granted behind at most the turn in flight, there are no more of them
    ///   than the allowance counts, and the overlap report stays silent.
    ///
    /// **What is deterministic, and what is not.** The teardowns run awaited inside § 3's firing
    /// (`InterferingWritePlane.interfere(afterBridge:with:)`), so which one restores, and so the
    /// admission of its writes, is fixed. One lease is held at a time
    /// (`.leaseHeldByAnotherClient`),
    /// so a teardown concurrent with § 3's own lane requests would race § 3 for the same lease and
    /// fix nothing; the overlap and the allowance are therefore asserted as properties of this run,
    /// and they are not what a misrouted teardown turns red.
    ///
    /// **Mutation (B4):** in `HelperComposition.init`, give `LeaseAuthority` § 3's handback as its
    /// standing `restorer:`. Run: red here — the TTL's hand-back is in the lane.
    /// **Mutation (W4):** in `SMCReadScheduler.withWriteTurn`, take every write turn at
    /// `.supervisor`. Run: red here — § 3's bridges leave the lane.
    @Test(
        "A firing under load stays in its lane, and teardowns landing mid-firing at supervisor",
        arguments: [12, 40])
    func aFiringUnderLoadStaysInItsLane(_ outstanding: Int) async throws {
        let machine = await Self.machine()
        let leases = machine.helper.leases
        let held = try await machine.lease(fans: [0, 1])
        try await machine.apply(rpm: 2_400, fans: [0, 1], under: held)
        machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))

        await machine.firmware.setDefaultWrite(.refuses(code: 0x85))
        await machine.firmware.setCriticalTemperatures(96)
        let window = Spawned()
        let firmware = machine.firmware
        await machine.writes.interfere(afterBridge: 1) {
            let begun = firmware.log.entries.count
            await leases.expireLapsedLeases()
            _ = await leases.revokeLease(id: held, forFan: 0, because: .systemReclaimed)
            window.record(begun..<firmware.log.entries.count)
        }
        let stop = Stop()
        let eventMark = machine.observer.events.count
        let load = Self.load(outstanding - 1, on: machine, until: stop)
        defer { stop.set() }
        await yieldUntil("every reader but the one holding the turn to queue") {
            await machine.scheduler.queuedTurns(at: .supervisor) >= outstanding - 2
        }

        await machine.helper.thermalEmergency.cycle()
        stop.set()
        for task in load { await task.value }

        let events = Array(machine.observer.events.dropFirst(eventMark))
        let queued = Self.supervisorWaitersAtLaneParks(in: events)
        #expect(
            (queued.max() ?? 0) >= (outstanding - 2) / 2,
            "§ 3's lane waiters parked against \(queued) supervisor waiters: not the load")
        #expect(await machine.helper.latch.isActive, "the cycle did not fire")
        #expect(await machine.writes.didFire, "the teardowns never landed mid-firing")
        #expect(await leases.leaseCount == 0)
        #expect(
            Self.laneWaitsPastTheTurnInFlight(in: events).isEmpty,
            "a lane turn waited past the turn in flight")
        #expect(Self.overlaps(in: events) == 0, "the lane overlapped")
        let lane = Self.laneGrants(in: events)
        #expect(lane >= 3, "\(lane) lane turns: the read and two bridges at least")
        #expect(lane <= WatchdogLimits.thermalCycleTurns(fans: 2), "\(lane) lane turns")

        let range = try #require(window.range, "the teardowns' window was not recorded")
        let teardownWrites = Array(
            machine.admittedWrites(since: range.lowerBound).prefix(
                Self.writes(in: firmware.log.entries[range])))
        #expect(
            Set(teardownWrites.map(\.key)) == ["F0Md", "F1Md"],
            "the TTL handed back \(teardownWrites), not fans 0 and 1")
        #expect(
            Set(teardownWrites.map(\.priority)) == [.supervisor],
            "a teardown landing mid-firing wrote in the lane: \(teardownWrites)")
    }

    /// How many writes `entries` holds.
    static func writes(in entries: ArraySlice<FirmwareLog.Entry>) -> Int {
        entries.filter {
            if case .write = $0 { return true }
            return false
        }.count
    }

    // MARK: - C28 / W5

    /// § 3 completes cycles while an engagement polls under sustained supervisor load: the step's
    /// turns are separate, so the lane is granted between them, and each lane turn behind at most
    /// the turn in flight.
    ///
    /// **Mutation (C28):** in `SMCFanControlPlane.engageManualControl(of:)`, step inside the one
    /// turn until engaged, holding it across the poll. Run: red here — no lane turn falls between
    /// the engagement's first and last mode write.
    @Test("§ 3 keeps completing cycles in its lane while an engagement polls under load")
    func sectionThreeCyclesDuringAPoll() async throws {
        let machine = await Self.machine(unlock: .heldUntilForced(stepsToYield: 6))
        let lease = try await machine.lease(fans: [0])
        let stop = Stop()
        let eventMark = machine.observer.events.count
        let logMark = machine.firmware.log.entries.count
        let load = Self.load(11, on: machine, until: stop)
        defer { stop.set() }
        await yieldUntil("every reader but the one holding the turn to queue") {
            await machine.scheduler.queuedTurns(at: .supervisor) >= 10
        }

        let applying = observing { try await machine.apply(rpm: 2_400, under: lease) }
        var completed = 0
        while await !applying.isFinished.isSet, !Task.isCancelled {
            if await machine.helper.thermalEmergency.cycle() { completed += 1 }
            await Task.yield()
        }
        stop.set()
        for task in load { await task.value }
        _ = try await finished("the apply", applying)

        let entries = Array(machine.firmware.log.entries.dropFirst(logMark))
        let modeWrites = entries.indices.filter {
            if case .write(let key, let bytes, _) = entries[$0] {
                return key == smcKey("F0Md") && bytes == [0x01]
            }
            return false
        }
        let first = try #require(modeWrites.first)
        let last = try #require(modeWrites.last)
        let laneDuringPoll = entries[first...last].filter { $0 == .turnGranted(.thermalCycle) }
        #expect(modeWrites.count >= 7, "the engagement took \(modeWrites.count) mode writes")
        #expect(completed >= 2, "§ 3 completed \(completed) cycles during the engagement")
        #expect(!laneDuringPoll.isEmpty, "§ 3 took no lane turn while the engagement polled")
        let events = Array(machine.observer.events.dropFirst(eventMark))
        let queued = Self.supervisorWaitersAtLaneParks(in: events)
        #expect(
            (queued.max() ?? 0) >= 5,
            "§ 3's lane waiters parked against \(queued) supervisor waiters: not the load")
        #expect(Self.laneWaitsPastTheTurnInFlight(in: events).isEmpty)
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0x01], "the fan did not engage")
    }
}
