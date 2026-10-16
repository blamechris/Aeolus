import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The two registrations the generation lets through, and what
/// `docs/records/reclamation-watchdog.md` relies on for both (#365, from the panel on #361): each
/// is **handed back as `.leaseLapsed` on the next examination**.
///
/// The generation refuses a registration whose answer is stale because the fan moved on: a
/// release notice, another registration, or the terminal action's entry. It does not refuse one
/// whose lease simply ended with nobody told, so such a registration is accepted and records the
/// fan under a lease the lease core no longer holds. Nothing is overwritten, because any other
/// lease's registration would have moved the generation. These tests pin what makes that safe:
/// the next examination asks the record's own lease, finds it not live, and restores the fan.
///
/// Both pin a residual, as `ReclamationWatchdogStalenessTests`' test of a lease lapsing during
/// the re-assert does: the acceptance is asserted too, so closing the residual turns them red,
/// and the record is updated rather than left claiming something that is no longer true.
extension ReclamationLeaseIdentityTests {

    /// **An unannounced end.** L1's registration is told L1 is live and parked. L1 then ends with
    /// no release notice and no re-grant, so nothing moves the generation and the stale `true` is
    /// accepted: fan 0 is recorded under a lease that has ended. The next cycle hands it back,
    /// and does not blame the system for a lease ending.
    ///
    /// **Mutation:** delete the `guard entitled` block from `examine(fanAt:)`. Run: red on the
    /// second cycle's restore, registry and log assertions — nothing else revisits a fan that
    /// reads converged.
    @Test("A registration accepted after an unannounced lease end is handed back as lapsed")
    func aRegistrationAcceptedAfterAnUnannouncedLeaseEndIsHandedBack() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_000)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let ended = try await machine.lease()
        let permit = try Self.permit(machine)
        await hops.parkNextAnswer()
        let late = observing {
            try await machine.watchdog.manualControlEngaged(permit, under: ended.id)
        }
        #expect(await yieldUntil("the registration's lease answer to park") { await hops.isParked })

        await machine.endLease()
        await hops.release()
        try await finished("the late registration", late)

        #expect(await hops.answers.first == true, "the parked answer was not the true one")
        #expect(
            await machine.watchdog.fansUnderManualControl == [0],
            "the residual this test bounds is gone: update the record, then this test")
        #expect(await machine.didRestore(fan: 0) == false)

        await machine.watchdog.cycle()

        #expect(
            await machine.didRestore(fan: 0),
            "a fan registered under a lease that had ended was never handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).count == 1)
        #expect(await machine.restorer.causes.contains(.systemReclaimed) == false)
        #expect(await machine.ledger.causes.isEmpty)
    }

    /// **An acceptance after the terminal action returned.** Fan 0 is held under L1 and reads
    /// automatic with nothing commanded, so its third cycle is the terminal action. Inside the
    /// hand-back a re-apply under L1 begins: it reads the generation after the entry moved it,
    /// is told L1 is live — it still is, the revocation is a step away — and parks. The terminal
    /// action finishes and revokes L1, `finalising` closes, and the re-apply resumes: nothing
    /// refuses it any more, so it is accepted, and fan 0 is recorded under a lease that was
    /// revoked. The next cycle hands it back, as `.leaseLapsed`.
    ///
    /// The case `aRegistrationInFlightAtTheTerminalActionClearsNothing` does not reach: that one's
    /// answer was read *before* the entry, so the entry's bump refuses it.
    ///
    /// **Mutation:** delete the `guard entitled` block from `examine(fanAt:)`. Run: red on the
    /// second restore, the registry and the lapsed line.
    @Test("A registration accepted after the terminal action returned is handed back as lapsed")
    func aRegistrationAcceptedAfterTheTerminalActionIsHandedBack() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 2_400)], interfering: sensing,
            parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        try await machine.holdWithoutCommanding(fan: 0)
        let held = try await Self.activeLease(machine)
        let permit = try Self.permit(machine)
        let reapply = ReapplyBox()
        await sensing.interfere {
            await hops.parkNextAnswer()
            await reapply.keep(
                observing { try await machine.watchdog.manualControlEngaged(permit, under: held) })
            await yieldUntil("the re-apply's lease answer to park") { await hops.isParked }
        }

        for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            await machine.watchdog.cycle()
        }

        #expect(await sensing.didFire, "the terminal action's hand-back never reached the seam")
        #expect(machine.safetyLog.lines(containing: "no speed to re-assert").count == 1)
        #expect(await machine.restorer.causes == [.systemReclaimed], "L1 was not revoked")
        #expect(await machine.leases.leaseCount == 0)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        let restoresBefore = await machine.restoreCount(fan: 0)
        let work = try #require(await reapply.work, "the re-apply never began")

        await hops.release()
        try await finished("the re-apply's registration", work)

        #expect(
            await machine.watchdog.fansUnderManualControl == [0],
            "the residual this test bounds is gone: update the record, then this test")

        await machine.watchdog.cycle()

        #expect(
            await machine.restoreCount(fan: 0) == restoresBefore + 1,
            "a fan registered after the terminal action returned was never handed back")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).count == 1)
        #expect(await machine.restorer.causes == [.systemReclaimed], "a lease was revoked again")
    }
}

/// The task a scenario started inside an interference effect, kept for the test body to join.
actor ReapplyBox {
    private(set) var work: ObservableWork<Void>?

    func keep(_ work: ObservableWork<Void>) { self.work = work }
}

extension ReclamationMachine {

    /// How many times this fan was restored to automatic control.
    func restoreCount(fan index: Int) async -> Int {
        await plane.attempts.filter { $0 == .restoreToAutomatic(.fan(index)) }.count
    }
}
