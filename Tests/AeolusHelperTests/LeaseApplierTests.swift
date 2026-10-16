import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Level 6's `apply`, `LeaseApplier`, against A6's contract (ADR 0014's A6 and A6 PR-2
/// amendments): item 0's checks, item 1's ownership, item 3's report, item 4's last questions,
/// the driver's level, and a shipped build.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`, with the real lease
/// core, § 3's latch, the fans' gate and § 5 (`LevelSix`). Item 5's table is
/// `LeaseApplierAnswerTests`, the undo `LeaseApplierUndoTests`, the ramp `LeaseApplierRampTests`,
/// and #383 and #389 with the real level 6 `LeaseApplierExaminationTests`. Each test names the
/// mutation it kills.
@Suite("Level 6's apply", .timeLimit(.minutes(1)))
struct LeaseApplierTests {

    /// Nothing was read or written, the gate was never entered, and § 5 holds nothing.
    static func expectNothingTouched<Writes>(
        _ machine: ReclamationMachine<Writes>, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(
            await machine.attempts.isEmpty, "the firmware was asked something",
            sourceLocation: sourceLocation)
        #expect(machine.gate.entrants == 0, "the gate was entered", sourceLocation: sourceLocation)
        #expect(
            await machine.watchdog.fansUnderManualControl.isEmpty, "§ 5 was told of a fan",
            sourceLocation: sourceLocation)
    }

    // MARK: - Item 0

    /// One of item 0's refusals: the settings, and the detail it answers with.
    struct Refusal: Sendable, CustomStringConvertible {
        let description: String
        let settings: [FanSetting]
        let detail: String
    }

    /// The five shapes item 0 refuses, each over a lease on fan 0 of a two-fan machine.
    static let refusals = [
        Refusal(
            description: "an empty list", settings: [], detail: LeaseApplyRules.Detail.noSettings),
        Refusal(
            description: "an automatic setting",
            settings: [FanSetting(fanIndex: 0, control: .automatic)],
            detail: LeaseApplyRules.Detail.automatic),
        Refusal(
            description: "a curve",
            settings: [
                FanSetting(
                    fanIndex: 0,
                    control: .curve(
                        FanCurve(
                            points: [.init(temperatureCelsius: 40, rpm: 2_000)],
                            source: SensorGroup(sensorKeys: ["Tp01"]))))
            ],
            detail: LeaseApplyRules.Detail.curve),
        Refusal(
            description: "a fan the lease does not cover",
            settings: fixed((0, 2_000), (1, 2_000)), detail: LeaseApplyRules.Detail.uncovered),
        Refusal(
            description: "a fan named twice",
            settings: fixed((0, 2_000), (0, 2_400)), detail: LeaseApplyRules.Detail.duplicate),
    ]

    /// **Item 0.** Each is refused with `invalidParameter(name: "settings")` and its fixed detail,
    /// before anything is read or written.
    ///
    /// **Mutations, one per guard, in `LeaseApplyRules.goals(of:coveredBy:)`:** delete the empty
    /// list's `guard`; make `.automatic` `continue`; make `.curve` `continue`; delete the coverage
    /// `guard`; delete the duplicate `guard`. Run: red on that argument each time, and on no other.
    @Test("Item 0 refuses before anything is read or written", arguments: refusals)
    func itemZeroRefusesBeforeAnythingIsTouched(_ refusal: Refusal) async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id

        await #expect(throws: settingsRefused(refusal.detail)) {
            try await machine.levelSix().apply(refusal.settings, under: lease)
        }
        await Self.expectNothingTouched(machine)
    }

    // MARK: - Item 1

    /// **Item 1.** A lease bound to another connection is refused as `heldLease(id:from:)`
    /// refuses it, and never reaches the driver: nothing is read, written or entered.
    ///
    /// **Mutation:** in `LeaseAuthority.heldLease(id:from:)`, delete the connection `guard`. Run:
    /// red here, the fan engaged and commanded under someone else's lease.
    @Test("Another connection's lease never reaches a write")
    func anotherConnectionsLeaseNeverReachesAWrite() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id

        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            try await machine.levelSix().applier.apply(
                fixed((0, 2_400)), leaseID: lease, from: ConnectionID())
        }
        await Self.expectNothingTouched(machine)
    }

    /// **Item 1, the driver.** `apply` engages and commands through a driver bound to the lease it
    /// authorised; the composed driver is bound to none and refuses every step.
    ///
    /// **Mutation:** in `LeaseApplier.step`, bind `let driver = engagement` instead of
    /// `engagement.under(lease: lease)`. Run: red, refused with nothing engaged or written.
    @Test("An apply engages and commands through the lease-bound driver")
    func anApplyEngagesThroughTheBoundDriver() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id

        try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)

        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(await machine.commandedRPMs == [2_400])
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
        #expect(machine.gate.isIdle)
    }

    // MARK: - Item 3

    /// **Item 3.** What § 5 records is the `CommandedTarget` the write returned, and the plane
    /// returns 2,001 for a request of 2,000.
    ///
    /// **Mutation:** in `LeaseApplier.step`, report `CommandedTarget(fanIndex: index, rpm: rpm)`.
    /// Run: red, 2,000 recorded.
    @Test("The report is what the write returned, never the request")
    func theReportIsWhatTheWriteReturned() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.misreport(commandedRPM: 2_001)

        try await machine.levelSix(writingThrough: writes).apply(fixed((0, 2_000)), under: lease)

        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)
                == CommandedTarget(fanIndex: 0, rpm: 2_001))
    }

    /// **Item 3, after the write and never before.** Fan 0 is held at 2,000 under the lease, and a
    /// re-apply to 3,000 is refused by the firmware: § 5 still records 2,000, which the fan holds.
    ///
    /// **Mutation:** in `LeaseApplier.step`, send the report built from the request before the
    /// write and none after it. Run: red, 3,000 recorded for a write that never landed.
    @Test("A write that throws is never reported")
    func aWriteThatThrowsIsNeverReported() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(targetWrites: .refused(reason: "F0Tg refused"))],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        try await levelSix.apply(fixed((0, 2_000)), under: lease)
        await machine.plane.advance()

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 3_000)), under: lease)
        }
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(
            await machine.watchdog.fansUnderManualControl == [0], "a fan engaged before was undone")
    }

    // MARK: - Item 4

    /// **Item 4.** The lease ends during the command write: the write lands, and the reply is the
    /// lease's fault, never applied.
    ///
    /// **Mutation:** delete `apply`'s last `heldLease(id:from:)`. Run: red, applied.
    @Test("A lease that ends mid-apply is never answered applied")
    func aLeaseThatEndsMidApplyIsNeverApplied() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.interfere { await machine.endLease() }

        await #expect(throws: AeolusXPCFault.leaseUnknown) {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire)
    }

    /// **Item 4, § 3's latch.** § 3 latches during the command write: the reply is
    /// `.thermalEmergencyActive`, never applied, and § 3 holds the fan the driver registered.
    ///
    /// **Mutation:** delete `apply`'s latch `guard`. Run: red, applied.
    @Test("§ 3 latching mid-apply is never answered applied")
    func aLatchMidApplyIsNeverApplied() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.interfere { await machine.engageThermalEmergency() }

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(await machine.emergency.fansUnderManualControl.contains(0))
    }

    // MARK: - A shipped build

    /// **On a build that cannot write, `apply` fails at `heldLease(id:from:)` with the faults it
    /// answers today, in the same order, and never enters the gate.** Composed over a plane that
    /// answers `.notBuilt`, no lease is granted, so level 6's `apply` and the shipped
    /// `SupervisedFanAuthority.apply` answer each request alike: `.leaseUnknown`, before item 0
    /// and before the capability, whatever the settings say.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, check item 0 before `heldLease(id:from:)`. Run: red,
    /// an empty list answered `invalidParameter`. Moving the capability `guard` first is red the
    /// same way, answered `.writePathNotBuilt`.
    @Test("On a build that cannot write, apply fails at heldLease and never enters the gate")
    func onANotBuiltBuildApplyFailsAtHeldLease() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = HelperComposition(
            plane: ControlStateGatePlane(firmware, capability: .notBuilt),
            snapshotProvider: fanProvider(fanCount: 1), criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog, leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
        #expect(helper.plane.writeCapability == .notBuilt, "this test is vacuous on a .built plane")
        await helper.bindSafetyRegistries()
        let applier = LeaseApplier(
            writer: GovernedFanWriter(plane: helper.plane),
            engagement: EngagementDriver(
                writer: SafetyActorWriter(plane: helper.plane, level: .leaseExpiry),
                leases: helper.leases, latch: helper.latch, emergency: helper.thermalEmergency,
                clock: SystemMonotonicClock(), level: .controlLoop, log: helper.safetyLog),
            gate: helper.examinationGate, envelopes: helper.plane,
            reclamation: helper.reclamationWatchdog, leases: helper.leases, latch: helper.latch,
            writeCapability: helper.plane, log: helper.safetyLog)
        await #expect(throws: (any Error).self, "a lease was granted on .notBuilt") {
            try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        let connection = ConnectionID()
        for settings in [fixed((0, 2_400)), [], fixed((0, 2_400), (0, 2_000))] {
            let lease = UUID()
            let today = await LeaseApplierAnswerTests.answer {
                try await helper.authority.apply(settings, leaseID: lease, from: connection)
            }
            let levelSix = await LeaseApplierAnswerTests.answer {
                try await applier.apply(settings, leaseID: lease, from: connection)
            }
            #expect(today as? AeolusXPCFault == .leaseUnknown)
            #expect(levelSix as? AeolusXPCFault == today as? AeolusXPCFault, "\(settings)")
        }
        #expect(helper.examinationGate.entrants == 0, "the gate was entered on a shipped build")
        #expect(await firmware.attempts.isEmpty, "a shipped build's apply reached the firmware")
    }

    // MARK: - The driver's level

    /// Level 6's driver is asked about the control loop's level. A6's next step composes it and
    /// pins the composed one; until then this pins the one level 6 is built with here.
    ///
    /// **Mutation:** build `LevelSix`'s driver with `level: .reclamationWatchdog`. Run: red.
    @Test("Level 6's driver is at the control loop's level")
    func levelSixsDriverIsAtTheControlLoopsLevel() {
        #expect(ReclamationMachine().levelSix().applier.engagementLevel == .controlLoop)
    }
}
