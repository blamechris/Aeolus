import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Registrations that arrive late, across the generation (#365, from the panel on #361), and
/// what `docs/records/reclamation-watchdog.md` relies on for them.
///
/// The generation refuses a registration whose lease answer no longer describes the fan: a
/// release notice, another registration, or the terminal action's entry moved it. It does not
/// refuse one whose lease simply ended with nothing moving it, so that registration is accepted
/// and records the fan under a lease the lease core no longer holds. Nothing is overwritten,
/// because any other lease's registration would have moved the generation. What makes that safe
/// is the next examination, which asks the record's own lease, finds it not live, and restores
/// the fan as `.leaseLapsed`. One under the lease § 5's terminal action gave the fan up for is
/// refused whatever moved, by `givenUp` (#366).
///
/// ## Two of these tests are models, and the model is named
///
/// A release notice is a hint (ADR 0009 D2), and the shipping composition sends one for every
/// fan before every lease-core restore, including the one inside the terminal action's
/// revocation (`HelperFanRestorer`). `RecordingFanRestorer` sends none. So a test that ends a
/// lease through it, or lets the terminal action revoke through it, models a **lost** notice, and
/// says so. The shipping composition is the test that delivers the notice.
///
/// The unannounced-end test asserts the acceptance as well, as
/// `ReclamationWatchdogStalenessTests.aLeaseLapsingDuringTheReassertIsHandedBackNextCycle` does:
/// closing the residual turns it red, and the record is updated rather than left claiming
/// something that is no longer true. The terminal action's lost-notice model asserted it too
/// until #366 closed that residual, which turned it red as it was meant to; it now asserts the
/// refusal.
extension ReclamationLeaseIdentityTests {

    /// How the lease behind a parked registration ends with nothing moving the generation.
    enum UnannouncedEnd: Sendable, CaseIterable {
        /// Its deadline passes and nothing has swept it yet, which is the shipping route: the
        /// sweep, not a notice, ends a lease that lapses.
        case lapsed
        /// It ends through a restorer that sends § 5 no notice: a connection teardown whose
        /// notice was lost. The model of the other route, since the shipping teardown sends one.
        case noticeLost
    }

    /// **An unannounced end.** L1's registration is told L1 is live and parked. L1 then ends with
    /// no release notice and no re-grant, so nothing moves the generation and the stale `true` is
    /// accepted: fan 0 is recorded under a lease that has ended. The next cycle hands it back,
    /// and does not blame the system for a lease ending.
    ///
    /// **Mutation:** delete the `guard entitled` block from `examine(fanAt:)`. Run: red on the
    /// second cycle's restore, registry and log assertions — nothing else revisits a fan that
    /// reads converged.
    @Test(
        "A registration accepted after an unannounced lease end is handed back as lapsed",
        arguments: UnannouncedEnd.allCases)
    func aRegistrationAcceptedAfterAnUnannouncedLeaseEndIsHandedBack(
        end: UnannouncedEnd
    ) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_000)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let ended = try await machine.lease()
        let permit = try Self.permit(machine)
        await hops.parkNextAnswer()
        let late = observing {
            try await machine.watchdog.manualControlEngaged(permit, under: ended.id)
        }
        #expect(await yieldUntil("the registration's lease answer to park") { await hops.isParked })

        switch end {
        case .lapsed: machine.lapseLease()
        case .noticeLost: await machine.endLease()
        }
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

    // MARK: - A registration that begins during the terminal action's hand-back

    /// Fan 0 is held under L1 and reads automatic with nothing commanded, so its third cycle is
    /// the terminal action. Inside the hand-back a re-apply under L1 begins: it reads the
    /// generation after the entry moved it, is told L1 is live — it still is, the revocation is a
    /// step away — and parks. `beforeNextRevocation` is not armed here; each test arms what its
    /// composition does.
    struct ReapplyInTheHandBack {
        let machine: ReclamationMachine<InterferingFanStateSensing>
        let hops: ParkableHeldLeases
        let sensing: InterferingFanStateSensing
        let reapply: ReapplyBox
    }

    static func reapplyParkedInTheHandBack() async throws -> ReapplyInTheHandBack {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 2_400)])
        let sensing = InterferingFanStateSensing(plane, during: .restoreWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .automatic(at: 2_400)], interfering: sensing,
            parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        try await machine.holdWithoutCommanding(fan: 0)
        let held = try await activeLease(machine)
        let fan = try permit(machine)
        let reapply = ReapplyBox()
        await sensing.interfere {
            await hops.parkNextAnswer()
            await reapply.keep(
                observing { try await machine.watchdog.manualControlEngaged(fan, under: held) })
            await yieldUntil("the re-apply's lease answer to park") { await hops.isParked }
        }
        return ReapplyInTheHandBack(
            machine: machine, hops: hops, sensing: sensing, reapply: reapply)
    }

    /// Runs the three cycles that end in the terminal action, and checks it ran.
    static func expectTheTerminalActionRan(_ scene: ReapplyInTheHandBack) async {
        for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            await scene.machine.watchdog.cycle()
        }
        #expect(await scene.sensing.didFire, "the hand-back never reached the seam")
        #expect(scene.machine.safetyLog.lines(containing: "no speed to re-assert").count == 1)
        #expect(await scene.machine.restorer.causes.contains(.systemReclaimed), "L1 not revoked")
        #expect(await scene.machine.leases.leaseCount == 0)
    }

    /// **The shipping composition.** The revocation's restore sends § 5 the release notice before
    /// it restores (`HelperFanRestorer`), and `Registry.release(fanAt:)` always moves the
    /// generation. So a re-apply under L1 that began in the hand-back and resumes after the
    /// terminal action returned is refused, and the mark the terminal action keeps (#346) stays.
    /// Since #366 it is refused twice over: by the generation the notice moved, and by `givenUp`,
    /// which refuses L1 at this fan whatever notice was sent. The lost-notice model below is the
    /// case only `givenUp` refuses.
    ///
    /// `beforeNextRevocation` delivers the notice inside the revocation, as the restorer does.
    ///
    /// **Mutation:** delete the `registrations[index, default: 0] &+= 1` in
    /// `Registry.release(fanAt:)`, **and** drop `givenUp[index] != lease` from
    /// `Registry.register`'s refusal. Run: red on the refusal, the mark and the registry — the
    /// re-apply is accepted and clears the mark the terminal action kept. Either alone leaves this
    /// green, because the other refuses.
    @Test("A re-apply that began in the hand-back is refused once the revocation's notice is sent")
    func aReapplyThatBeganInTheHandBackIsRefusedAfterTheRevocationsNotice() async throws {
        let scene = try await Self.reapplyParkedInTheHandBack()
        let machine = scene.machine
        await scene.hops.beforeNextRevocation {
            await machine.watchdog.manualControlReleased(fanAt: 0)
        }

        await Self.expectTheTerminalActionRan(scene)
        let work = try #require(await scene.reapply.work, "the re-apply never began")
        await scene.hops.release()

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await finished("the re-apply's registration", work)
        }
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply resuming after the terminal action erased the mark it keeps")
        #expect(machine.safetyLog.lines(containing: "is no longer reported as taken").isEmpty)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.restorer.causes.filter { $0 == .systemReclaimed }.count == 1)
    }

    /// **The lost-notice model.** The same re-apply with the notice never sent, as
    /// `RecordingFanRestorer` never sends one. Nothing moved the generation after the re-apply
    /// read it and `finalising` has closed, and until #366 the registration was accepted: it
    /// recorded fan 0 under the lease the terminal action had revoked and erased the mark the
    /// terminal action keeps, and the next cycle handed the fan back as `.leaseLapsed`. The
    /// terminal action's entry now records the lease in `givenUp`, which nothing clears, so the
    /// registration is refused whenever it resumes and whatever notice was sent or lost. The mark
    /// stays, and there is no record left to hand back.
    ///
    /// **Mutations:** (a) clear `givenUp[index]` in `Registry.endFinalising(fanAt:)`; (b) put
    /// `finalising[index] != lease` back in place of `givenUp[index] != lease` in
    /// `Registry.register`'s guard. Run: red on the refusal, the mark, the "resolved" line and the
    /// registry, on each.
    @Test("A registration resuming after the terminal action, its notice lost, keeps the mark")
    func aRegistrationResumingAfterTheTerminalActionIsRefusedAndKeepsTheMark() async throws {
        let scene = try await Self.reapplyParkedInTheHandBack()
        let machine = scene.machine

        await Self.expectTheTerminalActionRan(scene)
        #expect(await machine.restorer.causes.filter { $0 == .systemReclaimed }.count == 1)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        let restoresBefore = await machine.restoreCount(fan: 0)
        let work = try #require(await scene.reapply.work, "the re-apply never began")

        await scene.hops.release()
        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await finished("the re-apply's registration", work)
        }

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a registration under the lease the terminal action gave up erased the mark it keeps")
        #expect(machine.safetyLog.lines(containing: "is no longer reported as taken").isEmpty)
        #expect(machine.safetyLog.lines(containing: "refused to register fan 0").count == 1)
        #expect(
            await machine.watchdog.fansUnderManualControl.isEmpty,
            "a registration under a revoked lease recorded the fan")

        await machine.watchdog.cycle()

        #expect(await machine.restoreCount(fan: 0) == restoresBefore)
        #expect(machine.safetyLog.lines(containing: leaseLapsedNotice).isEmpty)
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.restorer.causes.filter { $0 == .systemReclaimed }.count == 1)
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
