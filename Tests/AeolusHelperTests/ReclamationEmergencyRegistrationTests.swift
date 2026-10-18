import Testing

@testable import AeolusHelper

/// § 5's re-assert and § 3's registry
/// ([#181](https://github.com/blamechris/Aeolus/issues/181), ADR 0014 D4): the engagement
/// driver registers every fan it engages with § 3 before its after-check, and every hand-back
/// § 5 issues deregisters through the driver — an accepted restore is owed § 3's read-back, and
/// a refused one stays registered for § 3's next emergency to bridge.
@Suite("§ 5's engagements and § 3's registry", .timeLimit(.minutes(1)))
struct ReclamationEmergencyRegistrationTests {

    /// **#181's residual, discharged.** § 3 latches mid-write and **the undo is refused**: the
    /// fan ends in § 3's registry, and § 3's next latched cycle bridges and restores it.
    ///
    /// Before #181 the re-assert registered with nothing, so a refused undo left the fan off
    /// automatic control above the ceiling with a log line and nothing else watching it. The
    /// driver now registers the fan with § 3 when it reads back engaged — before its
    /// after-check — and a refused hand-back tells § 3 nothing, so the registration stands.
    ///
    /// **Mutation:** delete `await emergency.manualControlEngaged(fan)` from
    /// `EngagementDriver.engageManualControl(of:)`. Run: red on the registry assertion and on
    /// the bridge.
    @Test("A refused undo leaves the fan in § 3's registry, and § 3's next cycle bridges it")
    func aRefusedUndoIsBridgedByTheNextLatchedCycle() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [
                .nominal(), .nominal(writes: .refused(reason: "firmware said no")), .nominal(),
            ]
        )
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in
            await machine.engageThermalEmergency()
            await machine.plane.advance()
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(machine.safetyLog.lines(containing: "is being undone").count == 1)
        #expect(
            try await plane.readControlState(ofFan: 0).mode == .manual,
            "the scenario did not leave the fan off automatic control")
        #expect(await machine.emergency.fansUnderManualControl == [0])
        #expect(await machine.emergency.fansOwedHandbackReadBack.isEmpty)

        // The firmware takes writes again, and § 3 cycles while still latched.
        await plane.advance()
        await machine.emergency.cycle()

        let maximum = try commandableFan(0, declaring: .automatic(at: 1_800))
            .envelope.highestCommandableRPM
        #expect(
            await machine.attempts.contains(.commandTarget(fan: 0, rpm: maximum)),
            "§ 3 did not bridge the fan § 5 could not hand back")
        #expect(try await plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await machine.emergency.fansUnderManualControl.isEmpty)
    }

    /// **#181's deregistration on `restoreAndForget(fanAt:heldUnder:)`.** A fan the driver
    /// registered with § 3, handed back by § 5 because its lease lapsed, is marked owed § 3's
    /// read-back by the accepted restore — not left registered as though it were still held, and
    /// not dropped.
    ///
    /// **Mutation:** in `restoreAndForget(fanAt:heldUnder:)`, restore through
    /// `writer.restoreToAutomatic(.fan(index))` instead of `engagement.handBack(fanAt:)`. Run:
    /// red on the owed assertion.
    @Test("A lapsed lease's hand-back deregisters the fan from § 3")
    func aLapsedLeasesHandBackDeregistersFromTheEmergency() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        await machine.watchdog.cycle()
        #expect(
            await machine.emergency.fansUnderManualControl == [0],
            "the re-assert never registered the fan with § 3")

        machine.lapseLease()
        await machine.watchdog.cycle()

        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).count == 1)
        #expect(await machine.emergency.fansOwedHandbackReadBack == [0])
    }

    /// The command-only re-assert asks the lease as well as the latch: a fan still in manual
    /// whose lease lapsed during the envelope read is handed back, never commanded (hard rule
    /// 2 — manual control is a lease).
    ///
    /// **Mutation:** make `EngagementDriver.requireEntitlement(for:)` ask only the arbiter.
    /// Run: red on the command assertion.
    @Test("A lease lapsing during the envelope read refuses the command-only re-assert")
    func theCommandOnlyReassertAsksTheLease() async throws {
        let firmware = ScriptedControlPlane.FanCondition.held(at: 1_800)
        let plane = ScriptedControlPlane(fans: [0: firmware])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, fans: [0: firmware], sensing: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.interfere { [machine] in machine.lapseLease() }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 commanded a fan no lease covers")
        #expect(await machine.didRestore(fan: 0))
    }

    /// A budget that runs out spends the attempt and keeps the fan: the firmware refused, the
    /// fan was not taken from § 5, so it is not handed back as though it had been.
    ///
    /// **Mutation:** make `EngagementRefusal.yieldsTheFan` true for `.yieldDidNotArrive`. Run:
    /// red.
    @Test("§ 5 keeps a fan whose engagement ran out of budget")
    func aBudgetExpiryDoesNotYieldTheFan() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)], unlock: .neverYields)
        let machine = ReclamationMachine(plane: plane, fans: [0: .automatic(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.watchdog.fansUnderManualControl == [0], "§ 5 gave the fan up")
        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).isEmpty)
        #expect(machine.safetyLog.lines(containing: "re-assert of fan 0 was refused").isEmpty)
    }
}
