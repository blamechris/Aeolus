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
/// fake, so up to N − 1 supervisor waiters are parked at once. Whether a lane turn waited for more
/// than the turn in flight is read off the scheduler's own events: after a lane waiter parks, the
/// next turn granted must be its own.
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

    /// `readers` supervisor readers and one snapshot reader, each looping until `stop`.
    static func load(
        _ readers: Int, on machine: ProductionWriteMachine, until stop: Stop
    ) -> [Task<Void, Never>] {
        let scheduler = machine.scheduler
        let snapshotKeys =
            CriticalSensorSet.mac16x5.keys.map(\.rawValue) + [
                "F0Ac", "F1Ac", "F0Tg", "F1Tg", "F0Mn", "F1Mn", "F0Mx", "F1Mx", "FNum",
            ]
        var tasks = (0..<readers).map { _ in
            Task {
                while !stop.isSet {
                    _ = try? await scheduler.read(keys: ["F1Ac"], at: .supervisor)
                }
            }
        }
        tasks.append(
            Task {
                while !stop.isSet {
                    _ = try? await scheduler.snapshotReader.read(keys: snapshotKeys)
                }
            })
        return tasks
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
    /// admission of its writes, is fixed. One lease is held at a time (`.leaseHeldByAnotherClient`),
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
        let machine = await ProductionWriteMachine()
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
        await yieldUntil("the readers to queue") {
            await machine.scheduler.queuedTurns(at: .supervisor) >= min(outstanding - 2, 8)
        }

        await machine.helper.thermalEmergency.cycle()
        stop.set()
        for task in load { await task.value }

        let events = Array(machine.observer.events.dropFirst(eventMark))
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
        let machine = await ProductionWriteMachine(unlock: .heldUntilForced(stepsToYield: 6))
        let lease = try await machine.lease(fans: [0])
        let stop = Stop()
        let eventMark = machine.observer.events.count
        let logMark = machine.firmware.log.entries.count
        let load = Self.load(11, on: machine, until: stop)

        let applying = observing { try await machine.apply(rpm: 2_400, under: lease) }
        var completed = 0
        while await !applying.isFinished.isSet {
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
        #expect(Self.laneWaitsPastTheTurnInFlight(in: events).isEmpty)
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0x01], "the fan did not engage")
    }
}
