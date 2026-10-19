import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Every write that is not § 3's is admitted at `.supervisor`, through the path that makes it
/// (#440's second review round).
///
/// The source scans say where the lane may be *named*; a lane view built in a file that may name
/// it and handed to another mechanism keeps every count (`ThermalCycleHandbackShapeTripwireTests`
/// records why scans cannot close that for good). So the consequence is held here instead, by
/// behaviour: each mechanism that writes for itself is driven through the composed graph, and the
/// firmware records the admission every call it receives came through.
///
/// **When § 3 cycles.** In every drive but two, no supervisor runs and the clock is frozen, so § 3
/// cycles only when a test calls its `cycle()` — before the path it is about — and a single
/// `.thermalCycle` call in the path is a mechanism other than § 3 in § 3's lane. The two drives
/// that call `bringUp()` — the signal teardown and the power observer — start the supervisors on
/// the real clock, so § 3 does cycle during them, reading in its lane once a second. They
/// therefore look at restores alone: § 3's cycle restores nothing at nominal temperatures, so a
/// `.thermalCycle` *restore* in either is still a mechanism other than § 3.
///
/// The paths are the ones `ThermalCycleLaneRoutingTests`' K6 does not already drive: level 6's
/// engagement and command, § 5's re-assert and its give-up, § 5's hand-back of a fan whose lease
/// lapsed, § 7's panic verb, § 6's machine-wide restore — each at rest and after a firing — and
/// the two closures `bringUp()` installs, fired through the sources they were given: the signal
/// teardown, and the power observer's sleep and wake. Those are the paths this suite holds; a path
/// it does not drive is held by the lexical scans and incidental tests alone.
@Suite("Every writer but § 3's is at supervisor, through its own path", .timeLimit(.minutes(1)))
struct SupervisorWriterAdmissionTests {

    /// The composed helper over one scripted firmware, bound as bring-up binds it.
    private struct Machine {
        let firmware: ScriptedControlPlane
        let helper: HelperComposition<ScriptedControlPlane>
        let holder = ConnectionID()
        let signals: RecordingSignalSources
        let journal: TeardownJournal

        init(
            stages: [ScriptedControlPlane.Stage], fans: Int = 2,
            reconciliationBudget: Duration = ReconciliationLimits.budget,
            clock: some MonotonicClock = TestClock(),
            powerObserver: (any SystemPowerObserving)? = nil
        ) async {
            let conditions = Dictionary(
                uniqueKeysWithValues: (0..<fans).map {
                    ($0, ScriptedControlPlane.FanCondition.automatic(at: 1_800))
                })
            let signals = RecordingSignalSources()
            let journal = TeardownJournal()
            firmware = ScriptedControlPlane(fans: conditions, stages: stages)
            helper = HelperComposition(
                plane: firmware,
                snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: fans),
                criticalSensors: .mac16x5,
                roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
                clock: clock,
                reconciliationBudget: reconciliationBudget,
                powerObserver: powerObserver,
                log: HelperRestorerTests.helperLog,
                leaseLog: LeaseFixture.log,
                safetyLog: HelperRestorerTests.safetyLog,
                teardown: TeardownSeams(sources: signals, terminate: journal.terminate))
            self.signals = signals
            self.journal = journal
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

    /// Nominal, hot, nominal, then refusing: stage 2 is where every path starts, whether or not a
    /// firing came first, and stage 3 is § 5's give-up.
    private static let stages = [nominal, .at(96), nominal, refusing]

    /// Brings `machine` to stage 2. After a firing, a lease over fan 0 has been revoked through
    /// § 3's handback in the lane and the latch has released; at rest, nothing has run.
    private static func prepare(_ machine: Machine, afterAFiring: Bool) async throws {
        guard afterAFiring else {
            await machine.firmware.advance()
            await machine.firmware.advance()
            return
        }
        _ = try await machine.lease([0])
        await machine.firmware.advance()
        let firing = await machine.calls { await machine.helper.thermalEmergency.cycle() }
        #expect(
            firing.contains {
                $0.attempt == .restoreToAutomatic(.fan(0)) && $0.admission == .thermalCycle
            },
            "the firing's revocation did not hand back in the lane: \(firing)")
        await machine.firmware.advance()
        await machine.helper.thermalEmergency.cycle()
        #expect(await !machine.helper.latch.isActive, "the latch never released")
    }

    /// `calls` happened, include `expected`, and every one of them is at `.supervisor`.
    private static func expectAtSupervisor(
        _ calls: [ScriptedControlPlane.AdmittedAttempt], _ path: String,
        including expected: (ScriptedControlPlane.Attempt) -> Bool
    ) {
        #expect(calls.contains { expected($0.attempt) }, "\(path) did not happen: \(calls)")
        let lane = calls.filter { $0.admission != .supervisor }
        #expect(lane.isEmpty, "\(path) took § 3's lane: \(lane)")
    }

    // MARK: - § 5, level 6 and § 7

    /// Level 6's engagement and command, § 5's re-assert after the system takes a fan back, § 5's
    /// give-up once the firmware refuses, and § 7's panic verb: every call each makes is at
    /// `.supervisor`, at rest and after a firing.
    ///
    /// **Mutation (L2b):** in `ThermalCycleHandback.swift`, add `extension SafetyActorWriter {
    /// var inTheLane: Self { admitted(at: .thermalCycle) } }`, build the handback's bound over
    /// `writer.inTheLane`, and command § 5's re-assert through `writer.inTheLane`. Run: red here,
    /// at the re-assert.
    /// **Mutation (C1):** a nested `LaneWriter` in `ThermalCycleHandback` that admits a writer in
    /// the lane, `typealias LaneHandback = ThermalCycleHandback` in the composition, and § 5's
    /// re-assert commanded through `LaneHandback<Plane>.LaneWriter(writer).value`. Run: red here.
    @Test(
        "§ 5's re-assert and give-up, level 6 and § 7 are at supervisor",
        arguments: [false, true])
    func supervisorWritersAreAtSupervisor(afterAFiring: Bool) async throws {
        let machine = await Machine(stages: Self.stages)
        let helper = machine.helper
        try await Self.prepare(machine, afterAFiring: afterAFiring)

        var leaseID = UUID()
        let apply = try await machine.calls {
            leaseID = try await machine.lease([0, 1])
            try await helper.authority.apply(
                [
                    FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400)),
                    FanSetting(fanIndex: 1, control: .fixed(rpm: 2_400)),
                ], leaseID: leaseID, from: machine.holder)
        }
        Self.expectAtSupervisor(apply, "level 6's apply") {
            $0 == .commandTarget(fan: 0, rpm: 2_400)
        }

        await machine.firmware.setMode(.automatic, ofFan: 0)
        let reassert = await machine.calls { await helper.reclamationWatchdog.cycle() }
        Self.expectAtSupervisor(reassert, "§ 5's re-assert") {
            $0 == .commandTarget(fan: 0, rpm: 2_400)
        }

        await machine.firmware.advance()
        await machine.firmware.setMode(.automatic, ofFan: 1)
        let giveUp = await machine.calls {
            for _ in 0..<8 {
                guard await helper.leases.leaseCount > 0 else { break }
                await helper.reclamationWatchdog.cycle()
            }
        }
        #expect(await helper.leases.leaseCount == 0, "§ 5 never gave the reclaimed fan up")
        Self.expectAtSupervisor(giveUp, "§ 5's give-up") { $0 == .restoreToAutomatic(.fan(1)) }

        let panic = try await machine.calls {
            try await helper.authority.restoreAllToAutomatic(from: machine.holder)
        }
        Self.expectAtSupervisor(panic, "§ 7's panic verb") { $0 == .restoreToAutomatic(.everyFan) }
    }

    // MARK: - § 5's lapse hand-back

    /// § 5's hand-back of fans whose lease lapsed, `ReclamationWatchdog.restoreAndForget`: every
    /// call it makes is at `.supervisor`, at rest and after a firing.
    ///
    /// Two fans are held under one lease through level 6's `apply`, so § 5 is watching both; the
    /// lease core's clock then moves past the lease's deadline with nothing swept and nobody told,
    /// and one `cycle()` finds each fan's lease no longer live and hands it back. That is the only
    /// restore in the window, so a restore that took another admission came from this path.
    ///
    /// **Mutation (U1):** in `ReclamationWatchdog.restoreAndForget(fanAt:heldUnder:)`, replace
    /// `await handBack(fanAt: index)` with `_ = try? await writer.admitted(at:
    /// .thermalCycle).restoreToAutomatic(.fan(index))`. Run: red here, at the lane assertion.
    @Test("§ 5's hand-back of a fan whose lease lapsed is at supervisor", arguments: [false, true])
    func theLapseHandBackIsAtSupervisor(afterAFiring: Bool) async throws {
        let clock = TestClock()
        let machine = await Machine(stages: Self.stages, clock: clock)
        let helper = machine.helper
        try await Self.prepare(machine, afterAFiring: afterAFiring)

        let leaseID = try await machine.lease([0, 1])
        try await helper.authority.apply(
            [
                FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400)),
                FanSetting(fanIndex: 1, control: .fixed(rpm: 2_400)),
            ], leaseID: leaseID, from: machine.holder)
        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl == [0, 1],
            "level 6 never registered both fans with § 5")

        clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
        let lapse = await machine.calls { await helper.reclamationWatchdog.cycle() }

        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            "§ 5 never handed back a fan whose lease lapsed")
        #expect(
            lapse.contains { $0.attempt == .restoreToAutomatic(.fan(1)) },
            "§ 5's lapse hand-back never reached the second fan: \(lapse)")
        Self.expectAtSupervisor(lapse, "§ 5's lapse hand-back") {
            $0 == .restoreToAutomatic(.fan(0))
        }
    }

    // MARK: - § 6

    /// § 6's machine-wide restore, the `panic:` writer's one write, when its budget runs out before
    /// any fan is read: at `.supervisor`, at rest and after a firing.
    ///
    /// **Mutation:** in `HelperComposition.init`, give reconciliation `panic:` the writer over
    /// `plane.admitted(at: .thermalCycle)`. Run: red here.
    @Test("§ 6's machine-wide restore is at supervisor", arguments: [false, true])
    func reconciliationsMachineWideRestoreIsAtSupervisor(afterAFiring: Bool) async throws {
        let machine = await Machine(stages: Self.stages, reconciliationBudget: .zero)
        try await Self.prepare(machine, afterAFiring: afterAFiring)

        let pass = await machine.calls { await machine.helper.reconcileFans() }
        Self.expectAtSupervisor(pass, "§ 6's machine-wide restore") {
            $0 == .restoreToAutomatic(.everyFan)
        }
    }

    // MARK: - The installed teardown

    /// The signal teardown `bringUp()` installs, fired through the signal source the composition
    /// was given: every restore it issues is at `.supervisor`. K6 drives
    /// `run(stoppingSupervisorsWith:)` with a closure of its own; this drives the closure bring-up
    /// actually supplies.
    ///
    /// **Mutation (A1):** keep the handback in a `let` in `HelperComposition.init`, store a
    /// `teardownHandback` closure that restores fan 0 through it, and have `bringUp()`'s
    /// `stoppingSupervisorsWith:` call it after `shutDown()`. Run: red here.
    @Test("The teardown bring-up installs restores at supervisor")
    func theInstalledTeardownRestoresAtSupervisor() async throws {
        let machine = await Machine(stages: [Self.nominal], clock: SystemMonotonicClock())
        await machine.helper.bringUp()
        _ = try await machine.lease([0])

        let teardown = await machine.calls {
            await machine.signals.fire()
            #expect(await machine.journal.waitForExit(), "the teardown never reached its exit")
        }
        let restores = teardown.filter {
            if case .restoreToAutomatic = $0.attempt { return true }
            return false
        }
        #expect(
            restores.contains { $0.attempt == .restoreToAutomatic(.fan(0)) },
            "the teardown did not hand the lease's fan back: \(teardown)")
        #expect(
            restores.allSatisfy { $0.admission == .supervisor },
            "the installed teardown restored in § 3's lane: \(restores)")
    }

    // MARK: - The installed power observer

    /// The sleep and wake restore `bringUp()` installs, fired through the power observer the
    /// composition was given: every restore it issues is at `.supervisor`, at rest and after a
    /// firing. `SystemPowerTests` drives § 4 through `observeSystemPower()` by hand with no loop
    /// running; this drives the closure the daemon's own bring-up installs, with the supervisors
    /// running behind it. A willSleep hands back the lease's fan and then every fan; a didWake
    /// writes nothing, so a restore in either window that is not at `.supervisor` is a mechanism
    /// other than § 3 in § 3's lane.
    ///
    /// **Mutation (U3):** keep the handback in a `let` in `HelperComposition.init`, store a
    /// `sleepHandback` closure that restores fan 0 through it, and have `observeSystemPower()`'s
    /// closure call it after `respond(to:)`. Run: red here, at the lane assertion.
    @Test(
        "The sleep and wake restore bring-up installs is at supervisor", arguments: [false, true])
    func theInstalledPowerObserverRestoresAtSupervisor(afterAFiring: Bool) async throws {
        let observer = ScriptedPowerObserver()
        let machine = await Machine(
            stages: Self.stages, clock: SystemMonotonicClock(), powerObserver: observer)
        try await Self.prepare(machine, afterAFiring: afterAFiring)
        await machine.helper.bringUp()
        #expect(observer.isObserving, "bring-up installed no power observer")
        _ = try await machine.lease([0])

        let sleepAndWake = try await machine.calls {
            try await observer.deliver(.willSleep)
            try await observer.deliver(.didWake)
        }
        await machine.helper.shutDown()

        let restores = sleepAndWake.filter {
            if case .restoreToAutomatic = $0.attempt { return true }
            return false
        }
        #expect(
            restores.contains { $0.attempt == .restoreToAutomatic(.everyFan) },
            "the installed sleep did not hand every fan back: \(sleepAndWake)")
        Self.expectAtSupervisor(restores, "the installed sleep's hand-back") {
            $0 == .restoreToAutomatic(.fan(0))
        }
    }
}
