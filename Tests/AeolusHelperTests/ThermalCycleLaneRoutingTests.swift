import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Only § 3's turns take § 3's lane, in the composed graph (ADR 0012's 2026-10-18 amendment).
///
/// On the lane: § 3's critical read, its owed read-backs and the restores its own revocation
/// causes. At `.supervisor`: the cache's source, § 6, § 7's read-back, the grant's foreign-control
/// and bounds reads, § 5 and level 6. Every call the scripted firmware receives is recorded with
/// the admission of the view it came through (`ScriptedControlPlane.admittedAttempts`), so each
/// mechanism is driven in turn and its calls are read off by phase.
@Suite("Only § 3 takes § 3's lane, in the composed graph", .timeLimit(.minutes(1)))
struct ThermalCycleLaneRoutingTests {

    /// The composed helper over one scripted firmware, bound as bring-up binds it.
    private struct Machine {
        let firmware: ScriptedControlPlane
        let helper: HelperComposition<ScriptedControlPlane>
        let holder = ConnectionID()

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
                clock: TestClock(),
                log: HelperRestorerTests.helperLog,
                leaseLog: LeaseFixture.log,
                safetyLog: HelperRestorerTests.safetyLog,
                teardown: TeardownSeams(sources: RecordingSignalSources()))
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
    /// granted in the lane, and the cache's flight at `.supervisor`.
    ///
    /// **Mutation:** in `HelperComposition.init`, give § 3 `telemetry:` itself. Run: red — § 3's
    /// read is granted at `.supervisor`.
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

        let grants = observer.events.compactMap { event -> SMCReadPriority? in
            if case .turnGranted(let priority, _) = event { return priority }
            return nil
        }
        let flight = observer.events.prefix(afterFlight).compactMap { event -> SMCReadPriority? in
            if case .turnGranted(let priority, _) = event { return priority }
            return nil
        }
        #expect(flight == [.supervisor], "the cache's flight was granted at \(flight)")
        #expect(
            Array(grants.dropFirst(flight.count)) == [.thermalCycle],
            "§ 3's read was granted at \(grants.dropFirst(flight.count))")
    }

    // MARK: - L5

    /// § 3's revocation, with every handback refused: each of the three attempts on each fan is
    /// a `.fan(n)` restore in the lane.
    ///
    /// **Mutation:** in `HelperFanRestorer.bound(for:)`, return `bounded` for every cause.
    /// Run: red.
    /// **Mutation:** swap the `.thermalEmergency` and `.systemReclaimed` arms. Run: red here and in
    /// `everyOtherCauseRestoresAtSupervisor`.
    @Test("§ 3's revocation puts every restore attempt in the lane")
    func sectionThreesRevocationRestoresInTheLane() async throws {
        let machine = await Machine(stages: [Self.nominal, Self.refusing])
        _ = try await machine.lease([0, 1])
        await machine.firmware.advance()

        let revocation = await machine.calls {
            await machine.helper.leases.revokeEveryLease(because: .thermalEmergency)
        }
        let attempts = revocation.filter {
            if case .restoreToAutomatic = $0.attempt { return true }
            return false
        }
        let budget = RestoreLimits.attemptBudget
        let expected: [ScriptedControlPlane.Attempt] =
            Array(repeating: .restoreToAutomatic(.fan(0)), count: budget)
            + Array(repeating: .restoreToAutomatic(.fan(1)), count: budget)
        #expect(
            attempts.map(\.attempt) == expected,
            "\(attempts)")
        #expect(Self.admissions(attempts) == [.thermalCycle], "§ 3's revocation: \(attempts)")
    }

    /// Every other cause, through its own path, restores at `.supervisor`: a release, the panic
    /// verb's lease drop, and § 5's revocation for a reclaimed fan.
    ///
    /// **Mutation:** in `HelperFanRestorer.bound(for:)`, return `thermalCycleBounded` for every
    /// cause. Run: red at each of the three.
    @Test("Every other cause restores at supervisor")
    func everyOtherCauseRestoresAtSupervisor() async throws {
        let machine = await Machine(stages: [Self.nominal], fans: 1)
        let leases = machine.helper.leases

        let released = try await machine.calls {
            let id = try await machine.lease([0])
            try await machine.helper.authority.releaseLease(id: id, from: machine.holder)
        }
        let dropped = try await machine.calls {
            _ = try await machine.lease([0])
            await leases.releaseEveryLease()
        }
        let reclaimed = try await machine.calls {
            _ = try await machine.lease([0])
            await leases.revokeLeases(coveringFan: 0, because: .systemReclaimed)
        }
        for (cause, calls) in [
            ("leaseReleased", released), ("allLeasesDropped", dropped),
            ("systemReclaimed", reclaimed),
        ] {
            let restores = calls.filter { $0.attempt == .restoreToAutomatic(.fan(0)) }
            #expect(restores.count == 1, "\(cause): \(calls)")
            #expect(Self.admissions(restores) == [.supervisor], "\(cause): \(restores)")
        }
    }
}
