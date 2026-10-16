import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// **No restore waits for the examination gate** (ADR 0014's A6 amendment): with a pass held for
/// good and the clock frozen, every path that hands a fan back still finishes.
///
/// Composed, because the hazard is wiring: a restore path handed the composition's one gate. Each
/// scenario builds the graph `HelperComposition` builds over two scripted fans and a `ManualClock`
/// nobody advances, so a wait on the gate ends only by a grant, and binds it as bring-up does. Fan
/// 1's gate is then held as a step and never left, which is what a step that never releases looks
/// like, and § 5 holds fan 0's for the scenarios it drives. A path that entered the gate for a fan
/// it hands back would wait on that holder for good; each is bounded by `finishedBeforeCeiling`,
/// so it fails red rather than hanging the run.
///
/// § 3's fire, § 4's handback, § 7's panic verb, a lease's release and its expiry, § 5's
/// `restoreAndForget` and `finaliseRelease`, the engagement driver's undo and § 6's reconciliation,
/// one scenario each. The census in `ExaminationGateRouteTests` keeps the gate's name out of every
/// one of their files; this is what would happen if it got in.
///
/// **Mutation:** have `HelperFanRestorer` enter the gate — a `gate: FanExaminationGate?`
/// parameter, the composition's gate passed to it, and `restoreToAutomatic(fans:because:)`
/// entering each fan's gate as an examination before it writes and leaving after. Run: red on
/// § 3's fire, § 4's handback, § 7, the release, the expiry, the terminal action and
/// reconciliation — each never finishes — and green on `restoreAndForget` and the undo, which do
/// not reach the lease core's restorer.
@Suite("No restore waits for the examination gate, composed", .timeLimit(.minutes(1)))
struct ExaminationGateRestoreTests {

    /// One way a fan goes back to automatic control.
    enum Restore: String, CaseIterable, Sendable, CustomStringConvertible {
        case thermalEmergencyFire
        case sleepHandback
        case panicVerb
        case leaseRelease
        case leaseExpiry
        case leaseLapsedHandback
        case terminalAction
        case engagementUndo
        case reconciliation

        var description: String { rawValue }
    }

    /// A composed helper over fans 0 and 1, bound, with a lease over both and fan 1's gate held.
    struct Composed {
        let helper: HelperComposition<ScriptedControlPlane>
        let clock: ManualClock
        let connection: ConnectionID
        let lease: UUID
        let held: FanExaminationGate.Pass
        let log: RecordedLog
    }

    static func composed(
        unlock: ScriptedControlPlane.UnlockBehaviour = .naive
    ) async throws -> Composed {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures), .at(96)],
            unlock: unlock)
        let clock = ManualClock()
        let log = RecordedLog()
        let helper = HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 2),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }),
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        await helper.bindSafetyRegistries()
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: connection)
        let held = try #require(
            await helper.examinationGate.enterForStep(fanAt: 1), "fan 1's gate was not free")
        return Composed(
            helper: helper, clock: clock, connection: connection, lease: lease.id, held: held,
            log: log)
    }

    /// Restores of `fan` the firmware was asked for.
    static func restores(
        of fan: Int, on helper: HelperComposition<ScriptedControlPlane>
    ) async -> Int {
        await helper.plane.attempts.filter {
            $0 == .restoreToAutomatic(.fan(fan)) || $0 == .restoreToAutomatic(.everyFan)
        }.count
    }

    @Test(
        "Every hand-back finishes with a gate held for good and the clock frozen",
        arguments: Restore.allCases)
    func everyHandBackFinishes(restore: Restore) async throws {
        let machine = try await Self.composed(
            unlock: restore == .engagementUndo ? .readsBack(rawMode: 0) : .naive)
        let helper = machine.helper

        try await Self.prepare(restore, on: machine)
        let work = observing { try await Self.run(restore, on: machine) }
        try await finishedBeforeCeiling("\(restore), with fan 1's gate held", work)

        try await Self.expectHandedBack(restore, on: machine)
        #expect(helper.examinationGate.isHeld(fanAt: 1), "the held pass was let go")
        #expect(helper.examinationGate.isHeld(fanAt: 0) == false, "§ 5 kept fan 0's gate")
        helper.examinationGate.leave(machine.held)
        #expect(helper.examinationGate.isIdle)
    }

    /// What has to be true before `restore` can run: what it hands back must be off automatic
    /// control, or registered where it is looked for.
    private static func prepare(_ restore: Restore, on machine: Composed) async throws {
        let helper = machine.helper
        switch restore {
        case .thermalEmergencyFire:
            for fan in [0, 1] {
                await helper.thermalEmergency.manualControlEngaged(
                    try commandableFan(fan, declaring: .held(at: 2_400)))
            }
            await helper.plane.advance()
        case .leaseLapsedHandback, .terminalAction:
            try await HelperRestorerTests.engage(fan: 0, in: helper, under: machine.lease)
            if restore == .leaseLapsedHandback {
                machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
            }
        case .engagementUndo:
            try await HelperRestorerTests.engage(fan: 0, in: helper, under: machine.lease)
            await helper.reclamationWatchdog.commandedTarget(
                CommandedTarget(fanIndex: 0, rpm: 2_400), under: machine.lease)
        case .leaseExpiry:
            machine.clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
        case .reconciliation:
            await helper.plane.setMode(.manual, ofFan: 1)
        case .sleepHandback, .panicVerb, .leaseRelease:
            break
        }
    }

    private static func run(_ restore: Restore, on machine: Composed) async throws {
        let helper = machine.helper
        switch restore {
        case .thermalEmergencyFire:
            await helper.thermalEmergency.cycle()
        case .sleepHandback:
            await helper.powerResponder.respond(
                to: SystemPowerNotification(event: .willSleep, generation: 1) {})
        case .panicVerb:
            try await helper.authority.restoreAllToAutomatic(from: machine.connection)
        case .leaseRelease:
            try await helper.leases.releaseLease(id: machine.lease, from: machine.connection)
        case .leaseExpiry:
            await helper.leases.expireLapsedLeases()
        case .leaseLapsedHandback, .engagementUndo:
            await helper.reclamationWatchdog.cycle()
        case .terminalAction:
            for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
                await helper.reclamationWatchdog.cycle()
            }
        case .reconciliation:
            await helper.reconcileFans()
        }
    }

    /// That `restore` did what it is for, so a scenario that never reached its restore cannot pass.
    private static func expectHandedBack(_ restore: Restore, on machine: Composed) async throws {
        let helper = machine.helper
        let log = machine.log
        switch restore {
        case .thermalEmergencyFire:
            #expect(await helper.latch.isActive, "§ 3 never fired")
            #expect(await Self.restores(of: 1, on: helper) >= 1)
            #expect(await helper.leases.leaseCount == 0)
        case .sleepHandback, .panicVerb, .leaseRelease, .leaseExpiry:
            #expect(await Self.restores(of: 1, on: helper) >= 1, "fan 1 was not handed back")
            #expect(await helper.leases.leaseCount == 0)
        case .leaseLapsedHandback:
            #expect(log.lines(containing: leaseLapsedNotice).count == 1)
            #expect(await Self.restores(of: 0, on: helper) == 1)
            #expect(await helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
        case .terminalAction:
            #expect(log.lines(containing: "no speed to re-assert").count == 1)
            #expect(await Self.restores(of: 1, on: helper) >= 1, "the revocation restored nothing")
            #expect(await helper.leases.leaseCount == 0)
        case .engagementUndo:
            #expect(
                log.lines(containing: "It was registered with § 3 and handed back").count == 1,
                "the driver's undo never ran")
            #expect(await Self.restores(of: 0, on: helper) == 1)
        case .reconciliation:
            #expect(await Self.restores(of: 1, on: helper) == 1, "reconciliation restored nothing")
        }
    }
}
