import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Only § 3's turns take § 3's lane, in the composed graph (ADR 0012's 2026-10-18 amendment).
///
/// On the lane: § 3's critical read, its owed read-backs and the restores its own revocation
/// causes, which reach the lane through the handback § 3 holds and lends (#440). At `.supervisor`:
/// the cache's source, § 6, § 7's read-back, the grant's foreign-control and bounds reads, § 5's
/// and § 6's reads, level 6, and every restore the restorer issues itself, whatever its cause.
/// `ThermalCycleLaneWriterTests` holds the other mechanisms' writes. Every call the scripted
/// firmware receives is recorded with
/// the admission of the view it came through (`ScriptedControlPlane.admittedAttempts`), so each
/// mechanism is driven in turn and its calls are read off by phase.
@Suite("Only § 3 takes § 3's lane, in the composed graph", .timeLimit(.minutes(1)))
struct ThermalCycleLaneRoutingTests {

    /// The composed helper over one scripted firmware, bound as bring-up binds it.
    private struct Machine {
        let firmware: ScriptedControlPlane
        let helper: HelperComposition<ScriptedControlPlane>
        let holder = ConnectionID()
        /// The lease core's clock, which a TTL scenario advances.
        let clock = TestClock()

        init(stages: [ScriptedControlPlane.Stage], fans: Int = 2) async {
            let conditions = Dictionary(
                uniqueKeysWithValues: (0..<fans).map {
                    ($0, ScriptedControlPlane.FanCondition.automatic(at: 1_800))
                })
            firmware = ScriptedControlPlane(fans: conditions, stages: stages)
            helper = HelperComposition(
                plane: firmware,
                snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: fans),
                criticalSensors: .mac16x5,
                roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
                clock: clock,
                log: HelperRestorerTests.helperLog,
                leaseLog: LeaseFixture.log,
                safetyLog: HelperRestorerTests.safetyLog,
                // A teardown that ends nothing: the shipping termination would end this test
                // process, successfully, with the run unfinished.
                teardown: TeardownSeams(
                    sources: RecordingSignalSources(), terminate: TeardownJournal().terminate))
            await helper.bindSafetyRegistries()
        }

        /// What `work` made the firmware do, with the admission each call came through.
        func calls(
            during work: () async throws -> Void
        ) async rethrows -> [ScriptedControlPlane.AdmittedAttempt] {
            let before = await firmware.admittedAttempts.count
            try await work()
            return Array(await firmware.admittedAttempts.dropFirst(before))
        }

        func lease(_ fans: [Int]) async throws -> UUID {
            try await helper.authority.acquireLease(LeaseFixture.request(fans: fans), from: holder)
                .id
        }
    }

    private static let nominal = ScriptedControlPlane.Stage.nominal(
        temperatures: LeaseFixture.nominalDieTemperatures)

    private static let refusing = ScriptedControlPlane.Stage(
        temperatures: LeaseFixture.nominalDieTemperatures,
        writes: .refused(reason: "the scripted firmware refuses every write"))

    /// Above § 3's ceiling, with every write refused: a firing cycle whose revocation's restores
    /// are each tried the whole budget.
    private static let hotAndRefusing = ScriptedControlPlane.Stage.at(
        96, writes: .refused(reason: "the scripted firmware refuses every write"))

    /// The restore attempts among `calls`, whatever their scope.
    private static func restores(
        _ calls: [ScriptedControlPlane.AdmittedAttempt]
    ) -> [ScriptedControlPlane.AdmittedAttempt] {
        calls.filter {
            if case .restoreToAutomatic = $0.attempt { return true }
            return false
        }
    }

    /// The admissions `calls` came through.
    private static func admissions(
        _ calls: [ScriptedControlPlane.AdmittedAttempt]
    ) -> Set<PlaneAdmission> {
        Set(calls.map(\.admission))
    }

    // MARK: - L3

    /// Each mechanism, in turn, through the composed graph: § 6's pass, a grant, level 6's
    /// `apply`, § 5's cycle, a release, § 3's quiet cycle with an owed read-back, and § 7's panic
    /// with a refused handback for it to read back. § 3's phase is the only one on the lane, and
    /// the lane is used by nothing else.
    ///
    /// **Mutation:** in `HelperComposition.init`, build the cache over
    /// `telemetry.admitted(at: .thermalCycle)`. Run: red at the grant's phase.
    /// **Mutation:** in `StartupReconciliation.fansReadingAutomatic(among:)`, read through
    /// `handbackReadBack(admittedAt: .thermalCycle)`. Run: red at the panic's phase.
    /// **Mutation:** in `HelperComposition.init`, give § 3 `telemetry:` itself. Run: red at § 3's
    /// phase.
    @Test("Only § 3's turns take the lane, mechanism by mechanism")
    func onlySectionThreeTakesTheLane() async throws {
        let machine = await Machine(stages: [Self.nominal, Self.refusing, Self.nominal])
        let helper = machine.helper

        let reconciliation = await machine.calls { await helper.reconcileFans() }
        #expect(reconciliation.contains { $0.attempt == .readControlState(fan: 0) })
        #expect(Self.admissions(reconciliation) == [.supervisor], "§ 6: \(reconciliation)")

        var leaseID = UUID()
        let grant = try await machine.calls { leaseID = try await machine.lease([0]) }
        #expect(grant.contains { $0.attempt == .readEnvelope(fan: 0) }, "the grant read no bounds")
        #expect(grant.contains { $0.attempt == .readControlState(fan: 0) })
        #expect(
            grant.contains {
                if case .readCriticalTemperatures = $0.attempt { return true }
                return false
            }, "the grant's cold cache did not read")
        #expect(Self.admissions(grant) == [.supervisor], "the grant: \(grant)")

        let apply = try await machine.calls {
            try await helper.authority.apply(
                [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))], leaseID: leaseID,
                from: machine.holder)
        }
        #expect(apply.contains { $0.attempt == .engageManualControl(fan: 0) })
        #expect(Self.admissions(apply) == [.supervisor], "level 6: \(apply)")

        let reclamation = await machine.calls { await helper.reclamationWatchdog.cycle() }
        #expect(reclamation.contains { $0.attempt == .readControlState(fan: 0) })
        #expect(Self.admissions(reclamation) == [.supervisor], "§ 5: \(reclamation)")

        let release = try await machine.calls {
            try await helper.authority.releaseLease(id: leaseID, from: machine.holder)
        }
        #expect(release.contains { $0.attempt == .restoreToAutomatic(.fan(0)) })
        #expect(Self.admissions(release) == [.supervisor], "the release: \(release)")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])

        let cycle = await machine.calls { await helper.thermalEmergency.cycle() }
        #expect(cycle.contains { $0.attempt == .readControlState(fan: 0) }, "no owed read-back")
        #expect(
            cycle.contains {
                if case .readCriticalTemperatures = $0.attempt { return true }
                return false
            }, "§ 3 did not read")
        #expect(Self.admissions(cycle) == [.thermalCycle], "§ 3: \(cycle)")

        try await Self.drivePanicWithAnAbandonedHandback(on: machine)

        let lane = await machine.firmware.admittedAttempts.filter { $0.admission == .thermalCycle }
        #expect(lane == cycle, "something other than § 3 took the lane: \(lane)")
    }

    /// § 7's half of `onlySectionThreeTakesTheLane`: fan 1's handback is refused into the lease
    /// core's register, the firmware relents, and the panic verb's sweep hands it back and reads it
    /// back — every call at `.supervisor`.
    private static func drivePanicWithAnAbandonedHandback(on machine: Machine) async throws {
        await machine.firmware.advance()
        let second = try await machine.lease([1])
        try await machine.helper.authority.releaseLease(id: second, from: machine.holder)
        #expect(
            await machine.firmware.attempts.filter { $0 == .restoreToAutomatic(.fan(1)) }.count
                == RestoreLimits.attemptBudget, "fan 1's handback was not refused into the register"
        )

        await machine.firmware.advance()
        let panic = try await machine.calls {
            try await machine.helper.authority.restoreAllToAutomatic(from: machine.holder)
        }
        #expect(panic.contains { $0.attempt == .restoreToAutomatic(.everyFan) })
        #expect(
            panic.last?.attempt == .readControlState(fan: 1),
            "§ 7 did not read back the handback it lifted: \(panic)")
        #expect(Self.admissions(panic) == [.supervisor], "§ 7: \(panic)")
    }

    /// The production plane in the same graph, through the real scheduler: § 3's critical read is
    /// granted in the lane, the cache's flight at `.supervisor`, and a client snapshot read through
    /// the production `snapshotReader` at `.snapshot`.
    ///
    /// **Mutation:** in `HelperComposition.init`, give § 3 `telemetry:` itself. Run: red — § 3's
    /// read is granted at `.supervisor`.
    /// **Mutation:** default `SMCReadScheduler.read(keys:at:)`'s priority to `.thermalCycle` and
    /// drop `SnapshotSensorReads`' `at: .snapshot`. Run: red — the snapshot is granted in the lane.
    @Test("In the production plane, § 3's read is granted in the lane and the cache's is not")
    func theProductionPlaneGrantsSectionThreeInTheLane() async throws {
        let observer = RecordingSchedulerObserver()
        let scheduler = SMCReadScheduler(
            provider: OutcomeScriptedProvider { key in .reading(key, 44, kind: .unknown) },
            observer: observer)
        let plane = SMCFanControlPlane(scheduler: scheduler, connection: InertSMCConnection())
        let helper = HelperComposition(
            plane: plane, snapshotProvider: scheduler.snapshotReader, criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(), clock: TestClock(),
            log: HelperRestorerTests.helperLog, leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))

        _ = try await helper.sightings.sighting()
        let afterFlight = observer.events.count
        await helper.thermalEmergency.cycle()
        let afterCycle = observer.events.count
        _ = try await scheduler.snapshotReader.read(keys: ["TC0P"])

        func grants(_ events: ArraySlice<SchedulerEvent>) -> [SMCReadPriority] {
            events.compactMap { event -> SMCReadPriority? in
                if case .turnGranted(let priority, _) = event { return priority }
                return nil
            }
        }
        let events = observer.events
        let flight = grants(events[..<afterFlight])
        let cycle = grants(events[afterFlight..<afterCycle])
        let snapshot = grants(events[afterCycle...])
        #expect(flight == [.supervisor], "the cache's flight was granted at \(flight)")
        #expect(cycle == [.thermalCycle], "§ 3's read was granted at \(cycle)")
        #expect(snapshot == [.snapshot], "the client's snapshot read was granted at \(snapshot)")
    }

    /// § 3's writes in a firing cycle — its bridge job and its revocation's restore — are all in
    /// the lane: a fan level 6 holds is bridged and handed back at § 3's admission.
    ///
    /// **Mutation:** in `HelperComposition.init`, give § 3 `SafetyActorWriter(plane: plane,
    /// level: .thermalEmergency)`. Run: red — the bridge job is admitted at `.supervisor`.
    @Test("A firing cycle's bridge and its revocation's restore are in the lane")
    func aFiringCyclesWritesAreInTheLane() async throws {
        let machine = await Machine(stages: [Self.nominal, .at(96)], fans: 1)
        let id = try await machine.lease([0])
        try await machine.helper.authority.apply(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))], leaseID: id,
            from: machine.holder)
        await machine.firmware.advance()

        let firing = await machine.calls { await machine.helper.thermalEmergency.cycle() }

        #expect(firing.contains { $0.attempt == .bridgeThenRestore(fan: 0, rpm: 5_777) })
        #expect(
            firing.contains { $0.attempt == .restoreToAutomatic(.fan(0)) },
            "the revocation restored nothing")
        #expect(Self.admissions(firing) == [.thermalCycle], "the firing cycle: \(firing)")
    }
}

// MARK: - L5, since #440: § 3 reaches the lane by holding it, and a cause selects nothing

extension ThermalCycleLaneRoutingTests {

    /// K1. Every cause, `FanRestoreCause.allCases` and `.thermalEmergencyRevocation` among them,
    /// through the composed graph's restorer: each restores once, at `.supervisor`. The restorer
    /// is cause-blind, so a cause — stored, replayed or added to the enum — reaches no lane. All
    /// of them, so a cause given a lane of its own fails here the day it is given one.
    ///
    /// **Mutation (K1):** in `HelperFanRestorer`, add a bound over
    /// `writer.admitted(at: .thermalCycle)` and restore through it when the cause is
    /// `.thermalEmergencyRevocation`. Run: red, naming it.
    @Test("The restorer is cause-blind: every cause restores at supervisor")
    func theRestorerIsCauseBlind() async throws {
        let machine = await Machine(stages: [Self.nominal], fans: 1)
        #expect(FanRestoreCause.allCases.count == 8, "a cause was added; it is driven below")

        for cause in FanRestoreCause.allCases {
            let calls = await machine.calls {
                _ = await machine.helper.restorer.restoreToAutomatic(fans: [0], because: cause)
            }
            let restores = calls.filter { $0.attempt == .restoreToAutomatic(.fan(0)) }
            #expect(restores.count == 1, "\(cause): \(calls)")
            #expect(Self.admissions(restores) == [.supervisor], "\(cause) restored at \(restores)")
        }
    }

    /// K2. § 3's revocation, driven by a firing cycle, hands back through § 3's handback in the
    /// lane: a lease over two fans, every restore refused, is the whole budget of `.fan(n)`
    /// attempts on each fan — three and three, in fan order — all at `.thermalCycle`, inside the
    /// one `cycle()` call.
    ///
    /// **Mutation (K2a):** drop `.admitted(at: .thermalCycle)` from `ThermalCycleHandback.init`.
    /// Run: red — the attempts are at `.supervisor`.
    /// **Mutation (K2b):** in `LeaseAuthority.revokeEveryLease(handingBackThrough:)`, lend
    /// `restorer` instead of `handback`. Run: red — at `.supervisor`.
    /// **Mutation (K2c):** add a second `await restore(fans, because: cause, through: handback)`
    /// to that verb. Run: red — six attempts on each fan.
    @Test("§ 3's revocation hands back through § 3's handback, in the lane, in one call")
    func sectionThreesRevocationHandsBackThroughItsHandback() async throws {
        let machine = await Machine(stages: [Self.nominal, Self.hotAndRefusing])
        _ = try await machine.lease([0, 1])
        await machine.firmware.advance()

        let firing = await machine.calls { await machine.helper.thermalEmergency.cycle() }

        #expect(await machine.helper.latch.isActive, "the cycle did not fire")
        #expect(await machine.helper.leases.leaseCount == 0, "the lease survived the firing")
        let restores = Self.restores(firing)
        let budget = RestoreLimits.attemptBudget
        let expected: [ScriptedControlPlane.Attempt] =
            Array(repeating: .restoreToAutomatic(.fan(0)), count: budget)
            + Array(repeating: .restoreToAutomatic(.fan(1)), count: budget)
        #expect(restores.map(\.attempt) == expected, "\(restores)")
        #expect(Self.admissions(restores) == [.thermalCycle], "§ 3's revocation: \(restores)")
    }

    /// K6. After a firing whose revocation handed back in the lane, every other teardown restores
    /// at `.supervisor`: the TTL, a connection's death, a release, § 5's revocation, the panic
    /// verb's lease drop, § 4's sleep, § 6's pass and the signal teardown. The lease core keeps no
    /// lane from the call that borrowed one, so nothing § 3 did reaches a later path.
    ///
    /// **Mutation (K6):** in `HelperComposition.init`, build the handback before the lease core
    /// and give it to `LeaseAuthority` as `restorer:`. Run: red at the seven lease-core paths.
    /// § 6's pass restores through the restorer itself, not the lease core, and stays green.
    /// **Mutation (N5c, from #439's review):** store the revocation's cause and restore lapsed
    /// leases under it, bound to a local first. Run: the whole suite green, correctly — the cause
    /// routes nothing. (Passed straight into the call it is a member read in a restore's arguments,
    /// which `TeardownCountTripwireTests` refuses; this test stays green either way.)
    @Test("After a firing, every other path restores at supervisor")
    func afterAFiringEveryOtherPathRestoresAtSupervisor() async throws {
        let machine = await Machine(stages: [Self.nominal, .at(96), Self.nominal], fans: 1)
        let helper = machine.helper
        _ = try await machine.lease([0])
        await machine.firmware.advance()
        let firing = await machine.calls { await helper.thermalEmergency.cycle() }
        #expect(
            Self.admissions(Self.restores(firing)) == [.thermalCycle],
            "the firing's revocation did not hand back in the lane: \(firing)")
        await machine.firmware.advance()
        await helper.thermalEmergency.cycle()
        #expect(await !helper.latch.isActive, "the latch never released")

        for (path, calls) in try await Self.everyOtherPath(on: machine) {
            let restores = Self.restores(calls)
            #expect(!restores.isEmpty, "\(path) restored nothing: \(calls)")
            #expect(Self.admissions(restores) == [.supervisor], "\(path): \(restores)")
        }
    }

    /// Every teardown but § 3's, each driven over a fresh lease on fan 0, with what it made the
    /// firmware do: the TTL, a connection's death, a release, § 5's revocation, the panic verb's
    /// drop, § 4's sleep, § 6's pass over a fan left manual, and the signal teardown, last.
    private static func everyOtherPath(
        on machine: Machine
    ) async throws -> [(String, [ScriptedControlPlane.AdmittedAttempt])] {
        let helper = machine.helper
        let leases = helper.leases
        let ttl = try await machine.calls {
            _ = try await machine.lease([0])
            machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
            await leases.expireLapsedLeases()
        }
        let dying = ConnectionID()
        let invalidation = try await machine.calls {
            _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: dying)
            await leases.connectionDidInvalidate(dying)
        }
        let release = try await machine.calls {
            let id = try await machine.lease([0])
            try await helper.authority.releaseLease(id: id, from: machine.holder)
        }
        let reclamation = try await machine.calls {
            let id = try await machine.lease([0])
            _ = await leases.revokeLease(id: id, forFan: 0, because: .systemReclaimed)
        }
        let panic = try await machine.calls {
            _ = try await machine.lease([0])
            await leases.releaseEveryLease()
        }
        let sleep = try await Self.sleepAndWake(machine)
        await machine.firmware.setMode(.manual, ofFan: 0)
        let reconciliation = await machine.calls { await helper.reconcileFans() }
        let teardown = try await machine.calls {
            _ = try await machine.lease([0])
            await helper.signalTeardown.run(stoppingSupervisorsWith: { await helper.shutDown() })
        }
        return [
            ("the TTL", ttl), ("a connection's death", invalidation), ("a release", release),
            ("§ 5's revocation", reclamation), ("the panic verb's drop", panic),
            ("§ 4's sleep", sleep), ("§ 6's pass", reconciliation),
            ("the signal teardown", teardown),
        ]
    }

    /// § 4's half of `everyOtherPath(on:)`: a lease, its sleep, and the wake that reopens grants.
    private static func sleepAndWake(
        _ machine: Machine
    ) async throws -> [ScriptedControlPlane.AdmittedAttempt] {
        let sleep = try await machine.calls {
            _ = try await machine.lease([0])
            await machine.helper.powerResponder.respond(
                to: SystemPowerNotification(event: .willSleep, generation: 1) {})
        }
        await machine.helper.powerResponder.respond(
            to: SystemPowerNotification(event: .didWake, generation: 2) {})
        return sleep
    }
}
