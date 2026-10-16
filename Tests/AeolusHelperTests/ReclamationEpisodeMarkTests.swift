import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's `.systemReclaimed` mark around a re-assert
/// ([#366](https://github.com/blamechris/Aeolus/issues/366)): what `FanState.isReclaimedBySystem`
/// says from the cycle § 5 judges a fan diverged to the cycle it reads the target held, or gives
/// the fan up.
///
/// Two rules, each red at `main` before #366:
///
/// - **The mark follows the primary signal.** Every readable cycle whose primary signal converges
///   clears it, `.short` included: reaching the secondary signal means the firmware holds Aeolus's
///   target (#119). Only a cycle converged on both signals used to, so a re-asserted fan still
///   ramping to its target was reported reclaimed for the whole ramp, and for good if it could
///   not reach it.
/// - **A same-lease re-apply mid-episode leaves the mark to the episode.** `HeldFan.judge(_:)`
///   opens the episode on every `.diverged`, before the mark reaches the ledger, and closes it on
///   the next cycle whose primary converges. A registration under the record's own lease while it
///   is open is accepted and clears nothing. It used to clear the mark, and a terminal action that
///   followed gave the fan up with no mark left.
///
/// The value half — `episodeInFlight`, and what
/// `Registration.accepted(replacedEndedLease:mayClearTheMark:)` answers — is
/// `ReclamationRegistryTests`. Every test names the mutation it kills, and each was run.
@Suite(
    "§ 5's reclamation mark follows the primary signal, and its episode", .timeLimit(.minutes(1)))
struct ReclamationEpisodeMarkTests {

    /// What `reclamationResolved(fan:)` says when a mark is cleared.
    private static let resolved = "is no longer reported as taken"

    /// What `reclamationMarkLeftToItsEpisode(fan:)` says.
    private static let leftToItsEpisode = "while § 5 is contesting a reclamation of it"

    // MARK: - A re-apply mid-episode

    /// **Demo A.** Fan 0 is commanded 2,400 RPM under L1 and reads automatic, so § 5 marks it
    /// reclaimed and re-asserts. While the re-assert reads the envelope, the holder re-applies
    /// under L1: still live, nothing moved the generation, so the registration is accepted. Then
    /// the envelope fails, which is the terminal action, and it gives the fan up as
    /// `.systemReclaimed`. The mark it keeps (#346) must be there: the re-apply left it to the
    /// episode. Both ways the envelope can fail reach the terminal action.
    ///
    /// **Mutations**, each red on the mark, the "resolved" line and the notice, in both cases:
    /// (a) delete `guard mayClearTheMark else { … }` from `manualControlEngaged(_:under:)`, so the
    /// actor always clears; (b) make `Registry.register` answer `mayClearTheMark: true` always;
    /// (c) delete `episodeInFlight = true` from `HeldFan.judge(_:)`.
    @Test(
        "A same-lease re-apply during the re-assert leaves the mark to the terminal action",
        arguments: ReclamationLeaseIdentityTests.EnvelopeFailure.allCases)
    func aReapplyDuringTheReassertLeavesTheMarkToTheTerminalAction(
        failure: ReclamationLeaseIdentityTests.EnvelopeFailure
    ) async throws {
        let condition: ScriptedControlPlane.FanCondition =
            failure == .implausibleBounds
            ? .init(
                mode: .automatic, targetRPM: 1_800, actualRPM: 1_800,
                minimumRPM: 5_777, maximumRPM: 1_350)
            : .automatic(at: 1_800)
        let plane = ScriptedControlPlane(fans: [0: condition], stages: [.nominal(), .blind()])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(plane: plane, fans: [0: condition], interfering: sensing)
        let lease = try await machine.lease(fans: [0]).id
        let permit = try commandableFan(0, declaring: .held(at: 2_400))
        try await machine.watchdog.manualControlEngaged(permit, under: lease)
        await machine.watchdog.commandedTarget(
            CommandedTarget(fanIndex: 0, rpm: 2_400), under: lease)
        await sensing.interfere { [machine] in
            #expect(
                await machine.ledger.isReclaimed(fanAt: 0),
                "the re-apply did not land after § 5 marked the fan")
            do {
                try await machine.watchdog.manualControlEngaged(permit, under: lease)
            } catch {
                Issue.record("the re-apply under the live lease was refused: \(error)")
            }
            if failure == .readFails { await machine.plane.advance() }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(
            machine.safetyLog.faults.contains { $0.contains("envelope") },
            "the re-assert never failed on its envelope, so the terminal action was not reached")
        #expect(await machine.restorer.causes == [.systemReclaimed], "L1 was not revoked")
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply mid-episode erased the mark the terminal action keeps")
        #expect(machine.safetyLog.lines(containing: Self.resolved).isEmpty)
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEpisode).count == 1)
        #expect(machine.safetyLog.levels(containing: Self.leftToItsEpisode) == [.notice])
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// **The one-cycle bound, both ways.** The same re-apply, with an envelope that reads and a
    /// re-assert that lands: the firmware holds the re-commanded 2,400 RPM, and the fan still
    /// turns at 1,800. The re-apply does not clear the mark early, and the next readable cycle,
    /// whose primary converges while the fan is short, clears it rather than leaving it for the
    /// ramp.
    ///
    /// **Mutations:** (a) the actor always clears, as in demo A: red on the first cycle's mark.
    /// (b) Take `.short` out of the clearing case in `examine(fanAt:)`: red on the second cycle's
    /// mark and its "resolved" line.
    @Test("A re-apply mid-episode leaves the mark for exactly one readable cycle")
    func aReapplyMidEpisodeLeavesTheMarkForOneCycle() async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .envelopeRead)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id
        let permit = try commandableFan(0, declaring: .held(at: 1_800))
        await sensing.interfere { [machine] in
            do {
                try await machine.watchdog.manualControlEngaged(permit, under: lease)
            } catch {
                Issue.record("the re-apply under the live lease was refused: \(error)")
            }
        }

        await machine.watchdog.cycle()

        #expect(await sensing.didFire, "the scenario never arranged the interleaving")
        #expect(await machine.commandedRPMs == [2_400], "the re-assert did not land")
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0),
            "a re-apply mid-episode cleared the mark before § 5 read the target held")
        #expect(machine.safetyLog.lines(containing: Self.leftToItsEpisode).count == 1)

        await machine.watchdog.cycle()

        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "a fan whose target the firmware holds was still reported reclaimed")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)
        #expect(await machine.leases.activeLease()?.id == lease)
    }

    // MARK: - The mark follows the primary signal

    /// **Demo C.** Fan 0 is commanded 2,400 RPM and the firmware holds 1,800, so § 5 marks it
    /// reclaimed and re-asserts. The re-assert lands: `F0Tg` reads 2,400 and the fan still turns
    /// at 1,800, a ramp in flight. The next cycle's primary converges, so the mark goes then, and
    /// the shortfall is reported once, at the dwell, as it always was.
    ///
    /// **Mutation:** take `.short` out of the clearing case in `examine(fanAt:)` — `case
    /// .converged:` clears and `.short` joins `.graced, nil`. Run: red on the second cycle's mark
    /// and on the "resolved" line.
    @Test("A re-asserted fan still ramping to its target is not reported reclaimed")
    func aReassertedFanStillRampingIsNotReportedReclaimed() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.commandedRPMs == [2_400], "the re-assert did not land")

        await machine.watchdog.cycle()
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0) == false,
            "a fan whose target the firmware holds was reported reclaimed while it ramped")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)

        for _ in 0..<ReclamationLimits.actualDwellCycles {
            await machine.watchdog.cycle()
        }

        #expect(
            machine.safetyLog.lines(containing: "has turned at").count == 1,
            "the shortfall was not reported once, at its dwell")
        #expect(machine.safetyLog.lines(containing: Self.resolved).count == 1)
        #expect(await machine.ledger.causes.isEmpty)
        #expect(await machine.commandedRPMs == [2_400], "a held target was re-asserted again")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.leases.activeLease() != nil)
    }

    /// How the fan reads on every cycle of `aMarkIsClearedOnEveryCycleWhosePrimaryConverges`.
    enum PrimaryConverged: Sendable, CaseIterable {
        /// `F0Tg` holds the commanded 2,400 RPM and the fan turns at 1,000: `.short` every cycle,
        /// with the dwell rising through its report.
        case ramping
        /// `F0Tg` holds 2,400 RPM and the fan turns at it: `.converged` every cycle.
        case held
    }

    /// A mark is put in the ledger before every cycle, up to one past the dwell, as a false one
    /// is (the residual C2, a stale restore landing before a newer lease registers). Every cycle
    /// whose primary converges clears it — the report cycle at the dwell included, which is a
    /// case of its own in `examine(fanAt:)`.
    ///
    /// **Mutations:** (a) delete the clear from the dwell-report case: red at cycle
    /// `actualDwellCycles` only, for `.ramping`. (b) Drop `.converged` from the clearing case:
    /// red on every cycle, for `.held`.
    @Test(
        "A mark is cleared on every cycle whose primary signal converges",
        arguments: PrimaryConverged.allCases)
    func aMarkIsClearedOnEveryCycleWhosePrimaryConverges(
        reading: PrimaryConverged
    ) async throws {
        let condition: ScriptedControlPlane.FanCondition =
            reading == .ramping ? .ramping(target: 2_400, actual: 1_000) : .held(at: 2_400)
        let machine = ReclamationMachine(fans: [0: condition])
        try await machine.hold(fan: 0, commanding: 2_400)
        let cycles = ReclamationLimits.actualDwellCycles + 1

        for cycle in 1...cycles {
            await machine.ledger.markReclaimed(fanAt: 0)
            await machine.watchdog.cycle()
            #expect(
                await machine.ledger.isReclaimed(fanAt: 0) == false,
                "cycle \(cycle) left the mark on a fan whose target the firmware holds")
        }

        #expect(machine.safetyLog.lines(containing: Self.resolved).count == cycles)
        #expect(
            machine.safetyLog.lines(containing: "has turned at").count
                == (reading == .ramping ? 1 : 0))
        #expect(await machine.commandedRPMs.isEmpty, "a held target was re-asserted")
        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }
}
