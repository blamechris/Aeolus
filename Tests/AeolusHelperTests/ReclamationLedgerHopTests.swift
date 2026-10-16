import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What `diverged(_:fanAt:heldUnder:)` makes of a target reported under the record's own lease
/// during its `markReclaimed` hop, pinned as the code stands
/// ([#365](https://github.com/blamechris/Aeolus/issues/365)'s C1 note, through #380's seam).
///
/// `diverged` copies the record at the precedence check and reads the copy after the ledger hop.
/// The re-fetch after the hop asks only whether the record is still the same lease's, so a report
/// that lands in the hop reaches the record and not the copy. Two reads of the copy follow: whether
/// anything was ever commanded, and the attempt count. The second cannot move under the same lease
/// during the hop, since only the one sweep in flight judges, spends or refunds it (#144); a newer
/// lease's record is the identity guard's, in `ReclamationSafetyHopIdentityTests.swift`. The
/// re-assert's target is not read from the copy at all: since #381 it is the record's as it
/// stands after the envelope read.
///
/// **These pin today's behaviour, not the contract A6 wants.** The first case is the window A6's
/// plan calls a false terminal action: a holder's first command reported during the hop is not
/// seen, so the fan is given up and the lease revoked as `.systemReclaimed` though its holder had
/// just commanded it. It fails safe, since the fan goes back to automatic control, and the
/// account it gives is false. A6's first PR decides on the live record there and turns the first
/// case red on purpose; this suite is updated with it.
@Suite("§ 5 reads a report made during its ledger hop as the code stands", .timeLimit(.minutes(1)))
struct ReclamationLedgerHopTests {

    /// **A first command, unseen.** Fan 0 is registered under L1 with nothing commanded and reads
    /// automatic, so the cycle after the registration grace diverges. Its `markReclaimed` hop is
    /// held, and L1's holder reports its first command, 2,400 RPM. The record takes it and the copy
    /// does not, so § 5 finds no speed to re-assert and gives the fan up: hand-back, the mark kept,
    /// and L1 revoked as `.systemReclaimed`.
    ///
    /// **Mutation (the pin is live):** read the nothing-commanded check from the record instead of
    /// the copy — `guard registry.record(ofFan: index)?.commanded != nil`. Run: red on the
    /// no-speed line, the revocation and the lease count: the fan is re-engaged and commanded.
    @Test("A first command reported during the ledger hop is not seen, and the fan is given up")
    func aFirstCommandReportedDuringTheLedgerHopIsNotSeen() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 2_400)], parkingSafetyHops: true)
        let ledgerHops = try #require(machine.ledgerHops)
        try await machine.holdWithoutCommanding(fan: 0)
        let lease = try #require(await machine.leases.activeLease()).id
        for _ in 1..<ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }
        #expect(
            machine.safetyLog.lines(containing: "no speed to re-assert").isEmpty,
            "the registration grace ran out before the cycle this test holds")
        await ledgerHops.parkNext(.markReclaimed)
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the diverged cycle's ledger hop to park") {
                await ledgerHops.isParked
            })

        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_400), under: lease)
        #expect(
            await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400,
            "the report did not reach the record, so this is not the copy's window")
        await ledgerHops.release()
        try await finished("the examination", sweep)

        #expect(
            machine.safetyLog.lines(containing: "no speed to re-assert").count == 1,
            "the copy saw the first command: update this pin and the records with it")
        #expect(await machine.didRestore(fan: 0))
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.restorer.causes.contains(.systemReclaimed))
        #expect(await machine.leases.leaseCount == 0)
        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the terminal action keeps the mark")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **A newer target, written.** Fan 0 is held under L1 at 2,400 RPM while the firmware holds
    /// 1,800, so the cycle diverges. During its `markReclaimed` hop the holder reports 2,600. The
    /// copy still says 2,400, and the re-assert writes 2,600: the record's target as it stands
    /// after the envelope read (#381), not the copy's.
    ///
    /// **Mutation:** decide the re-assert's target on the copy taken before the hop — store
    /// `fan.commanded` in `diverged` before `ledger.markReclaimed`, and have `reassert` write that
    /// in place of `target.rpm`. Run: red on the commanded RPMs and the re-asserted line.
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
