import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The orderly teardown with level 6's `apply` in flight (ADR 0014's A6 PR-3 and #410
/// ticket-and-seal amendments).
///
/// `SignalTeardown`'s control gate refuses an `apply` that arrives once it is closed, through the
/// authority's shutdown refusal, and covers nothing already in flight. What covers flight is the
/// plane: the engagement's ticket, taken before its entitlement, and the exit's `.forExit`, which
/// seals the plane against every forward write from the moment it is requested. Both halves are
/// here: the refusal on arrival, and what an engagement, a command and a re-assert already in
/// flight write after the keystone, which is nothing.
@Suite("The teardown with an apply in flight", .timeLimit(.minutes(1)))
struct SignalTeardownInFlightApplyTests {

    private static let applyInProgress = AeolusXPCFault.helperFailed(
        detail: LeaseApplyRules.Detail.applyInProgress)

    // MARK: - Arrival

    /// An `apply` that arrives once the teardown has begun, beside one already in flight under
    /// the same lease, gets the shutdown refusal and reaches no `LeaseApplier`. Reaching it, it
    /// would meet the claim of the `apply` in flight and be answered `applyInProgress`. The one in
    /// flight runs on, and is answered applied: the gate covers arrival, not flight.
    ///
    /// **Mutation:** in `SupervisedFanAuthority.apply`, delegate before `refuseIfShuttingDown`.
    /// Run: red, the second `apply` answered `applyInProgress`, and the one in flight refused for
    /// shutdown once level 6 had applied it.
    @Test("An apply arriving during the teardown, beside one in flight, is refused for shutdown")
    func anApplyArrivingDuringTheTeardownIsRefusedForShutdown() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        let engagement = HopParking()
        await machine.writes.interfere(beforeEngageStep: 1) { await engagement.park() }

        let inFlight = observing { try await machine.apply(rpm: 2_400, under: lease) }
        #expect(
            await yieldUntil("the first apply to park in its engagement") {
                await engagement.isParked
            })
        await machine.helper.authority.controlGate.close()
        let arriving = await LevelSixMachine.answer {
            try await machine.apply(rpm: 3_000, under: lease)
        }
        await engagement.release()
        let inFlightAnswer = await LevelSixMachine.answer {
            try await finished("the apply in flight", inFlight)
        }

        #expect(
            arriving == SupervisedApplyBoundaryTests.shuttingDown,
            "an apply arriving during the teardown was answered \(String(describing: arriving))")
        #expect(
            inFlightAnswer == nil,
            "the apply in flight was answered \(String(describing: inFlightAnswer))")
        #expect(
            await machine.helper.reclamationWatchdog.lastCommanded(ofFan: 0)?.rpm == 2_400,
            "the apply refused for shutdown reached level 6, or the one in flight did not finish")
    }

    // MARK: - Flight: nothing is written after the exit's keystone (#410)

    /// A teardown that begins while an `apply` is mid-engagement — after the driver's ticket and
    /// entitlement, before the engagement's first step — leaves no forward write behind it. The
    /// release ends the lease, the keystones request `.everyFan` then `.forExit`, and the first
    /// step is refused at its admission; the retry's entitlement refuses on the ended lease, so
    /// nothing is written or undone, and the process ends `.restored` with the fan automatic and
    /// the key clear.
    ///
    /// This inverts the residual the A6 PR-3 amendment pinned here, ruling D19's: until #410 the
    /// first step was admitted after the final keystone, wrote `F<n>Md = 1`, and on the force-key
    /// path `Ftst = 1`, and only the driver's after-check undid it, after the exit was called.
    ///
    /// **End to end, both guards together, and it does not discriminate the seal's step half.**
    /// The seal is checked first, but the engagement's ticket predates the release's restore and
    /// both keystones, so it refuses the step as well. So deleting the seal check leaves this
    /// green (`PlaneWriteLedgerTests.aSealedLedgerRefusesATicketedStep` is the row that keeps that
    /// half honest), and so does the rule before the ticket, whose step the seal refuses.
    /// **Mutation:** both together — delete the seal check at the top of
    /// `PlaneWriteLedger.admitStep(fanAt:)` and admit a first step whatever its ticket. Run: red,
    /// at the forward-write assertion, on both paths.
    @Test(
        "An apply in flight at the exit writes nothing after the keystone",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.naive, .heldUntilForced(stepsToYield: 2),
        ])
    func anApplyInFlightAtTheExitWritesNothingAfterTheKeystone(
        unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let machine = await LevelSixMachine(unlock: unlock)
        let lease = try await machine.lease()
        let atExit = FirmwareAtExit()
        await machine.writes.interfere(beforeEngageStep: 1) {
            await machine.helper.signalTeardown.run(stoppingSupervisorsWith: {
                await machine.helper.shutDown()
            })
            await atExit.record(machine.firmware)
        }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        let writes = await machine.firmware.keyWrites
        let afterExit = await atExit.attemptsAfter(on: machine.firmware)
        #expect(await machine.writes.didFire, "the teardown never ran inside the engagement")
        #expect(machine.journal.exitsNow == [.restored], "the teardown did not end the process")
        #expect(
            !writes.contains(.mode(fan: 0, value: 1)) && !writes.contains(.forceKey(1)),
            "a forward write reached the firmware: \(writes)")
        #expect(
            !afterExit.contains(.restoreToAutomatic(.fan(0))),
            "fan 0 was undone after the exit, so a step had written: \(afterExit)")
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.firmware.isForceKeySet == false, "the force key was left set")
        #expect(answer == .leaseUnknown, "the apply was answered \(String(describing: answer))")
    }

    /// **The seal's command half (#410's item 1b).** Fan 0 is engaged by a first `apply`. A
    /// re-apply asks the entitlement while the lease is live, and its command is parked before its
    /// turn while the real teardown runs. The command is still attempted after the exit — and its
    /// target is not written, because `.forExit` sealed the plane and `admitCommand()` refuses it
    /// first in the command's turn. The engaged fan the keystones restored stays automatic.
    ///
    /// Nothing else stands here: a command takes no ticket, so this is the only guard against a
    /// target written after the exit's keystone.
    ///
    /// **Mutation:** delete `try ledger.admitCommand()` from `ScriptedControlPlane.commandTarget`.
    /// Run: red, at the target-write assertion. **Mutation:** make
    /// `PlaneWriteLedger.admitCommand()` check nothing. Run: red, at the same assertion.
    @Test("A command in flight at the exit writes no target")
    func aCommandInFlightAtTheExitWritesNoTarget() async throws {
        let machine = await LevelSixMachine()
        let lease = try await machine.lease()
        try await machine.apply(rpm: 2_400, under: lease)
        let atExit = FirmwareAtExit()
        await machine.writes.interfere(beforeCommandTarget: 2) {
            await machine.helper.signalTeardown.run(stoppingSupervisorsWith: {
                await machine.helper.shutDown()
            })
            await atExit.record(machine.firmware)
        }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 3_000, under: lease)
        }

        let afterExit = await atExit.attemptsAfter(on: machine.firmware)
        let writes = await machine.firmware.keyWrites
        #expect(await machine.writes.didFire, "the teardown never ran inside the command")
        #expect(machine.journal.exitsNow == [.restored], "the teardown did not end the process")
        #expect(
            afterExit.contains(.commandTarget(fan: 0, rpm: 3_000)),
            "the command was never attempted after the exit, so this proves nothing: \(afterExit)")
        #expect(
            !writes.contains(.target(fan: 0, rpm: 3_000)),
            "a target was written after the exit's keystone: \(writes)")
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(answer == .leaseUnknown, "the apply was answered \(String(describing: answer))")
    }

    /// § 3 between the two keystones. Fan 0 is engaged by an `apply` at 1,400 RPM, so § 3 has it
    /// registered; then the machine runs hot, and the firmware refuses every mode write while it
    /// honours target writes. The release's hand-back and the first keystone are refused, and § 3,
    /// which runs until the supervisors stop, crosses the ceiling. Its bridge still commands the
    /// maximum: the first keystone is `.everyFan`, which seals nothing, and only the last, after
    /// `stop()`, is `.forExit` (ADR 0014's #410 ticket-and-seal amendment). That keystone is
    /// refused too, so the exit is non-zero and launchd restarts the helper where it restarts.
    ///
    /// **Mutation:** make `SignalTeardown.run`'s first keystone `.forExit`, as both were before
    /// this was ruled. Run: red, at the maximum's target-write assertion: the seal refuses § 3's
    /// bridge, and fan 0 ends at 1,400 RPM.
    @Test("A thermal emergency before the supervisors stop still commands the maximum")
    func aThermalEmergencyBeforeTheSupervisorsStopStillCommandsTheMaximum() async throws {
        let machine = await LevelSixMachine(stages: [
            .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
            ScriptedControlPlane.Stage(
                temperatures: ScriptedControlPlane.Stage.temperatures(96),
                writes: .refused(reason: "the firmware holds every fan's mode"),
                targetWrites: .honoured),
        ])
        let lease = try await machine.lease()
        try await machine.apply(rpm: 1_400, under: lease)
        await machine.firmware.advance()
        let atStop = FirmwareAtExit()

        await machine.helper.signalTeardown.run(stoppingSupervisorsWith: {
            await atStop.record(machine.firmware)
            await machine.helper.thermalEmergency.cycle()
            await machine.helper.shutDown()
        })

        let afterFirstKeystone = await atStop.writesAfter(on: machine.firmware)
        let fan = try await machine.firmware.readControlState(ofFan: 0)
        #expect(
            afterFirstKeystone.contains(.target(fan: 0, rpm: 5_777)),
            "§ 3's bridge wrote no maximum after the first keystone: \(afterFirstKeystone)")
        #expect(fan.mode == .manual && fan.target == .rpm(5_777), "fan 0 ended at \(fan)")
        let exits = machine.journal.exitsNow
        #expect(exits == [.restoreFailed], "the exit was \(exits)")
    }

    /// § 5's re-engage in flight at the exit: fan 0 is engaged by an `apply`, the system takes it
    /// back, and § 5's re-assert re-engages it through its own driver, whose first step is parked
    /// after its ticket and entitlement while the real teardown runs. Nothing is written after the
    /// keystone, and the fan ends automatic with the key clear.
    ///
    /// **End to end, and it discriminates neither guard alone.** § 5 shares the driver, so its
    /// first step meets both the ticket and the seal, as level 6's does in the first test here.
    /// The ruling's mutation — move the seal out of the ledger into a teardown flag level 6 reads
    /// — leaves this green now, because the ticket refuses § 5's step without it; that this is
    /// end to end through § 5 is the claim. **Mutation:** delete the seal check in `admitStep` and
    /// admit a first step whatever its ticket, together. Run: red, at the forward-write assertion.
    @Test(
        "A re-assert in flight at the exit writes nothing after the keystone",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.naive, .heldUntilForced(stepsToYield: 2),
        ])
    func aReassertInFlightAtTheExitWritesNothingAfterTheKeystone(
        unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let machine = await LevelSixMachine(unlock: unlock)
        let lease = try await machine.lease()
        try await machine.apply(rpm: 2_400, under: lease)
        await machine.firmware.setMode(.automatic, ofFan: 0)
        let steps = await machine.firmware.attempts.filter { $0 == .engageManualControl(fan: 0) }
        let atExit = FirmwareAtExit()
        await machine.writes.interfere(beforeEngageStep: steps.count + 1) {
            await machine.helper.signalTeardown.run(stoppingSupervisorsWith: {
                await machine.helper.shutDown()
            })
            await atExit.record(machine.firmware)
        }

        await machine.helper.reclamationWatchdog.cycle()

        let afterExit = await atExit.writesAfter(on: machine.firmware)
        #expect(await machine.writes.didFire, "§ 5 never re-engaged the reclaimed fan")
        #expect(machine.journal.exitsNow == [.restored], "the teardown did not end the process")
        #expect(
            !afterExit.contains(.mode(fan: 0, value: 1)) && !afterExit.contains(.forceKey(1)),
            "a forward write reached the firmware after the exit: \(afterExit)")
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.firmware.isForceKeySet == false, "the force key was left set")
    }
}

/// What the firmware had received at the instant the teardown returned, which is after its
/// recorded exit and before whatever was parked resumes.
actor FirmwareAtExit {
    private(set) var writes: [ScriptedControlPlane.KeyWrite] = []
    private(set) var attempts: [ScriptedControlPlane.Attempt] = []

    func record(_ firmware: ScriptedControlPlane) async {
        writes = await firmware.keyWrites
        attempts = await firmware.attempts
    }

    /// The key writes `firmware` has received since the exit.
    func writesAfter(on firmware: ScriptedControlPlane) async -> [ScriptedControlPlane.KeyWrite] {
        Array(await firmware.keyWrites.dropFirst(writes.count))
    }

    /// The calls `firmware` has received since the exit.
    func attemptsAfter(on firmware: ScriptedControlPlane) async -> [ScriptedControlPlane.Attempt] {
        Array(await firmware.attempts.dropFirst(attempts.count))
    }
}
