import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The identity half of the two re-fetches in `diverged(_:fanAt:heldUnder:)` that #365 could not
/// reach: the precedence check after the latch hop, and the reclamation report after the ledger
/// hop ([#380](https://github.com/blamechris/Aeolus/issues/380)).
///
/// Both hops are on actors § 5 now holds through roles, `ThermalLatchRole` and
/// `ReclamationLedgerRole`, as it holds the lease core through `HeldLeaseRole`. The machine's
/// `parkingSafetyHops` puts `ParkableThermalLatch` and `ParkableReclamationLedger` behind them,
/// each of which answers from the real actor and then holds the hop open on a continuation. A
/// newer lease's registration lands between that actor answering and § 5 resuming, with no race
/// (#109) and no pool thread blocked (#344). `ReclamationRefetchIdentityTests.swift` lists every
/// re-fetch against its test, these two included.
extension ReclamationLeaseIdentityTests {

    /// **The precedence check.** Fan 0 is held under L1 at 2,400 RPM while the firmware holds
    /// 1,800, so the cycle diverges and `diverged` asks the latch. Its answer, clear, is held open
    /// while a newer lease registers fan 0 and commands 2,000 of its own. § 5 stops at the
    /// precedence check, before the ledger hop: it does not mark the newer lease's fan reclaimed.
    ///
    /// Both arrivals reach the same guard here, because nothing between the latch hop and the
    /// mark asks the lease core: `granted` is the shipping order and `vouched` keeps L1 live in
    /// the lease core while § 5's role answers for the newer lease.
    ///
    /// **Mutation:** make the re-fetch after `currentRuling()` in `diverged` check presence only —
    /// `guard registry.record(ofFan: index) != nil, let fan = registry.record(ofFan: index)`.
    /// Run: red on the precedence-check line, the `markReclaimed` call, and the ledger: the newer
    /// lease's fan is marked `.systemReclaimed`.
    @Test(
        "A record registered under a new lease during the precedence check is left to it",
        arguments: NewerLease.allCases)
    func aRecordRegisteredUnderANewLeaseDuringThePrecedenceCheckIsLeftToIt(
        how: NewerLease
    ) async throws {
        let machine = ReclamationMachine(
            fans: [0: .held(at: 1_800)], parkingLeaseHops: true, parkingSafetyHops: true)
        let latchHops = try #require(machine.latchHops)
        let ledgerHops = try #require(machine.ledgerHops)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        let granted = GrantedLeases()
        await latchHops.parkNextAnswer()
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the precedence check's latch answer to park") {
                await latchHops.isParked
            })

        await Self.arrive(how, machine: machine, permit: permit, granted: granted)
        await latchHops.release()
        try await finished("the examination", sweep)

        #expect(
            await latchHops.answers == [false],
            "the parked answer was not the precedence check's, or § 3 had latched")
        #expect(await granted.ids.count == 1)
        #expect(
            machine.safetyLog.lines(containing: "during the precedence check").count == 1,
            "the examination went past the precedence check")
        #expect(
            await ledgerHops.calls.contains { $0.hop == .markReclaimed } == false,
            "§ 5 went on to mark the newer lease's fan")
        #expect(await machine.commandedRPMs.isEmpty, "§ 5 re-asserted the old lease's target")
        await Self.expectNewerLeaseUntouched(machine)
    }

    /// **The reclamation report.** The firmware discards every write, so L1's first two divergent
    /// cycles re-assert 2,400 RPM and spend two of its three attempts. On the third, the
    /// `markReclaimed` hop is held open with the mark landed, and L1 ends, L2 is granted, and L2
    /// registers fan 0 and commands 2,000 of its own. § 5 stops at the reclamation report, so
    /// L2's record keeps its own budget and L2's first divergence is re-asserted as its first
    /// attempt.
    ///
    /// A presence-only re-fetch acts on the copy of L1's record `diverged` took before the hop:
    /// it books L1's third attempt onto L2's record, then the re-assert stops at its envelope
    /// read (#381's identity), so nothing is written and the attempt is the harm. L2's first
    /// divergence finds the budget spent and goes to the terminal action, revoking L2 as
    /// `.systemReclaimed` for a contest it never had.
    ///
    /// `granted` only. The follow-up cycle re-asserts for L2, and the engagement driver asks the
    /// real lease core about L2 before it commands, which a vouched lease is not in.
    ///
    /// **Mutation:** make the re-fetch after `ledger.markReclaimed` in `diverged` check presence
    /// only — `guard registry.record(ofFan: index) != nil`. Run: red on the reclamation-report
    /// line and the envelope-read line, and on L2's follow-up cycle: no attempt-1 re-assert, the
    /// budget fault, and L2 revoked as `.systemReclaimed`.
    @Test("A record registered under a new lease during the reclamation report is left to it")
    func aRecordRegisteredUnderANewLeaseDuringTheReclamationReportIsLeftToIt() async throws {
        let budget = ReclamationLimits.reassertAttemptBudget
        let setupCycles = budget - 1
        let machine = ReclamationMachine(
            stages: [.nominal(writes: .reverted)], fans: [0: .held(at: 1_800)],
            parkingSafetyHops: true)
        let ledgerHops = try #require(machine.ledgerHops)
        try await machine.hold(fan: 0, commanding: 2_400)
        let permit = try Self.permit(machine)
        for _ in 0..<setupCycles { await machine.watchdog.cycle() }
        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2400 RPM").count == setupCycles,
            "the setup did not spend all but one of L1's attempts")
        let granted = GrantedLeases()
        await ledgerHops.parkNext(.markReclaimed)
        let sweep = observing { await machine.watchdog.cycle() }
        #expect(
            await yieldUntil("the reclamation report's ledger hop to park") {
                await ledgerHops.isParked
            })

        await Self.arrive(.granted, machine: machine, permit: permit, granted: granted)
        await ledgerHops.release()
        try await finished("the examination", sweep)

        let next = try #require(await granted.ids.first)
        #expect(
            await ledgerHops.calls.filter { $0.hop == .markReclaimed }.count == setupCycles + 1,
            "the parked call was not this cycle's mark")
        #expect(
            machine.safetyLog.lines(containing: "during the reclamation report").count == 1,
            "the examination went past the reclamation report")
        #expect(
            machine.safetyLog.lines(containing: "during its envelope read").isEmpty,
            "the old lease's copy of the record went on to a re-assert")
        #expect(await machine.commandedRPMs == Array(repeating: 2_400, count: setupCycles))
        await Self.expectNewerLeaseUntouched(machine)

        await machine.watchdog.cycle()

        #expect(
            machine.safetyLog.lines(containing: "re-asserted 2000 RPM, attempt 1 of").count == 1,
            "L2's first divergence was not re-asserted as its first attempt")
        #expect(
            machine.safetyLog.faults.contains { $0.contains("budget") } == false,
            "the old lease's attempts were booked onto L2's record")
        #expect(await machine.leases.activeLease()?.id == next, "L2 was revoked")
        #expect(
            await machine.restorer.causes.contains(.systemReclaimed) == false,
            "L2 was revoked blaming the system")
    }
}
