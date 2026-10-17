import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// How level 6 reads a fan through the driver when it holds no `.engaged` account of it
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment):
/// only a fan whose hand-back was refused, still holding the raw value Aeolus's engagement writes,
/// is read as still the lease's. A fan with no account, or a kept fan holding any other value, is
/// someone else's. And a refused undo inside the driver keeps the fan's account (#406).
///
/// The kept fans a re-apply re-adopts are `LeaseApplierHandBackTests`'; which refusals open and end
/// an account are `LeaseApplierIssuedWriteTests`' and `LeaseApplierAccountEndTests`'. Every
/// scenario runs the real `LeaseApplier` over a `ReclamationMachine`, and each test names the
/// mutation it kills.
@Suite("Level 6 reads a fan it does not hold engaged", .timeLimit(.minutes(1)))
struct LeaseApplierKeptFanTests {

    /// What `SafetyLog.engagementUndoRefused(fan:detail:)` says for fan 0.
    static let undoRefused = "Could not undo the engagement of fan 0"

    /// **A fan with no account that reads manual is someone else's.** Fan 0 is leased on
    /// automatic, and another program takes it before level 6 ever engages it. The `apply` runs the
    /// driver, whose first step reads raw `1` and refuses with nothing written; with no account
    /// under the lease, level 6 answers `.foreignManualControl`, registers nothing and writes
    /// nothing. The raw value alone never makes a fan Aeolus's.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, re-adopt an engaged-mode `.notAutomatic` without
    /// asking the account. Run: red, the fan adopted, registered and commanded.
    @Test("A fan never engaged that reads manual is answered foreignManualControl")
    func aFanNeverEngagedThatReadsManualIsForeign() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        await machine.plane.setMode(.manual, ofFan: 0)

        let answered = await LeaseApplierAnswerTests.answer {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }

        #expect(
            answered as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "answered \(answered as Any)")
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)),
            "the driver never read the fan")
        #expect(await machine.plane.keyWrites.isEmpty, "something was written to a foreign fan")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).isEmpty)
    }

    /// **A kept fan reading any other raw value is someone else's.** Fan 0 is kept in manual;
    /// before its re-apply, another program leaves its raw mode at `2`, a value no engagement of
    /// Aeolus's writes. The driver's first step refuses `.notAutomatic` with nothing written, and
    /// level 6 answers `.foreignManualControl`: only `EngagementRules.isEngagedMode`, the
    /// read-back's own predicate, reads a kept fan as still the lease's.
    ///
    /// **Mutation:** make `EngagementRules.isEngagedMode` answer `rawMode != 0`. Run: red, the fan
    /// re-adopted and commanded.
    @Test("A kept fan reading another raw value is answered foreignManualControl")
    func aKeptFanReadingAnotherRawValueIsForeign() async throws {
        let kept = try await KeptFan.inManual()
        let machine = kept.machine
        await machine.plane.setRawMode(2, ofFan: 0)
        let attemptsBefore = await machine.attempts.count
        let writesBefore = await machine.plane.keyWrites.count

        let answered = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 2_000)), under: kept.lease)
        }

        #expect(
            answered as? AeolusXPCFault
                == .manualControlUnavailable(reason: .foreignManualControl),
            "answered \(answered as Any)")
        let reApply = await machine.attempts.dropFirst(attemptsBefore)
        #expect(reApply.contains(.engageManualControl(fan: 0)), "the driver never read the fan")
        #expect(
            KeptFan.writes(in: reApply) == [.engageManualControl(fan: 0)],
            "the re-apply did more than read a fan another program holds: \(Array(reApply))")
        #expect(await machine.plane.keyWrites.dropFirst(writesBefore).isEmpty)
        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).isEmpty)
    }

    /// **#406: a driver undo the firmware refused keeps the fan's account.** Fan 0's
    /// engagement writes `F0Md = 1`, which lands, and its read-back answers `0`, so the step throws
    /// `.engagementNotConfirmed`; then the firmware stops taking writes, and the driver's own undo
    /// is refused. The `apply` is answered by that cause, and its notice names fan 0 as not handed
    /// back. Level 6 kept the fan: once the firmware takes writes again, a re-apply re-adopts it as
    /// a fan still in manual, with nothing written, and is applied.
    ///
    /// **Mutation:** in `EngagementDriver.engageManualControl(of:)`, throw the bare `error` for a
    /// refused undo. Run: red, the notice says no engagement returned and the re-apply is answered
    /// `.foreignManualControl`. **Mutation:** in `LeaseEngagements.read`, throw the wrapper without
    /// calling `keep`. Run: red on the re-apply, the same.
    @Test("A driver undo the firmware refused keeps the fan's account for its re-apply")
    func aDriverUndoTheFirmwareRefusedKeepsTheFansAccount() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(writes: .refused(reason: "F0Md refused")), .nominal()],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .refusedEngageStep)
        await writes.interfere { await machine.plane.advance() }
        await machine.plane.setRawMode(0, ofFan: 0)
        let levelSix = machine.levelSix(writingThrough: writes)

        let refused = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }

        #expect(await writes.didFire, "the step was never refused")
        #expect(
            refused as? AeolusXPCFault
                == .helperFailed(detail: LeaseApplyRules.Detail.notConfirmed),
            "the apply was not answered by its cause: \(refused as Any)")
        #expect(machine.safetyLog.levels(containing: Self.undoRefused) == [.fault])
        let notice = machine.safetyLog.lines(containing: "Level 6's apply was refused")
        #expect(notice.count == 1)
        #expect(
            notice.allSatisfy { $0.contains("The hand-back of [0] was refused") },
            "the refusal's notice did not name fan 0 as not handed back: \(notice)")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual, "the undo landed")

        await machine.plane.setRawMode(nil, ofFan: 0)
        await machine.plane.advance()
        let attemptsBefore = await machine.attempts.count
        let writesBefore = await machine.plane.keyWrites.count
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(
            await machine.attempts.dropFirst(attemptsBefore).contains(.engageManualControl(fan: 0)),
            "the re-apply did not run the driver for a fan whose hand-back was refused")
        #expect(
            await machine.plane.keyWrites.dropFirst(writesBefore).contains(.mode(fan: 0, value: 1))
                == false)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_000)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// **`.notBuilt` is unchanged.** A fan kept under a lease granted where the write path was
    /// built, re-applied once it reports `.notBuilt`, a state only a test can build: the answer is
    /// `.writePathNotBuilt`, and nothing is read, written or registered. A kept fan's route through
    /// the driver sits behind the capability, as every other is, and a shipped build, which grants
    /// no lease, never reaches it.
    ///
    /// **Mutation:** delete `apply`'s capability `guard`. Run: red, the fan re-adopted and
    /// commanded.
    @Test("On a write path that is not built, a kept fan's re-apply answers writePathNotBuilt")
    func aKeptFanOnAWritePathNotBuiltIsAnsweredAsBefore() async throws {
        let kept = try await KeptFan.inManual()
        kept.writes.report(.notBuilt)
        let attemptsBefore = await kept.machine.attempts.count

        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)) {
            try await kept.levelSix.apply(fixed((0, 2_000)), under: kept.lease)
        }
        #expect(await kept.machine.attempts.count == attemptsBefore, "the re-apply touched the fan")
        #expect(kept.machine.safetyLog.lines(containing: KeptFan.reAdopted).isEmpty)
    }
}

/// A fan level 6 engaged and could not hand back: its command was refused, and so was its undo's
/// restore, so it is in manual and kept as one whose hand-back was refused. The firmware takes
/// writes again once `inManual()` returns.
struct KeptFan {
    let machine: ReclamationMachine<ScriptedControlPlane>
    let writes: InterferingFanStateSensing
    let levelSix: LevelSix<InterferingFanStateSensing>
    let lease: UUID
    /// What the `apply` that kept the fan was answered.
    var refusal: (any Error)?

    /// Every fan's condition before anything is written.
    static let automatic = ScriptedControlPlane.FanCondition.automatic(at: 1_800)

    /// What `SafetyLog.controlLoopKeptFanReAdopted(fan:rawMode:)` says for fan 0 at raw `1`.
    static let reAdopted = "Fan 0, whose hand-back level 6 could not confirm, reads raw mode 1"

    /// The writes among `attempts`: every engagement step, command and restore.
    static func writes(
        in attempts: some Sequence<ScriptedControlPlane.Attempt>
    ) -> [ScriptedControlPlane.Attempt] {
        attempts.filter {
            switch $0 {
            case .engageManualControl, .commandTarget, .restoreToAutomatic: true
            default: false
            }
        }
    }

    /// A fan whose command was refused and whose undo's restore was refused too, under level 6's
    /// own undo: in manual, kept. The machine's stages are those, `later` after them; the firmware
    /// takes writes again once this returns. With `order`, the driver's § 3 registrations are
    /// recorded there, through `RecordingRegistration`, before they reach § 3.
    static func inManual(
        then later: [ScriptedControlPlane.Stage] = [], recordingInto order: Sightings<String>? = nil
    ) async throws -> KeptFan {
        let machine = ReclamationMachine(
            stages: [
                .nominal(targetWrites: .refused(reason: "F0Tg refused")),
                .nominal(writes: .refused(reason: "F0Md refused")), .nominal(),
            ] + later,
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .refusedCommandWrite)
        await writes.interfere { await machine.plane.advance() }
        let registration = order.map {
            RecordingRegistration(forwardingTo: machine.emergency, recordingInto: $0)
        }
        let levelSix = machine.levelSix(writingThrough: writes, registration: registration)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire, "the command was never refused")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual, "the restore landed")
        await machine.plane.advance()
        return KeptFan(machine: machine, writes: writes, levelSix: levelSix, lease: lease)
    }

    /// A fan kept on automatic: engaged under the force key, its command refused, and its undo's
    /// restore landing `F0Md = 0` while the force key's clear is refused, so the hand-back threw
    /// and level 6 kept fan 0. `fans` are leased, and every stage reads `temperatures`; the
    /// firmware takes writes again once this returns.
    static func onAutomatic(
        of fans: [Int] = [0],
        unlock: ScriptedControlPlane.UnlockBehaviour = .heldUntilForced(stepsToYield: 0),
        temperatures: [String: Double] = [:]
    ) async throws -> KeptFan {
        let conditions = Dictionary(uniqueKeysWithValues: fans.map { ($0, Self.automatic) })
        let plane = ScriptedControlPlane(
            fans: conditions,
            stages: [
                .nominal(temperatures: temperatures, targetWrites: .refused(reason: "F0Tg")),
                .nominal(temperatures: temperatures, forceKeyWrites: .refused(reason: "Ftst")),
                .nominal(temperatures: temperatures),
            ],
            unlock: unlock)
        let machine = ReclamationMachine(plane: plane, fans: conditions)
        let lease = try await machine.lease(fans: fans).id
        let writes = InterferingFanStateSensing(plane, during: .refusedCommandWrite)
        await writes.interfere { await plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire, "the command was never refused")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "the restore's mode write")
        await plane.advance()
        return KeptFan(machine: machine, writes: writes, levelSix: levelSix, lease: lease)
    }

    /// A fan the driver could not hand back itself (#406): its mode write lands, its read-back
    /// answers `0`, and the firmware refuses the driver's undo, so it is in manual and kept. Fan
    /// `index` of `fans`, all leased; the firmware takes writes again once this returns.
    static func keptByTheDriver(fan index: Int = 0, of fans: [Int] = [0]) async throws -> KeptFan {
        let machine = ReclamationMachine(
            stages: [
                .nominal(), .nominal(writes: .refused(reason: "F\(index)Md refused")), .nominal(),
            ],
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .automatic(at: 1_800)) }))
        let lease = try await machine.lease(fans: fans).id
        let writes = InterferingFanStateSensing(machine.plane, during: .refusedEngageStep)
        await writes.interfere { await machine.plane.advance() }
        await machine.plane.setRawMode(0, ofFan: index)
        let levelSix = machine.levelSix(writingThrough: writes)

        let refusal = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((index, 2_400)), under: lease)
        }
        #expect(refusal != nil, "the apply that should have kept fan \(index) was applied")
        #expect(await writes.didFire, "the step was never refused")
        #expect(try await machine.plane.firmwareMode(ofFan: index) == .manual, "the undo landed")
        await machine.plane.setRawMode(nil, ofFan: index)
        await machine.plane.advance()
        return KeptFan(
            machine: machine, writes: writes, levelSix: levelSix, lease: lease, refusal: refusal)
    }

    /// A fan whose report § 5 answered `.notHeld`, and whose hand-back the firmware then refused:
    /// § 5 is told fan 0 was released while its command lands, and the undo's restore is refused.
    /// In manual, kept; the firmware takes writes again once this returns.
    static func keptAfterNotHeld() async throws -> KeptFan {
        let machine = ReclamationMachine(
            stages: [
                .nominal(), .nominal(writes: .refused(reason: "restore refused")), .nominal(),
            ],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        await writes.interfere {
            await machine.watchdog.manualControlReleased(fanAt: 0)
            await machine.plane.advance()
        }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        ) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire, "§ 5 was never told the fan was released")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual, "the hand-back landed")
        await machine.plane.advance()
        return KeptFan(machine: machine, writes: writes, levelSix: levelSix, lease: lease)
    }
}

/// § 3's registration role as level 6's driver reaches it: each registration recorded in `order`,
/// then forwarded to § 3, so a scenario can place it beside the commands it records there too.
actor RecordingRegistration: ThermalEmergencyRegistering {
    private let forwarding: any ThermalEmergencyRegistering
    private let order: Sightings<String>

    init(
        forwardingTo forwarding: any ThermalEmergencyRegistering,
        recordingInto order: Sightings<String>
    ) {
        self.forwarding = forwarding
        self.order = order
    }

    func manualControlEngaged(_ fan: CommandableFan) async {
        await order.record("registered \(fan.index)")
        await forwarding.manualControlEngaged(fan)
    }

    func handbackAccepted(fanAt index: Int) async {
        await forwarding.handbackAccepted(fanAt: index)
    }
}
