import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The orderly teardown with level 6's `apply` in flight (ADR 0014's A6 PR-3 amendment, #410).
///
/// `SignalTeardown`'s control gate refuses an `apply` that arrives once it is closed, through the
/// authority's shutdown refusal, and covers nothing already in flight. Both halves are here: the
/// refusal on arrival, and the residual an `apply` already past the gate leaves.
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

    // MARK: - Flight: ruling D19's residual, which level 6 inherits

    /// **Residual (#410).** A teardown that begins while an `apply` is mid-engagement, after the
    /// driver's entitlement and before the engagement's first step, does not stop that step. The
    /// step is admitted **after the teardown's final keystone**, and only the driver's after-check
    /// undoes it, once the teardown has already ended the process with `.restored`.
    ///
    /// The step is admitted because the plane records the restore epoch at an engagement's first
    /// step, so a restore requested before that step's turn does not supersede it (ADR 0009 D1's
    /// residual; `PlaneWriteLedger`, "What the epoch cannot see"). It writes `F<n>Md = 1`, and on
    /// the force-key path `Ftst = 1` too.
    ///
    /// **What this pins, and what it cannot show.** The seam parks the step past the recorded
    /// exit, so here the process lives on and the after-check's undo runs. In the daemon the exit
    /// is `exit()`:
    ///
    /// - on the naive path the undo races the exit;
    /// - on the force-key path the first step answers `.awaitingYield`, and the after-check waits
    ///   behind the driver's 100 ms poll sleep, which an exiting process does not outlive. So if
    ///   the step's writes land, `Ftst = 1` is in practice left set, with exit code 0.
    ///
    /// Nothing outside the process reconciles that: exit 0 means launchd does not restart the
    /// helper, and a bootout or an uninstall restarts nothing. This is the residual ruling D19 on
    /// [#197](https://github.com/blamechris/Aeolus/pull/197) accepts for § 5's re-assert
    /// (`SignalTeardown`'s step 5; `docs/SAFETY.md` § 6), and its acceptance does not extend to a
    /// plane that can write. The fix is #410's items 1 and 1a: a `.forExit` restore scope that
    /// seals the plane against every forward write, steps and commands, from every writer, and an
    /// engagement ticket taken before the entitlement, so a first step admitted after a restore
    /// request is refused before it writes. They land on `main` with item 1b, a test of the seal's
    /// command half, before B1's first `.built` commit. When they do, this test inverts.
    ///
    /// **Mutation:** in `EngagementDriver.engageManualControl(of:)`, delete the undo's
    /// `try await handBack(fanAt: index)`. Run: red for both paths, the fan left in manual and, on
    /// the force-key path, `Ftst = 1` left set. **Mutation:** delete the after-check
    /// `try await requireEntitlement(for: fan)` after § 3's registration. Run: red on the naive
    /// path, at the driver's refusal line: the undo is then `LeaseApplier`'s, not the
    /// after-check's.
    @Test(
        "Residual (#410): a step admitted after the final keystone is undone by its after-check",
        arguments: [
            ScriptedControlPlane.UnlockBehaviour.naive, .heldUntilForced(stepsToYield: 2),
        ])
    func anEngagementAdmittedAfterTheFinalKeystoneIsUndoneOnlyByItsAfterCheck(
        unlock: ScriptedControlPlane.UnlockBehaviour
    ) async throws {
        let machine = await LevelSixMachine(unlock: unlock)
        let lease = try await machine.lease()
        let atExit = KeyWritesAtExit()
        await machine.writes.interfere(beforeEngageStep: 1) {
            await machine.helper.signalTeardown.run(stoppingSupervisorsWith: {
                await machine.helper.shutDown()
            })
            await atExit.record(await machine.firmware.keyWrites)
        }

        let answer = await LevelSixMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        let beforeExit = await atExit.writes
        let afterExit = Array(await machine.firmware.keyWrites.dropFirst(beforeExit.count))
        let forced = unlock != .naive
        #expect(await machine.writes.didFire, "the teardown never ran inside the engagement")
        #expect(machine.journal.exitsNow == [.restored], "the teardown did not end the process")
        #expect(
            beforeExit.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)],
            "the final keystone's writes are not the last before the exit: \(beforeExit)")
        #expect(
            afterExit
                == (forced
                    ? [
                        .mode(fan: 0, value: 1), .forceKey(1), .mode(fan: 0, value: 0),
                        .forceKey(0),
                    ]
                    : [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)]),
            """
            after the recorded exit the firmware received \(afterExit). The residual is a first \
            step admitted after the final keystone, then the after-check's undo.
            """)
        #expect(try await machine.firmware.firmwareMode(ofFan: 0) == .automatic)
        #expect(machine.firmware.ledger.isForceKeySet == false, "the force key was left set")
        #expect(
            machine.lines.lines(containing: "The engagement of fan 0 was refused after").count == 1
                && machine.lines.lines(containing: "handed back, and the restore landed").count
                    == 1,
            "the undo was not the driver's after-check: \(machine.lines.lines)")
        #expect(answer == .leaseUnknown, "the apply was answered \(String(describing: answer))")
    }
}

/// The firmware's key writes at the instant the teardown returned, which is after its recorded
/// exit and before the parked step resumes.
actor KeyWritesAtExit {
    private(set) var writes: [ScriptedControlPlane.KeyWrite] = []

    func record(_ writes: [ScriptedControlPlane.KeyWrite]) { self.writes = writes }
}
