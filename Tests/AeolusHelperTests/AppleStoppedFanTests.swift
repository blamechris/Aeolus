import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A fan Apple's controller has stopped — raw `F<n>Md = 3`, `F<n>Tg` 0 — read through every
/// consumer of the fold ([#633](https://github.com/blamechris/Aeolus/issues/633); ADR 0014's P1′
/// amendment).
///
/// P1 recorded `3` whenever Apple had the fans stopped and `0` whenever it spun them, and no
/// other value, in 41,931 samples on `Mac16,5` under macOS 27.2. The fold read only `0` as
/// Apple's, so the shipped helper reported the machine's idle state as another program's hold.
/// Every case here scripts that state on the firmware (`FanCondition.stoppedByApple`) and asks
/// one consumer, through the production decode: the snapshot's own read of `F<n>Md`
/// (`SnapshotFanModeReads`, served the byte by `PlaneBackedProvider`) or the plane's
/// (`readControlState(ofFan:)`, which folds the byte as `SMCFanControlPlane` does).
///
/// **Each one is red under the old fold**, `value == 0 ? .automatic : .manual`. The run that
/// showed it was this file over `eb625c1`'s `Sources/`, before the fold changed; the PR records
/// it.
@Suite(
    "A fan Apple has stopped reads automatic to every consumer of the fold",
    .timeLimit(.minutes(1)))
struct AppleStoppedFanTests {

    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "AppleStopped")

    /// Two fans Apple has stopped, as P1 found this machine at rest.
    private static func stoppedFirmware() -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [0: .stoppedByApple, 1: .stoppedByApple],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
    }

    /// The daemon's graph over `plane`, the snapshot reading `firmware`'s bytes.
    private static func composed<Plane: FanControlPlane>(
        plane: Plane, firmware: ScriptedControlPlane, provider: PlaneBackedProvider
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: provider,
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// The firmware still holds Apple's byte: nothing in the scenario moved it, so an assertion
    /// that the fan reads automatic is about the fold, not about a write that put `0` there.
    private static func expectStillStopped(_ firmware: ScriptedControlPlane) async throws {
        for fan in [0, 1] {
            #expect(
                try await firmware.firmwareRawMode(ofFan: fan) == 3,
                "fan \(fan) no longer reads Apple's stopped byte, so this case tested a write")
        }
    }

    // MARK: - The snapshot (#633's acceptance)

    /// The shipped build at rest: a `.notBuilt` plane, both fans stopped by Apple. The snapshot
    /// reports them automatic and states the build's own refusal, never another program's hold.
    ///
    /// This is the misreport #633 was filed on, from the installed helper: `mode = manualFixed`
    /// and `foreignManualControl` for both fans, with no other program running. Step 5's manual
    /// arm is the one rung stated over `.writePathNotBuilt`, so the fold alone decided it.
    @Test("The shipped snapshot reports a fan Apple has stopped as automatic, not foreign")
    func theShippedSnapshotReportsAStoppedFanAutomatic() async throws {
        let firmware = Self.stoppedFirmware()
        let provider = PlaneBackedProvider(over: firmware, fanCount: 2)
        let helper = Self.composed(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt), firmware: firmware,
            provider: provider)
        #expect(helper.plane.writeCapability == .notBuilt, "this case is about the shipped build")
        await helper.bindSafetyRegistries()

        let snapshot = try await helper.authority.snapshot()

        #expect(await provider.answeredModeReads == 2, "the snapshot did not read both modes")
        for fan in [0, 1] {
            let state = try #require(snapshot.fans.first { $0.index == fan })
            #expect(
                state.mode == .automatic,
                "fan \(fan) reads raw 3, Apple's stopped state, and is reported \(state.mode)")
            #expect(
                state.manualControlAvailability == .unavailable(.writePathNotBuilt),
                """
                fan \(fan) is stopped by Apple and the snapshot says \
                \(state.manualControlAvailability): a claim that another program holds it, \
                which CLAUDE.md rule 6 forbids.
                """)
        }
        try await Self.expectStillStopped(firmware)
    }

    /// On a seam that can write, the same fans read available and the grant takes one: a grant
    /// over raw `3` is not refused `.foreignManualControl`.
    @Test("On a seam that can write, a fan Apple has stopped reads available and is granted")
    func aSeamThatCanWriteGrantsAStoppedFan() async throws {
        let firmware = Self.stoppedFirmware()
        let helper = Self.composed(
            plane: firmware, firmware: firmware,
            provider: PlaneBackedProvider(over: firmware, fanCount: 2))
        await helper.bindSafetyRegistries()

        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(fan.mode == .automatic)
        #expect(fan.manualControlAvailability == .available)

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        #expect(await helper.leases.leaseCount == 1)
        try await Self.expectStillStopped(firmware)
    }

    // MARK: - Reconciliation, § 5, § 3 and the lease core

    /// Startup reconciliation over a machine at rest hands nothing back. Under the old fold it
    /// wrote `0` over Apple's `3` on every fan at every start, and treated the fans as its own
    /// handbacks to confirm.
    @Test("Reconciliation over fans Apple has stopped writes nothing")
    func reconciliationOverStoppedFansWritesNothing() async throws {
        let firmware = Self.stoppedFirmware()
        let helper = Self.composed(
            plane: firmware, firmware: firmware,
            provider: PlaneBackedProvider(over: firmware, fanCount: 2))

        await helper.bringUp()
        await helper.shutDown()

        let writes = await firmware.keyWrites
        #expect(writes.isEmpty, "reconciliation wrote to fans Apple had stopped: \(writes)")
        #expect(await helper.reconciliation.unreconciledFans.isEmpty)
        try await Self.expectStillStopped(firmware)
    }

    /// § 5's primary signal reads a fan Apple has stopped as taken back, `.modeReclaimed`: the
    /// mode is the unambiguous half. Under the old fold it read the fan as still manual, with a
    /// target of 0 against the one commanded, `.targetDiverged`.
    @Test("§ 5 reads a held fan that Apple then stops as reclaimed")
    func sectionFiveReadsAStoppedFanAsReclaimed() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        await firmware.setByApple(.stoppedByApple, ofFan: 0)

        let state = try await firmware.readControlState(ofFan: 0)
        let divergence = ReclamationWatchdog<ScriptedControlPlane>.primaryDivergence(
            of: state, against: CommandedTarget(fanIndex: 0, rpm: 2_400))

        #expect(divergence == .modeReclaimed)
    }

    /// § 3 confirms a handback when the fan then reads Apple's stopped byte: Apple stops a fan
    /// about a second after its target reaches 0, so a handback at rest is confirmed by a `3`.
    @Test("§ 3 confirms a handback that then reads Apple's stopped byte")
    func sectionThreeConfirmsAHandbackThatThenReadsStopped() async throws {
        let machine = ThermalMachine(stages: [.at(44)], fans: [0: .held(at: 2_400)])
        try await machine.engageManualControl(fan: 0)
        await machine.emergency.handbackAccepted(fanAt: 0)
        await machine.plane.setByApple(.stoppedByApple, ofFan: 0)

        await machine.emergency.cycle()

        #expect(await machine.handbackReadBack.requests == [[0]], "the read was never issued")
        #expect(await machine.emergency.fansOwedHandbackReadBack.isEmpty)
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
        #expect(
            machine.safetyLog.lines(containing: "reads automatic after its handback").count == 1)
        #expect(machine.safetyLog.lines(containing: "still reads manual").isEmpty)
    }

    /// The lease core lifts a durable refusal when the fan it handed back then reads Apple's
    /// stopped byte on § 7's pass, and the grant that follows reads the same byte and grants.
    @Test("The lease core lifts a handback refusal when the fan then reads Apple's stopped byte")
    func theLeaseCoreLiftsAHandbackThatThenReadsStopped() async throws {
        let modes = ScriptedControlPlane(
            fans: [0: ScriptedControlPlane.FanCondition()],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let (leases, firmware) = try await AbandonedHandbackRecoveryTests.abandoned(
            leasing: [0], refusing: [0],
            foreignControl: LeaseFixture.reconciliation(
                over: modes, enumeration: ScriptedFanEnumeration(indices: [0])))

        await modes.setByApple(.stoppedByApple, ofFan: 0)
        await firmware.takesTheWrite(for: [0])
        await AbandonedHandbackRecoveryTests.panicPass(leases)

        #expect(
            await firmware.attemptCount(forFan: 0) == RestoreLimits.attemptBudget + 1,
            "the panic pass did not reach fan 0, so this case says nothing about the lift")
        #expect(
            await leases.fansWithAbandonedHandbacks.isEmpty,
            "fan 0 reads Apple's stopped byte and the lease core still refuses it")
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    // MARK: - The engagement's pre-state

    /// D3 step 1 admits a fan Apple has stopped: the machine's rest state is the state run 1's 1a
    /// engages from. Under the old pre-state, `rawMode == 0`, it was refused `.notAutomatic` with
    /// nothing written.
    @Test("An engagement's first step admits a fan Apple has stopped")
    func anEngagementAdmitsAStoppedFan() async throws {
        let firmware = Self.stoppedFirmware()

        let step = try await firmware.ticketedStep(
            of: try commandableFan(0, declaring: .stoppedByApple))

        #expect(step == .engaged)
        #expect(await firmware.keyWrites.first == .mode(fan: 0, value: 1))
    }
}
