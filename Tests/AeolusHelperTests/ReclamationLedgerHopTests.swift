import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What `diverged(_:fanAt:heldUnder:)` makes of a target reported under the record's own lease
/// during its `markReclaimed` hop ([#365](https://github.com/blamechris/Aeolus/issues/365)'s C1
/// note, through #380's seam, and #383's ledger-hop window).
///
/// `diverged` judges the record it re-fetched at the precedence check, and decides on the record
/// it re-fetches after the ledger hop: whether anything was ever commanded, and the attempt count.
/// Until A6's gate it decided on the copy taken before the hop, so a holder's first command
/// reported in the hop was not seen, and the fan was given up and the lease revoked as
/// `.systemReclaimed` though its holder had just commanded it — the first case below pinned that
/// as a defect (#383). Now the hop cannot hold a step at all while § 5 holds the gate: level 6's
/// step waits for it. Past the gate's bound one can land there, and the live record sees it. The
/// re-assert's target is not read from either: since #381 it is the record's as it stands after
/// the envelope read. A newer lease's record is the identity guard's, in
/// `ReclamationSafetyHopIdentityTests.swift`.
@Suite("§ 5 decides on the record as it stands after its ledger hop", .timeLimit(.minutes(1)))
struct ReclamationLedgerHopTests {

    /// Fan 0 registered under its lease with nothing commanded, reading automatic, and cycled to
    /// the last cycle of its registration grace: the next one diverges into the ledger hop.
    static func atTheEndOfTheGrace(
        _ machine: ReclamationMachine<ScriptedControlPlane>
    ) async throws -> UUID {
        try await machine.holdWithoutCommanding(fan: 0)
        let lease = try #require(await machine.leases.activeLease()).id
        for _ in 1..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }
        #expect(
            machine.safetyLog.lines(containing: "no speed to re-assert").isEmpty,
            "the registration grace ran out before the cycle this test holds")
        return lease
    }

    /// **A first command waits for the gate** (#383's ledger-hop window, flipped from its pin).
    /// Fan 0 is at the end of its registration grace, reading automatic, and the diverged cycle's
    /// `markReclaimed` hop is held. Level 6 steps to 2,400 then: it waits for the gate, so nothing
    /// is reported in the hop and § 5 decides on a record that has, truly, nothing commanded — the
    /// grace's own outcome, not one decided on a copy the step had overtaken. Granted once § 5
    /// leaves, the step finds its lease revoked and writes nothing.
    ///
    /// **Mutation:** drop the gate — `cycle()` calls `examine(fanAt: index, gated: true)` and
    /// enters nothing. Run: red on the wait, the record during the hop and the no-speed line: the
    /// step lands in the hop and § 5 re-asserts it.
    @Test("A first command attempted during the ledger hop waits for the gate")
    func aFirstCommandDuringTheLedgerHopWaitsForTheGate() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 2_400)], parkingSafetyHops: true)
        let ledgerHops = try #require(machine.ledgerHops)
        let standIn = LevelSixStandIn(machine)
        let lease = try await Self.atTheEndOfTheGrace(machine)
        let permit = try standIn.permit()
        await ledgerHops.parkNext(.markReclaimed)
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the diverged cycle's ledger hop to park") {
                await ledgerHops.isParked
            })

        let step = observing { try await standIn.step(to: 2_400, of: permit, under: lease) }
        #expect(
            await yieldUntil("the step to wait for the gate") {
                machine.gate.waiting(onFan: 0) == 1
            })
        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0) == nil,
            "a step was reported inside the examination's ledger hop")
        await ledgerHops.release()
        try await finished("the examination", sweep)
        let written = try await finished("the step", step)

        #expect(
            machine.safetyLog.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 did not decide on the record nothing had been reported to")
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.restorer.causes.contains(.systemReclaimed))
        #expect(await machine.leases.leaseCount == 0)
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the terminal action keeps the mark")
        #expect(written == .some(nil), "the step wrote under a lease the terminal action revoked")
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.gate.isIdle)
    }

    /// **Past the bound, no terminal action from a stale copy.** As above, but level 6 holds the
    /// gate and never leaves, so § 5 examines without it, and level 6 reports its first command,
    /// 2,400, in the hop. § 5 decides on the live record: a speed was commanded, so it re-asserts
    /// rather than giving the fan up, and the ungated re-assert stands down, attempt spent. No
    /// restore, no revocation, and § 5 writes nothing.
    ///
    /// **Mutation (a):** decide on the copy taken before the hop — `guard judged.commanded != nil`
    /// in `diverged`. Run: red on the no-speed line, the restore, the revocation and the record.
    /// **(b):** ignore the stamp — drop `record.examinedGated` from `reassertTarget(ofFan:under:)`.
    /// Run: red on the re-engage and the stand-down line.
    @Test("Past the gate's bound, a first command reported in the hop is decided on, not given up")
    func pastTheBoundAFirstCommandInTheHopIsSeen() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 2_400)], parkingSafetyHops: true)
        let ledgerHops = try #require(machine.ledgerHops)
        let standIn = LevelSixStandIn(machine)
        let lease = try await Self.atTheEndOfTheGrace(machine)
        let permit = try standIn.permit()
        let stuck = try #require(await standIn.enter())
        await ledgerHops.parkNext(.markReclaimed)
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(await yieldUntil("the examination's timer") { machine.gateClock.sleepers == 1 })
        machine.gateClock.advance(by: FanExaminationGate.examinationWait)
        #expect(
            await yieldUntil("the ungated cycle's ledger hop to park") {
                await ledgerHops.isParked
            })

        await standIn.report(try await standIn.write(2_400, of: permit), under: lease)
        await ledgerHops.release()
        try await finished("the examination", sweep)

        #expect(
            machine.safetyLog.lines(containing: "no speed to re-assert").isEmpty,
            "§ 5 gave the fan up on the copy taken before the hop")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.restorer.causes.isEmpty, "a lease was revoked")
        #expect(await machine.leases.leaseCount == 1)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
        #expect(
            machine.safetyLog.lines(
                containing: ReclamationExaminationGateTests.ungatedStandDown
            ).count == 1)
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(await machine.commandedRPMs == [2_400], "§ 5 wrote without the gate")
        #expect(await machine.watchdog.fansUnderManualControl == [0])
        standIn.leave(stuck)
    }

    /// **A newer target, written.** Fan 0 is held under L1 at 2,400 RPM while the firmware holds
    /// 1,800, so the cycle diverges. During its `markReclaimed` hop the holder reports 2,600,
    /// without the gate: a write that bypasses it, which the gate cannot stop and the re-fetches
    /// still answer. The copy still says 2,400, and the re-assert writes 2,600: the record's
    /// target as it stands after the envelope read (#381), not the copy's.
    ///
    /// **Mutation:** decide the re-assert's target on the copy taken before the hop — store
    /// `judged.commanded` in `diverged` before `ledger.markReclaimed`, and have `reassert` write
    /// that in place of `target.rpm`. Run: red on the commanded RPMs and the re-asserted line.
    @Test("A target reported during the ledger hop is the one the re-assert writes")
    func aTargetReportedDuringTheLedgerHopIsTheOneTheReassertWrites() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)], parkingSafetyHops: true)
        let ledgerHops = try #require(machine.ledgerHops)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id
        await ledgerHops.parkNext(.markReclaimed)
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the diverged cycle's ledger hop to park") {
                await ledgerHops.isParked
            })

        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_600), under: lease)
        await ledgerHops.release()
        try await finished("the examination", sweep)

        #expect(
            await machine.commandedRPMs == [2_600],
            "the re-assert wrote the copy's target, not the one reported during the hop")
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2600 RPM, attempt 1 of").count == 1)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_600)
        #expect(machine.safetyLog.lines(containing: "left fan 0 alone").isEmpty)
        #expect(await machine.restorer.causes.isEmpty, "a lease was revoked")
    }
}
