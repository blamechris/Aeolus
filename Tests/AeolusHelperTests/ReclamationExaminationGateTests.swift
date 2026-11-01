import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5 takes the fan's examination gate, then stamps, and holds it to the examination's last act
/// (ADR 0014's #383 and A6 amendments): a level-6 step lands before an examination or after it,
/// never inside, so § 5 judges every reading against a record that is exactly the step's.
///
/// Every step here is `LevelSixStandIn`'s: the gate taken as `.step`, the target written through
/// `GovernedFanWriter`, its return reported, and the gate left. The waits are on the machine's own
/// `ManualClock`, so past the bound happens when a test moves it and at no other time.
///
/// Each test names the mutation it kills. **Red first:** run with § 5 as it is on `main` — the gate
/// never entered, the copy deciding after the ledger hop, the stamp ignored — the two orders, each
/// fan's own gate, the past-the-bound divergence and the cancelled wait here, and both cases in
/// `ReclamationLedgerHopTests` that need the gate, go red on their claims. The step under way and
/// the gate before the stamp pin orderings only a gate has: without one they go red only on the
/// wait they observe, and taking the gate after the read, or stamping first, is what turns their
/// claims red.
@Suite("§ 5 takes the gate, then stamps", .timeLimit(.minutes(1)))
struct ReclamationExaminationGateTests {

    /// What `SafetyLog.reclamationDetected` and the two stand-down lines say.
    static let detected = "Reclamation detected on fan 0"
    static let ungatedStandDown = "without its examination gate, past the gate's bound"
    static let leftToItsEngagement = "left this re-assert to that engagement"
    static let abandoned = "stopped short of re-asserting fan 0"

    static func lease<Writes>(_ machine: ReclamationMachine<Writes>) async throws -> UUID {
        try #require(await machine.leases.activeLease()).id
    }

    /// Asserts fan 0 was not judged a reclamation: no mark, no `.fault`, no re-assert.
    static func expectNotJudgedAReclamation<Writes>(
        _ machine: ReclamationMachine<Writes>, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "an ordinary step was reported as the system taking fan 0",
            sourceLocation: sourceLocation)
        #expect(
            machine.safetyLog.lines(containing: Self.detected).isEmpty,
            "an ordinary step was logged as a reclamation", sourceLocation: sourceLocation)
        #expect(
            machine.safetyLog.lines(containing: "re-asserted").isEmpty,
            "§ 5 re-asserted over an ordinary step", sourceLocation: sourceLocation)
    }

    // MARK: - The two orders

    /// **Forward order** (#383's acceptance). Fan 0 is held at 2,400. § 5 reads it and its lease
    /// check is held open; level 6 steps to 2,000 then. The step waits for the gate, so § 5 judges
    /// the 2,400 it read against the 2,400 recorded, and the step lands after the examination;
    /// the next cycle reads 2,000 against 2,000.
    ///
    /// **Mutation:** § 5 skips the gate — `cycle()` calls `examine(fanAt: index, inBound: true)`
    /// and enters nothing. Run: red on the wait, the step landing inside the examination, the
    /// mark, the `.fault` and the re-assert.
    @Test("A step attempted during the lease check waits, and is not judged a reclamation")
    func aStepDuringTheLeaseCheckWaitsForTheGate() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 4_400)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let lease = try await Self.lease(machine)
        let permit = try standIn.permit()

        await hops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the lease check to park") { await hops.isParked })
        let step = observing { try await standIn.step(to: 4_000, of: permit, under: lease) }
        #expect(
            await yieldUntil("the step to wait for the gate") {
                machine.gate.waiting(onFan: 0) == 1
            })
        #expect(await machine.commandedRPMs.isEmpty, "the step landed inside the examination")

        await hops.release()
        try await finished("the examination", sweep)
        #expect(try await finished("the step", step)??.rpm == 4_000)
        await Self.expectNotJudgedAReclamation(machine)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)

        try await finished("the next cycle", observing { await machine.watchdog.cycle() })
        await Self.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_000], "§ 5 wrote over the step")
        #expect(machine.gate.isIdle)
    }

    /// **Reverse order** (#383's acceptance). Level 6 has written 2,000 under the gate and not yet
    /// reported it when § 5's sweep reaches the fan. § 5 waits, and reads the fan only once the
    /// step is reported, so the reading and the record agree; without the gate it reads 2,000
    /// against the 2,400 recorded and re-asserts 2,400 over the step.
    ///
    /// **Mutations:** § 5 skips the gate — red on the wait, the read between the write and its
    /// report, the mark, the `.fault` and the re-assert of the old target. § 5 takes the gate
    /// after its control-state read — `cycle()` enters nothing, and `examine` enters and defers
    /// the leave just after the read. Run: red on "no read between the write and its report".
    @Test("A step written before § 5 reads, and reported after it arrived, is read reported")
    func aStepWrittenBeforeTheReadIsReadOnlyOnceReported() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 4_400)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let lease = try await Self.lease(machine)
        let permit = try standIn.permit()

        let pass = try #require(await standIn.enter())
        let written = try await standIn.write(4_000, of: permit)
        let afterTheWrite = await machine.attempts.count
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the examination to wait for the gate") {
                machine.gate.waiting(onFan: 0) == 1
            })
        #expect(
            await machine.attempts.dropFirst(afterTheWrite).contains(.readControlState(fan: 0))
                == false,
            "§ 5 read the fan between the step's write and its report")

        await standIn.report(written, under: lease)
        standIn.leave(pass)
        try await finished("the examination", sweep)

        #expect(
            await machine.attempts.dropFirst(afterTheWrite).contains(.readControlState(fan: 0)),
            "the examination never read the fan, so nothing here was judged")
        await Self.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_000], "§ 5 re-asserted the old target")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 4_000)
        #expect(machine.gate.isIdle)
    }

    /// A step under way when § 5's sweep reaches the fan — the gate taken, nothing yet written —
    /// is read after it lands. A gate taken after the read would judge a reading from before the
    /// step against the record the step left.
    ///
    /// **Mutation:** § 5 takes the gate after its control-state read, as above. Run: red on the
    /// mark, the `.fault` and the re-assert: the reading predates the step.
    @Test("A step under way when the examination begins is read after it lands")
    func aStepUnderWayIsReadAfterItLands() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 4_400)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let lease = try await Self.lease(machine)
        let permit = try standIn.permit()

        let pass = try #require(await standIn.enter())
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the examination to wait for the gate") {
                machine.gate.waiting(onFan: 0) == 1
            })
        await standIn.report(try await standIn.write(4_000, of: permit), under: lease)
        standIn.leave(pass)
        try await finished("the examination", sweep)

        await Self.expectNotJudgedAReclamation(machine)
        #expect(await machine.commandedRPMs == [4_000])
        #expect(machine.gate.isIdle)
    }

    // MARK: - Each fan's own gate

    /// **§ 5 waits on the gate of the fan it examines.** Fans 0 and 1 are held at 2,400, and
    /// level 6 holds fan 1's gate. § 5's sweep examines fan 0, whose gate is free, then waits on
    /// fan 1's: not on fan 0's, and without reading fan 1 until the step leaves. Keyed to another
    /// fan, § 5 would examine fan 1 inside fan 1's own step: #383's false reclamation, on every fan
    /// but the one it keyed to.
    ///
    /// **Mutation:** `cycle()` enters `gate.enterForExamination(fanAt: 0)` whatever the fan. Run:
    /// red on the wait for fan 1's gate, and on the read of fan 1 inside the step.
    @Test("§ 5 waits on the gate of the fan it examines, and on no other fan's")
    func eachExaminationWaitsOnItsOwnFansGate() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 4_400), 1: .held(at: 4_400)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        try await machine.hold(fan: 1, commanding: 4_400)
        let stepOnFanOne = try #require(await standIn.enter(fanAt: 1))
        let beforeTheSweep = await machine.attempts.count

        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("§ 5 to wait on fan 1's gate") { machine.gate.waiting(onFan: 1) == 1 },
            "§ 5 did not wait on the gate of the fan it was examining")
        #expect(machine.gate.waiting(onFan: 0) == 0, "§ 5 waited on fan 0's gate")
        #expect(machine.gate.isHeld(fanAt: 0) == false, "§ 5 kept fan 0's gate after examining it")
        let duringTheStep = await machine.attempts.dropFirst(beforeTheSweep)
        #expect(duringTheStep.contains(.readControlState(fan: 0)), "fan 0 was not examined first")
        #expect(
            duringTheStep.contains(.readControlState(fan: 1)) == false,
            "§ 5 read fan 1 inside the step that held fan 1's gate")

        standIn.leave(stepOnFanOne)
        try await finished("the sweep", sweep)
        #expect(
            await machine.attempts.dropFirst(beforeTheSweep).contains(.readControlState(fan: 1)),
            "fan 1 was never examined, so nothing here was judged")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
        #expect(await machine.ledger.isReclaimed(fanAt: 1) == false)
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 wrote to a fan holding its target")
        #expect(machine.gate.isIdle)
    }

    // MARK: - The gate before the stamp

    /// **The gate, then the stamp.** Fan 0 is held under L at 2,400 and the system has taken it
    /// back: it reads automatic. Level 6 holds the gate when § 5's sweep reaches the fan, and
    /// registers it again under L, as A6's item 2 does for a fan it believes engaged, then leaves.
    /// The registration is before the examination, so § 5 judges a reading that includes it and
    /// re-engages the fan: nothing stands its re-assert down.
    ///
    /// **Mutation:** stamp first — `cycle()` calls `registry.beginExamination(ofFan: index,
    /// inBound: true)` before entering the gate, and `examine` reads the lease from the record
    /// without stamping. Run: red on the stand-down line, the re-engage and the command.
    @Test("§ 5 takes the gate before it stamps, so a step's registration is not inside it")
    func theGateIsTakenBeforeTheStamp() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 4_400)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let lease = try await Self.lease(machine)
        let permit = try standIn.permit()

        let pass = try #require(await standIn.enter())
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the examination to wait for the gate") {
                machine.gate.waiting(onFan: 0) == 1
            })
        try await standIn.register(permit, under: lease)
        standIn.leave(pass)
        try await finished("the examination", sweep)

        #expect(
            machine.safetyLog.lines(containing: Self.leftToItsEngagement).isEmpty,
            "a registration made before the examination stood its re-assert down")
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(await machine.commandedRPMs == [4_400], "§ 5 did not re-assert the reclaimed fan")
    }

    // MARK: - Past the bound

    /// **Past the bound, a divergence marks the fan and writes nothing away from automatic
    /// control.** Fan 0 is held at 2,400
    /// while the firmware holds 1,800, and level 6 holds the gate and never leaves. § 5 waits
    /// `examinationWait`, then examines without the gate: it judges, marks and reports, and its
    /// re-assert stands down, attempt spent. The next cycles do not wait at all, and when the
    /// budget is spent the terminal action restores the fan: every restore still happens. § 5
    /// writes nothing away from automatic control throughout.
    ///
    /// **Mutation:** ignore the stamp — drop `record.examinedInBound` from
    /// `Registry.reassertTarget(ofFan:under:)`. Run: red on the writes, the stand-down line and
    /// the terminal action, which the re-asserts postpone.
    @Test("Past the gate's bound, § 5 marks a diverged fan and writes nothing away from automatic")
    func pastTheBoundADivergenceMarksAndWritesNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let stuck = try #require(await standIn.enter())

        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the examination's timer") { machine.gateClock.sleepers == 1 })
        machine.gateClock.advance(by: FanExaminationGate.examinationWait)
        try await finished("the examination past the bound", sweep)

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the judgement did not happen")
        #expect(machine.safetyLog.levels(containing: Self.detected) == [.fault])
        #expect(machine.safetyLog.lines(containing: Self.ungatedStandDown).count == 1)
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 wrote without the gate")
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(
            machine.safetyLog.levels(containing: "examination gate, and its holder") == [.fault])

        for cycle in 1..<ReclamationLimits.reassertAttemptBudget {
            try await finished(
                "cycle \(cycle) after the expiry", observing { await machine.watchdog.cycle() })
        }
        #expect(
            machine.safetyLog.lines(containing: Self.ungatedStandDown).count
                == ReclamationLimits.reassertAttemptBudget,
            "a later cycle waited on the outwaited holder, or wrote")
        #expect(await machine.didRestore(fan: 0) == false)

        try await finished("the terminal cycle", observing { await machine.watchdog.cycle() })
        #expect(
            await machine.didRestore(fan: 0), "the terminal action did not restore past the bound")
        #expect(await machine.restorer.causes.contains(.systemReclaimed))
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 wrote without the gate")
        #expect(machine.safetyLog.lines(containing: "examination gate, and its holder").count == 1)
        standIn.leave(stuck)
        #expect(machine.gate.isIdle)
    }

    /// **A cancelled wait is not an expiry.** Fan 0 is reclaimed while level 6 holds the gate, and
    /// each of `reassertAttemptBudget` sweeps is cancelled while it waits, as `stop()` cancels.
    /// Each returns at once without the gate, is not stood down, and reaches the re-assert's
    /// cancellation guard, which refunds the attempt (#144). Once level 6 leaves, the first real
    /// sweep re-engages the fan with its whole budget.
    ///
    /// **Mutation:** take a cancelled wait for an expiry — `cycle()` passes `inBound: pass.isHeld`.
    /// Run: red on the cancellation lines, the stand-down lines and the re-engage; the budget is
    /// spent and the real sweep gives the fan up.
    @Test("A cancelled wait for the gate still refunds the re-assert's attempt")
    func aCancelledWaitStillRefundsTheAttempt() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let standIn = LevelSixStandIn(machine)
        try await machine.hold(fan: 0, commanding: 4_400)
        let holder = try #require(await standIn.enter())

        for round in 1...ReclamationLimits.reassertAttemptBudget {
            let sweep = observing { await machine.watchdog.cycle() }
            #expect(
                await yieldUntil("sweep \(round) to wait for the gate") {
                    machine.gate.waiting(onFan: 0) == 1
                })
            sweep.task.cancel()
            try await finished("cancelled sweep \(round)", sweep)
        }
        #expect(
            machine.safetyLog.lines(containing: Self.abandoned).count
                == ReclamationLimits.reassertAttemptBudget,
            "a cancelled wait did not reach the cancellation guard")
        #expect(machine.safetyLog.lines(containing: Self.ungatedStandDown).isEmpty)
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)

        standIn.leave(holder)
        try await finished("the first real sweep", observing { await machine.watchdog.cycle() })
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)),
            "the budget went on waits that wrote nothing, so § 5 gave fan 0 up")
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 4400 RPM, attempt 1 of").count == 1)
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(machine.gate.isIdle)
    }
}
