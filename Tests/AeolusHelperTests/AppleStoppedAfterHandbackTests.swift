import FanKit
import SMCCore
import Testing

@testable import AeolusHelper

/// The consumers of the fold that read a fan **after** Aeolus has handed it back, or taken it, and
/// Apple has then stopped it: raw `F<n>Md = 3` with `F<n>Tg` 0 ([#633](https://github.com/blamechris/Aeolus/issues/633);
/// ADR 0014's P1′ amendment).
///
/// P1 recorded Apple writing mode `3` about a second after a fan's target reaches 0, so a fan
/// handed back at rest is next read at `3`, not at the `0` the restore wrote. Each case here reads
/// one such consumer: reconciliation's own read-back, § 3's read-back of its own restore, and the
/// snapshot's held target, with § 5's re-assert after it. `AppleStoppedFanTests` holds the
/// consumers that read a fan Apple had stopped before anything was written.
///
/// **Each is red under the old fold**, `value == 0 ? .automatic : .manual`; the PR records the run.
@Suite(
    "A fan Apple stops after a handback reads automatic to the fold's later readers",
    .timeLimit(.minutes(1)))
struct AppleStoppedAfterHandbackTests {

    /// Startup reconciliation's read-back of a fan it handed back by name
    /// (`StartupReconciliation.readBack`): the restore writes `0`, Apple then stops the fan, and
    /// the read-back finds `3`. The fan is confirmed, nothing is left unreconciled, a grant is not
    /// refused, and the fan Apple had already stopped is never written.
    @Test("Reconciliation confirms a handback that Apple then stops")
    func reconciliationConfirmsAHandbackAppleThenStops() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .held(at: 4_400), 1: .stoppedByApple],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: AppleStopsAfterRestorePlane(wrapping: firmware),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]), clock: TestClock())

        await reconciliation.reconcile()

        #expect(
            await firmware.attempts.contains(.restoreToAutomatic(.fan(0))),
            "fan 0 was never handed back, so its read-back was never taken")
        #expect(try await firmware.firmwareRawMode(ofFan: 0) == 3, "Apple never stopped fan 0")
        #expect(
            await firmware.keyWrites.contains(.mode(fan: 1, value: 0)) == false,
            "reconciliation wrote over the fan Apple had already stopped")
        #expect(
            await reconciliation.unreconciledFans.isEmpty,
            "a handback Apple then stopped was read as still manual")
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0, 1], heldByAeolus: [], awaitingConfirmation: []) == nil)
    }

    /// § 3's read-back of its own restore after an emergency (`ThermalEmergency`'s
    /// `restoredUnconfirmed`): the firmware discarded the restore, then Apple stopped the fan. The
    /// next clear cycle reads `3`, confirms the restore, and the next emergency does not bridge a
    /// fan that reads automatic.
    @Test("§ 3 confirms its own restore when the fan then reads Apple's stopped byte")
    func sectionThreeConfirmsItsOwnRestoreOverAStoppedFan() async throws {
        let machine = ThermalMachine(
            stages: [
                .at(96, writes: .reverted), .at(44, writes: .reverted), .at(96, writes: .reverted),
            ],
            fans: [0: .held(at: 4_400)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.cycle()
        #expect(await machine.emergency.isHolding, "the first emergency never fired")
        await machine.plane.advance()
        await machine.emergency.cycle()
        #expect(await !machine.emergency.isHolding, "the first emergency never released")
        #expect(
            await machine.emergency.fansRestoredUnconfirmed == [0],
            "the discarded restore left nothing owed, so this case reads nothing")
        await machine.plane.setByApple(.stoppedByApple, ofFan: 0)

        await machine.emergency.cycle()

        #expect(await machine.handbackReadBack.requests == [[0]], "the read was never issued")
        #expect(await machine.emergency.fansRestoredUnconfirmed.isEmpty)
        #expect(
            machine.safetyLog.levels(containing: "reads automatic after the thermal emergency")
                == [.notice])
        #expect(
            machine.safetyLog.lines(containing: "is still manual after the thermal emergency")
                .isEmpty)

        await machine.plane.advance()
        await machine.emergency.cycle()
        let bridges = await machine.attempts.filter {
            if case .bridgeThenRestore(fan: 0, _) = $0 { return true }
            return false
        }
        #expect(bridges.count == 1, "the second emergency bridged a fan that reads automatic")
    }

    /// The snapshot's held target over a fan Apple stopped under a lease: no target is stated,
    /// because the fan reads automatic. § 5 then judges it taken back, re-engages it — the
    /// pre-state admits `3`, and the engaged step raises the target from 0 to the floor — and
    /// re-commands the recorded target, and the next cycle states it again.
    @Test("A held fan Apple stops states no target, and § 5's re-assert raises it to the floor")
    func aHeldFanAppleStopsStatesNoTargetUntilReasserted() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        try await machine.apply(rpm: 5_000, under: lease)
        let before = try #require(try await Self.fanZero(machine))
        #expect(before.targetRPM == 5_000, "the apply stated no target, so nothing here is tested")

        await machine.firmware.setByApple(.stoppedByApple, ofFan: 0)
        let taken = try #require(try await Self.fanZero(machine))
        #expect(taken.mode == .automatic)
        #expect(taken.targetRPM == nil, "a target is stated beside a fan Apple has stopped")
        #expect(!taken.isReclaimedBySystem)

        let writesBefore = await machine.firmware.keyWrites.count
        await machine.helper.reclamationWatchdog.cycle()
        let judged = try #require(try await Self.fanZero(machine))
        #expect(judged.isReclaimedBySystem)
        #expect(judged.mode == .manualFixed)
        #expect(judged.targetRPM == nil, "a target is stated beside § 5's mark")
        let reassert: [ScriptedControlPlane.KeyWrite] = [
            .mode(fan: 0, value: 1), .target(fan: 0, rpm: 1_350), .target(fan: 0, rpm: 5_000),
        ]
        #expect(
            Array(await machine.firmware.keyWrites.dropFirst(writesBefore)) == reassert,
            "§ 5's re-assert did not engage from 3, raise to the floor, then re-command")

        await machine.helper.reclamationWatchdog.cycle()
        let converged = try #require(try await Self.fanZero(machine))
        #expect(!converged.isReclaimedBySystem)
        #expect(converged.targetRPM == 5_000)
    }

    /// `ReadOnlyFanReport.heldTarget(...)` over the decoded bytes themselves: Apple's `3` states no
    /// target, and a held `1` does.
    @Test("The held-target rule states no target over Apple's 3, and states one over 1")
    func theHeldTargetRuleReadsTheDecodedByte() {
        let fan = FanState(
            index: 0, actualRPM: .measured(3_000), minimumRPM: .measured(1_350),
            maximumRPM: .measured(5_777), targetRPM: nil, mode: .manualFixed,
            isReclaimedBySystem: false, manualControlAvailability: .available)
        func held(_ raw: Double) -> Double? {
            ReadOnlyFanReport.heldTarget(
                of: fan, leasedFans: [0], recorded: [0: 4_400],
                observedMode: FirmwareFanMode(declaredByFirmware: raw),
                thermalEmergencyActive: false)
        }

        #expect(held(3) == nil)
        #expect(held(1) == 4_400)
    }

    private static func fanZero(_ machine: LevelSixMachine) async throws -> FanState? {
        try await machine.helper.authority.snapshot().fans.first { $0.index == 0 }
    }
}

/// Scripted firmware that behaves as Apple's controller does after a per-fan restore at rest: once
/// `.fan(n)` lands, Apple stops fan *n*, so its next read is raw `3` with target 0. Every other
/// verb forwards unchanged.
actor AppleStopsAfterRestorePlane: AdmissionBlindPlane {
    private let wrapped: ScriptedControlPlane
    nonisolated let writeCapability: FanWriteCapability = .built

    init(wrapping wrapped: ScriptedControlPlane) { self.wrapped = wrapped }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        try await wrapped.restoreToAutomatic(scope)
        if case .fan(let index) = scope {
            await wrapped.setByApple(.stoppedByApple, ofFan: index)
        }
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await wrapped.readControlState(ofFan: index)
    }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func reconnect() async throws { try await wrapped.reconnect() }

    nonisolated func beginEngagement(fanAt index: Int) { wrapped.beginEngagement(fanAt: index) }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        try await wrapped.engageManualControl(of: fan)
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await wrapped.prepareWritePath(enumerating: fans)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}
