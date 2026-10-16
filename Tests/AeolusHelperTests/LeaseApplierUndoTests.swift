import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Level 6's hold and its undo (ADR 0014's A6 and A6 PR-2 amendments): one hold per fan, one
/// gate at a time, the entitlement before each command, and an undo that drops § 5's record before
/// it hands a fan back, outside every gate and waiting for none.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`, writing through an
/// `InterferingFanStateSensing` over the machine's plane, so a moment inside one of level 6's
/// writes or steps can be observed. Each test names the mutation it kills.
@Suite("Level 6's hold and its undo", .timeLimit(.minutes(1)))
struct LeaseApplierUndoTests {

    // MARK: - Item 2

    /// **Item 2.** Fan 0 is engaged, registered, held and reported, and fan 1 is engaged; then
    /// fan 1's registration is refused, because its release notice landed while § 5 asked the lease
    /// core. Every fan this `apply` engaged is undone: when fan 0's restore lands § 5 no longer
    /// holds it, both are restored, and § 5's next cycle neither marks nor re-engages either.
    ///
    /// **Mutations:** in `LeaseApplier.undo`, delete the `manualControlHandedBack` call. Run: red,
    /// the next cycle marks fan 0 and re-engages it. Hand back before dropping the record (swap the
    /// two). Run: red, § 5 still held fan 0 as its restore landed.
    @Test("A refused registration undoes every fan, § 5's record first and then the restore")
    func aRefusedRegistrationUndoesEveryFanRecordFirst() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let atTheRestore = Sightings<Set<Int>>()
        await writes.interfere {
            await atTheRestore.record(await machine.watchdog.fansUnderManualControl)
        }
        await writes.interfere(beforeEngageStep: 2) { await hops.parkNextAnswer() }
        let levelSix = machine.levelSix(writingThrough: writes)

        let apply = observing {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        #expect(await yieldUntil("fan 1's registration to park") { await hops.isParked })
        await machine.watchdog.manualControlReleased(fanAt: 1)
        await hops.release()
        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)) {
            try await finished("the refused apply", apply)
        }

        #expect(await atTheRestore.seen == [[]], "§ 5 still held a fan as its restore landed")
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.didRestore(fan: 1))
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        let beforeTheCycle = await machine.attempts.count
        await machine.watchdog.cycle()
        #expect(
            await machine.attempts.dropFirst(beforeTheCycle).isEmpty,
            "§ 5 acted on a fan level 6 handed back")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
    }

    /// **Risk 7, half-landed.** Fan 1's mode write lands and its command is refused: every fan this
    /// `apply` engaged, fan 1 with fan 0, is undone, rather than fan 1 being left in manual at
    /// whatever target the firmware held.
    ///
    /// **Mutation:** in `LeaseApplier.step`, append the fan to `engaged` only after its command
    /// returns. Run: red, fan 1 left in manual and held by § 5.
    @Test("A command refused on a newly engaged fan undoes every fan this apply engaged")
    func aHalfLandedEngagementIsUndone() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused"))],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        await writes.interfere(beforeEngageStep: 2) { await machine.plane.advance() }

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400), (1, 2_600)), under: lease)
        }

        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(
            try await machine.plane.firmwareMode(ofFan: 1) == .automatic,
            "the half-landed fan was left in manual")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - The undo never waits for a gate

    /// **The undo never waits for a gate.** Fan 0 is engaged and held; while fan 1 engages, the
    /// system takes fan 0 back, and § 5's re-assert re-engages it and parks inside its yield wait,
    /// holding fan 0's gate. Fan 1's yield never arrives, so the `apply` is refused and fan 0 is
    /// undone: the undo finishes while § 5 still holds the gate. Once § 5 resumes, the undo's
    /// restore has superseded its engagement, and the fan is on automatic.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, take the fan's gate around its hand-back (`guard let
    /// pass = await gate.enterForStep(fanAt: index)`, left after). Run: red on "the apply finished
    /// while § 5 held fan 0's gate".
    @Test("The undo finishes while § 5 holds the fan's gate inside a re-assert's yield wait")
    func theUndoNeverWaitsForAGate() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)],
            unlock: .heldUntilForced(stepsToYield: 0))
        let sectionFive = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)],
            interfering: sectionFive)
        let lease = try await machine.lease(fans: [0, 1]).id
        let levelSixWrites = InterferingFanStateSensing(plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: levelSixWrites)
        let yieldWait = HopParking()
        await sectionFive.interfere(beforeEngageStep: 2) { await yieldWait.park() }
        let sweep = Sightings<ObservableWork<Void>>()
        await levelSixWrites.interfere(beforeEngageStep: 3) {
            await plane.setMode(.automatic, ofFan: 0)
            await plane.setForceKey(false)
            await sweep.record(observing { await machine.watchdog.cycle() })
            _ = await yieldUntil("§ 5 to park in its yield wait") { await yieldWait.isParked }
        }

        let apply = observing {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        let finishedWhileHeld = await yieldUntil("the apply to finish while § 5 holds the gate") {
            await apply.isFinished.isSet
        }
        #expect(finishedWhileHeld, "the apply finished while § 5 held fan 0's gate")
        #expect(machine.gate.isHeld(fanAt: 0))
        #expect(await yieldWait.isParked)
        #expect(await machine.didRestore(fan: 0), "fan 0 was not handed back")

        await yieldWait.release()
        let examination = try #require(await sweep.seen.first)
        try await finished("§ 5's sweep", examination)
        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.yieldDidNotArrive)
        ) {
            try await finished("the refused apply", apply)
        }
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.gate.isIdle)
    }

    // MARK: - One hold, one gate

    /// **One hold per fan.** At fan 0's engage step and inside its command write, fan 0's gate is
    /// held and nothing has entered since the step did; a two-fan `apply` enters the gate twice.
    ///
    /// **Mutation:** in `LeaseApplier.step`, leave the gate after the engagement and enter it again
    /// before the registration. Run: red on the entrant count at the command write and after.
    @Test("Each fan's engagement, registration, entitlement, write and report are one hold")
    func oneHoldPerFan() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        let held = Sightings<String>()
        await writes.interfere(beforeEngageStep: 1) {
            await held.record("engage: \(machine.gate.isHeld(fanAt: 0)) \(machine.gate.entrants)")
        }
        await writes.interfere {
            await held.record("command: \(machine.gate.isHeld(fanAt: 0)) \(machine.gate.entrants)")
        }

        try await machine.levelSix(writingThrough: writes).apply(
            fixed((0, 2_400), (1, 2_600)), under: lease)

        #expect(await held.seen == ["engage: true 1", "command: true 1"])
        #expect(machine.gate.entrants == 2, "a fan's step took the gate more than once")
        #expect(machine.gate.isIdle)
    }

    /// **No hold-and-wait.** While fan 1's step holds its gate, fan 0's is free: one gate at a
    /// time.
    ///
    /// **Mutation:** keep every fan's pass until the `apply` ends (collect them in `step` and leave
    /// them after the loop). Run: red, fan 0's gate held during fan 1's step.
    @Test("A fan's gate is left before the next fan's is taken")
    func noHoldAndWait() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let held = Sightings<[Bool]>()
        await writes.interfere(beforeEngageStep: 2) {
            await held.record([machine.gate.isHeld(fanAt: 0), machine.gate.isHeld(fanAt: 1)])
        }

        try await machine.levelSix(writingThrough: writes).apply(
            fixed((0, 2_400), (1, 2_600)), under: lease)

        #expect(await held.seen == [[false, true]], "fan 0's gate was held during fan 1's step")
        #expect(machine.gate.isIdle)
    }

    // MARK: - The entitlement before each command

    /// **Risk 6.** § 3 latches between the engagement and the command, while § 5 asks the lease
    /// core about the registration: no command is written, the fan is undone, and the answer is
    /// `.thermalEmergencyActive`.
    ///
    /// **Mutation:** delete `requireEntitlement(for:)` from `LeaseApplier.step`. Run: red, 2,400
    /// commanded into a latched machine.
    @Test("§ 3 latching between engaging and commanding means no command is written")
    func aLatchBeforeTheCommandWritesNoCommand() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        await hops.parkNextAnswer()

        let apply = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
        #expect(await yieldUntil("the registration's lease hop to park") { await hops.isParked })
        await machine.engageThermalEmergency()
        await hops.release()
        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            try await finished("the pre-empted apply", apply)
        }

        #expect(await machine.commandedRPMs.isEmpty, "a command was written into a latched machine")
        #expect(await machine.didRestore(fan: 0), "the engaged fan was not undone")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }
}
