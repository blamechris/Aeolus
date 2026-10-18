import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `LeaseApplierExaminationTests`' case about § 5's bound with the real level 6, in a file of its
/// own so the suite's body stays under `type_body_length`.
extension LeaseApplierExaminationTests {

    /// **§ 5's bound outlasts an engagement's lawful hold at ADR 0012's design point** (ADR 0014's
    /// A6 PR-2 amendment). Fan 0 is registered with § 5 and on automatic, and level 6 engages it
    /// through a yield the firmware gives only under its force key. § 5's sweep reaches the fan as
    /// the engagement's last poll is about to run, and queues for the gate. That poll starts 3.4 s
    /// into the yield budget and its turn, its wait included, takes G, as a turn may at the design
    /// point: the gate's clock moves 13.4 s. The command's turn takes G more. § 5 has then waited
    /// 23.4 s inside a lawful hold: it says nothing, is granted when the step leaves, and examines
    /// the fan under the gate against the target the step reported.
    ///
    /// **Mutation:** the A6 formula, `lawfulHold = UnlockLimits.yieldBudget +
    /// WatchdogLimits.roundTrip * 2`, so `examinationWait` is 15.5 s. Run: red, § 5 runs out inside
    /// the command's turn and says so at `.fault`.
    @Test("§ 5's wait outlasts an engagement's lawful hold at ADR 0012's design point")
    func theBoundOutlastsALawfulHoldAtTheDesignPoint() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], unlock: .heldUntilForced(stepsToYield: 0))
        let machine = ReclamationMachine(plane: plane, fans: [0: .automatic(at: 1_800)])
        try await machine.holdWithoutCommanding(fan: 0)
        let lease = try await machine.leaseID()
        let writes = InterferingFanStateSensing(plane, during: .commandWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let turn = WatchdogLimits.gateWaiterAlarm
        let lastPoll = UnlockLimits.yieldBudget - .milliseconds(100)
        let sweeps = Sightings<ObservableWork<Void>>()
        let stillWaiting = Sightings<Bool>()
        await writes.interfere(beforeEngageStep: 2) {
            let sweep = observing { await machine.watchdog.cycle() }
            await sweeps.record(sweep)
            _ = await yieldUntil("§ 5 to queue for the gate, or to examine without it") {
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                return await sweep.isFinished.isSet
            }
            machine.gateClock.advance(by: lastPoll + turn)
        }
        await writes.interfere {
            machine.gateClock.advance(by: turn)
            await FanExaminationGateTests.settle()
            await stillWaiting.record(machine.gate.waiting(onFan: 0) == 1)
        }

        try await levelSix.apply(fixed((0, 2_400)), under: lease)
        let sweep = try #require(await sweeps.seen.first, "the engagement's last poll never came")
        try await finished("§ 5's examination once the step left", sweep)

        #expect(await writes.didFire)
        #expect(
            machine.safetyLog.lines(containing: "examination gate").isEmpty,
            "§ 5 ran out inside a lawful hold")
        #expect(await stillWaiting.seen == [true], "§ 5 was not waiting when the hold ended")
        await ReclamationExaminationGateTests.expectNotJudgedAReclamation(machine)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
        #expect(machine.gate.isIdle)
    }
}
