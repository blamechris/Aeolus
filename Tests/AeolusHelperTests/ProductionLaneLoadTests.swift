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

    /// Tasks started from inside a firmware hook, kept so the test can await them.
    final class Spawned: Sendable {
        private let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
        func add(_ task: Task<Void, Never>) { tasks.withLock { $0.append(task) } }
        func wait() async { for task in tasks.withLock({ $0 }) { await task.value } }
        var count: Int { tasks.withLock { $0.count } }
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
    /// supervisor readers and § 3 — with continuous snapshots, while the firing's own lease's TTL
    /// sweep and a § 5 revocation of it land mid-firing (started from inside § 3's bridge job, so
    /// they race § 3's revocation for the one lease): every lane turn is granted behind at most
    /// the turn in flight, there are no more of them than the allowance counts, the overlap report
    /// stays silent, and every write is in a turn of the two admissions the safety path has.
    ///
    /// The race is real, so which teardown hands the lease back varies run to run; what holds
    /// either way is asserted. One lease is held at a time (`.leaseHeldByAnotherClient`), so the
    /// TTL and § 5 can only race § 3 for the same one.
    ///
    /// **Mutation (B4):** in `HelperComposition.init`, build § 3's handback before the lease core
    /// and give it to `LeaseAuthority` as `restorer:` — the TTL sweep and § 5's revocation then
    /// restore in the lane beside § 3. Run: red here — the overlap is reported.
    /// **Mutation (W4):** in `SMCReadScheduler.withWriteTurn`, take every write turn at
    /// `.supervisor`. Run: red here — § 3's bridge waits behind the readers.
    @Test(
        "A firing under load is granted behind the turn in flight, within the allowance",
        arguments: [12, 40])
    func aFiringUnderLoadStaysInItsLane(_ outstanding: Int) async throws {
        let machine = await ProductionWriteMachine()
        let leases = machine.helper.leases
        let held = try await machine.lease(fans: [0, 1])
        try await machine.apply(rpm: 2_400, fans: [0], under: held)
        machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))

        await machine.firmware.setDefaultWrite(.refuses(code: 0x85))
        await machine.firmware.setCriticalTemperatures(96)
        let midFiring = Spawned()
        await machine.firmware.onNext(.write(smcKey("F0Tg"))) {
            midFiring.add(Task { await leases.expireLapsedLeases() })
            midFiring.add(
                Task {
                    _ = await leases.revokeLease(id: held, forFan: 0, because: .systemReclaimed)
                })
        }
        let stop = Stop()
        let eventMark = machine.observer.events.count
        let logMark = machine.firmware.log.entries.count
        let load = Self.load(outstanding - 1, on: machine, until: stop)
        await yieldUntil("the readers to queue") {
            await machine.scheduler.queuedTurns(at: .supervisor) >= min(outstanding - 2, 8)
        }

        await machine.helper.thermalEmergency.cycle()
        await midFiring.wait()
        stop.set()
        for task in load { await task.value }

        let events = Array(machine.observer.events.dropFirst(eventMark))
        #expect(await machine.helper.latch.isActive, "the cycle did not fire")
        #expect(midFiring.count == 2, "the mid-firing teardowns were never started")
        #expect(await leases.leaseCount == 0, "the lease outlived the firing and its races")
        #expect(
            Self.laneWaitsPastTheTurnInFlight(in: events).isEmpty,
            "a lane turn waited past the turn in flight")
        #expect(Self.overlaps(in: events) == 0, "the lane overlapped")
        let lane = Self.laneGrants(in: events)
        #expect(lane >= 2, "\(lane) lane turns: the read and the bridge at least")
        #expect(lane <= WatchdogLimits.thermalCycleTurns(fans: 2), "\(lane) lane turns")
        let written = machine.admittedWrites(since: logMark)
        #expect(written.contains { $0.key == "F1Md" }, "nothing handed fan 1 back: \(written)")
        #expect(
            Set(written.map(\.priority)).isSubset(of: [.thermalCycle, .supervisor]),
            "a write fell outside a safety turn: \(written)")
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
