import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// § 3's lane on real write turns (#439's W1, W4, W5; #440's B1–B5; the B1 plan's C28), composed
/// over the production plane with `.built`: the graph as the daemon builds it, over `FirmwareSMC`.
/// Every write the fake takes is read off with the admission of the scheduler turn it fell in.
@Suite("§ 3's lane on the production plane's write turns", .timeLimit(.minutes(1)))
struct ProductionLaneTests {

    static let refused = FirmwareSMC.WriteAnswer.refuses(code: 0x85)

    /// The admissions of the writes after `mark`, by key.
    private static func admissions(
        _ machine: ProductionWriteMachine, since mark: Int
    ) -> Set<SMCReadPriority?> {
        Set(machine.admittedWrites(since: mark).map(\.priority))
    }

    // MARK: - W1 / B1: § 3's writes in the lane, everyone else's at supervisor

    /// Level 6's engagement and command, § 3's bridge and its revocation's restores, § 4's sleep,
    /// and § 7's panic, each through the composed graph: § 3's writes are in the lane and every
    /// other mechanism's at `.supervisor`. The verbs take no admission; the views do.
    ///
    /// **Mutation:** in `HelperComposition.init`, give § 3 `SafetyActorWriter(plane: plane,
    /// level: .thermalEmergency)`. Run: red here — the bridge is at `.supervisor`.
    /// **Mutation:** in `ThermalCycleHandback.init`, drop `.admitted(at: .thermalCycle)`. Run: red
    /// here — the firing's restores are at `.supervisor`.
    @Test("§ 3's writes are in the lane and level 6's, § 4's and § 7's at supervisor")
    func onlySectionThreesWritesAreInTheLane() async throws {
        let machine = await ProductionWriteMachine()
        let lease = try await machine.lease(fans: [0])

        var mark = machine.firmware.log.entries.count
        try await machine.apply(rpm: 2_400, under: lease)
        let levelSix = machine.admittedWrites(since: mark)
        #expect(levelSix.map(\.key) == ["F0Md", "F0Tg"], "\(levelSix)")
        #expect(Self.admissions(machine, since: mark) == [.supervisor], "level 6: \(levelSix)")

        await machine.firmware.setCriticalTemperatures(96)
        mark = machine.firmware.log.entries.count
        await machine.helper.thermalEmergency.cycle()
        #expect(await machine.helper.latch.isActive, "the cycle did not fire")
        let firing = machine.admittedWrites(since: mark)
        #expect(firing.map(\.key).prefix(2) == ["F0Tg", "F0Md"], "\(firing)")
        #expect(Self.admissions(machine, since: mark) == [.thermalCycle], "§ 3: \(firing)")

        await machine.firmware.setCriticalTemperatures(44)
        for _ in 0..<3 { await machine.helper.thermalEmergency.cycle() }
        #expect(await !machine.helper.latch.isActive, "the latch never released")

        mark = machine.firmware.log.entries.count
        await machine.helper.powerResponder.respond(
            to: SystemPowerNotification(event: .willSleep, generation: 1) {})
        #expect(!machine.admittedWrites(since: mark).isEmpty, "§ 4 wrote nothing")
        #expect(Self.admissions(machine, since: mark) == [.supervisor], "§ 4")
        await machine.helper.powerResponder.respond(
            to: SystemPowerNotification(event: .didWake, generation: 2) {})

        mark = machine.firmware.log.entries.count
        try await machine.helper.authority.restoreAllToAutomatic(from: machine.holder)
        #expect(!machine.admittedWrites(since: mark).isEmpty, "§ 7 wrote nothing")
        #expect(Self.admissions(machine, since: mark) == [.supervisor], "§ 7")
    }

    // MARK: - B2: after a firing, every other path at supervisor

    /// K6 on real write turns: after a firing whose revocation handed back in the lane, the TTL, a
    /// release, § 5's revocation, § 6's pass and the signal teardown each write at `.supervisor`.
    ///
    /// **Mutation (K6):** in `HelperComposition.init`, give `LeaseAuthority` a
    /// `ThermalCycleHandback` as its `restorer:`. Run: red here, at the lease-core paths.
    @Test("After a firing, every other path writes at supervisor")
    func afterAFiringEveryOtherPathIsAtSupervisor() async throws {
        let machine = await ProductionWriteMachine()
        let leases = machine.helper.leases
        let lease = try await machine.lease(fans: [0])
        try await machine.apply(rpm: 2_400, under: lease)
        await machine.firmware.setCriticalTemperatures(96)
        let mark = machine.firmware.log.entries.count
        await machine.helper.thermalEmergency.cycle()
        #expect(Self.admissions(machine, since: mark) == [.thermalCycle], "the firing")
        await machine.firmware.setCriticalTemperatures(44)
        for _ in 0..<3 { await machine.helper.thermalEmergency.cycle() }
        #expect(await !machine.helper.latch.isActive, "the latch never released")

        func writes(
            of work: () async throws -> Void
        ) async rethrows -> [(key: String, priority: SMCReadPriority?)] {
            let mark = machine.firmware.log.entries.count
            try await work()
            return machine.admittedWrites(since: mark)
        }
        let paths: [(String, [(key: String, priority: SMCReadPriority?)])] = [
            (
                "the TTL",
                try await writes {
                    let ttl = try await machine.lease(fans: [0])
                    try await machine.apply(rpm: 2_400, under: ttl)
                    machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
                    await leases.expireLapsedLeases()
                }
            ),
            (
                "a release",
                try await writes {
                    let released = try await machine.lease(fans: [0])
                    try await machine.apply(rpm: 2_400, under: released)
                    try await machine.helper.authority.releaseLease(
                        id: released, from: machine.holder)
                }
            ),
            (
                "§ 5's revocation",
                try await writes {
                    let reclaimed = try await machine.lease(fans: [0])
                    try await machine.apply(rpm: 2_400, under: reclaimed)
                    _ = await leases.revokeLease(
                        id: reclaimed, forFan: 0, because: .systemReclaimed)
                }
            ),
            (
                "§ 6's pass",
                try await writes {
                    await machine.firmware.setRegister(smcKey("F0Md"), [0x01])
                    await machine.helper.reconcileFans()
                }
            ),
            (
                "the signal teardown",
                try await writes {
                    _ = try await machine.lease(fans: [0])
                    await machine.tearDown()
                }
            ),
        ]
        for (path, written) in paths {
            #expect(written.contains { $0.key == "F0Md" }, "\(path) restored nothing: \(written)")
            #expect(Set(written.map(\.priority)) == [.supervisor], "\(path): \(written)")
        }
    }

    // MARK: - B3: § 5's notice before the request, and the ledger's bracket

    /// A release on the write plane, held at its restore's turn by a parked read: by then § 5 has
    /// been told — its notice comes before the restore is requested — and the fan is in the lease
    /// core's `releasing` throughout.
    ///
    /// **Mutation:** in `HelperFanRestorer.handBack(_:because:through:)`, tell § 5 after the bound
    /// rather than before it. Run: red here — § 5 still watches the fan while its restore waits.
    @Test("A release tells § 5 before its restore is requested, and holds the fan mid-handback")
    func aReleaseTellsSectionFiveFirst() async throws {
        let machine = await ProductionWriteMachine()
        let lease = try await machine.lease(fans: [0])
        try await machine.apply(rpm: 2_400, under: lease)
        #expect(await machine.helper.reclamationWatchdog.fansUnderManualControl == [0])
        let ledger = try #require(
            Mirror(reflecting: machine.plane).children.first { $0.label == "ledger" }?.value
                as? PlaneWriteLedger)
        await machine.firmware.holdReads()

        let read = observing { try await machine.scheduler.read(keys: ["F0Ac"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await machine.firmware.readsParked == 1 }
        let release = observing {
            try await machine.helper.authority.releaseLease(id: lease, from: machine.holder)
        }
        await yieldUntil("the release's restore to queue") {
            await machine.scheduler.queuedTurns(at: .supervisor) == 1
        }

        #expect(
            await machine.helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            "§ 5 was told after the restore was requested")
        #expect(ledger.engagedFans == [0], "the restore was issued before its turn")
        #expect(await machine.helper.leases.fansMidHandback == [0], "the fan left `releasing`")

        await machine.firmware.releaseReads()
        _ = try await finished("the read", read)
        _ = try await finished("the release", release)
        #expect(await machine.helper.leases.fansMidHandback.isEmpty)
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0])
    }

    /// § 3's own handback on the write plane, refused by the firmware on every attempt: the fan
    /// lands in the abandoned register, and the next grant over it is refused durably.
    @Test("A refused § 3 handback on the write plane is recorded abandoned")
    func aRefusedSectionThreeHandbackIsAbandoned() async throws {
        let machine = await ProductionWriteMachine()
        let lease = try await machine.lease(fans: [0])
        try await machine.apply(rpm: 2_400, under: lease)
        await machine.firmware.setDefaultWrite(Self.refused)
        await machine.firmware.setCriticalTemperatures(96)

        await machine.helper.thermalEmergency.cycle()

        #expect(await machine.helper.latch.isActive)
        #expect(await machine.helper.leases.fansWithAbandonedHandbacks == [0])
        #expect(await machine.helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - B5: one channel and one ledger, at rest and after a firing

    /// Every plane the composed graph stores — § 3's four lane sites among them — holds the
    /// plane's channel and its ledger by identity, at rest and after a firing; the lane sites are
    /// at the lane and every other at `.supervisor`.
    ///
    /// **Mutation:** in `SMCFanControlPlane.admitted(at:)`, rebuild the view through `init` with
    /// the channel. Run: red here — each view holds a ledger of its own.
    @Test("Every stored plane shares the channel and the ledger, at rest and after a firing")
    func everyStoredPlaneSharesTheChannelAndTheLedger() async throws {
        let machine = await ProductionWriteMachine()
        func check(_ when: String) throws {
            let found = ThermalCycleLaneWriterTests.stored(
                SMCFanControlPlane.self, reachableFrom: machine.helper)
            let ledger = try #require(
                PlaneViewTests.storedProperty("ledger", of: machine.plane) as? PlaneWriteLedger)
            #expect(found.count > 10, "\(when): \(found.keys.sorted())")
            var lane = 0
            for (site, views) in found {
                for view in views {
                    let channel = PlaneViewTests.storedProperty("writeChannel", of: view)
                    #expect(
                        (channel as? any SMCWriteChannel) === machine.firmware,
                        "\(when): \(site) holds another channel")
                    #expect(
                        PlaneViewTests.storedProperty("ledger", of: view) as? PlaneWriteLedger
                            === ledger, "\(when): \(site) holds another ledger")
                    if view.admission == .thermalCycle { lane += 1 }
                }
            }
            #expect(
                lane >= ThermalCycleLaneWriterTests.laneSites.count, "\(when): \(lane) lane views")
        }

        try check("at rest")
        let lease = try await machine.lease(fans: [0])
        try await machine.apply(rpm: 2_400, under: lease)
        await machine.firmware.setCriticalTemperatures(96)
        await machine.helper.thermalEmergency.cycle()
        #expect(await machine.helper.latch.isActive)
        try check("after a firing")
    }
}
