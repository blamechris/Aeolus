import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// One `apply` at a time (ADR 0014's A6 PR-2 amendment): `LeaseApplier` admits one, whatever the
/// lease or connection, refuses a second before it reads anything, and gives the claim up on every
/// exit. A refused `apply`'s undo takes no gate and cannot tell whether another `apply` has
/// commanded the fan since, so the two must never meet.
///
/// Every scenario holds the first `apply` inside one of its engagement steps, on a
/// `HopParking` the plane double parks in, so the second arrives while the first is in flight.
/// Each test names the mutation it kills.
@Suite("Level 6 admits one apply at a time", .timeLimit(.minutes(1)))
struct LeaseApplierClaimTests {

    private static let applyInProgress = AeolusXPCFault.helperFailed(
        detail: LeaseApplyRules.Detail.applyInProgress)

    // MARK: - Under the same lease

    /// **Codex's sequence.** A commands fan 0 at 2,400 and is held in fan 1's engagement; B, under
    /// the same lease, is refused `helperFailed` with the fixed detail before it reads or writes
    /// anything. A's fan-1 command is then refused and A undoes fan 0: nobody was answered applied
    /// for a fan the undo put back on automatic, and § 5 holds nothing.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, delete the claim (the `if let inFlight = applying`
    /// block and `applying = lease`). Run: red, B reads fan 0's envelope and is answered applied.
    @Test("A second apply under the same lease is refused before it reads anything")
    func aSecondApplyUnderTheSameLeaseIsRefusedBeforeItReads() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused"))],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let engagement = HopParking()
        await writes.interfere(beforeEngageStep: 2) { await engagement.park() }

        let first = observing {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        #expect(await yieldUntil("A to park in fan 1's engagement") { await engagement.isParked })
        let before = await machine.attempts.count
        let second = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 3_000)), under: lease)
        }
        let during = await machine.attempts.dropFirst(before)
        await machine.plane.advance()
        await engagement.release()
        let firstAnswer = await LeaseApplierAnswerTests.answer {
            try await finished("A", first)
        }

        #expect(
            second as? AeolusXPCFault == Self.applyInProgress, "B was answered \(second as Any)")
        #expect(during.isEmpty, "B reached the firmware while A was in flight: \(Array(during))")
        #expect(
            LeaseApplyRules.Detail.applyInProgress
                == "another apply under this lease has not finished")
        #expect(
            firstAnswer as? AeolusXPCFault
                == .helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused))
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
        #expect(await machine.commandedRPMs == [2_400, 2_600], "B wrote a target")
    }

    /// **B run to completion inside A's engagement.** B is started and finished from inside fan
    /// 1's engagement step, as the panel's second probe ran it, and is refused there. A then
    /// finishes applied, its targets are what § 5 records, and B's retry once A has returned is
    /// applied.
    ///
    /// **Mutation:** the claim deleted, as above. Run: red, B answered applied inside A's step,
    /// and § 5 left recording B's 3,000 for a fan A then commanded to 2,400.
    @Test("A second apply run inside the first's engagement is refused, and its retry applied")
    func aSecondApplyInsideTheFirstsEngagementIsRefused() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let inside = Sightings<String>()
        await writes.interfere(beforeEngageStep: 2) {
            let answer = await LeaseApplierAnswerTests.answer {
                try await levelSix.apply(fixed((0, 3_000)), under: lease)
            }
            await inside.record(answer.map { String(describing: $0) } ?? "applied")
        }

        try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)

        #expect(await inside.seen == [String(describing: Self.applyInProgress)])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
        #expect(await machine.watchdog.lastCommanded(ofFan: 1)?.rpm == 2_600)
        try await levelSix.apply(fixed((0, 3_000)), under: lease)
        #expect(await machine.commandedRPMs == [2_400, 2_600, 3_000])
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 3_000)
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual)
    }

    // MARK: - Under another lease

    /// **The panel's cross-lease sequence.** A, under L1, commands fan 0 and is held in fan 1's
    /// engagement. L1 is released on its connection, its restore and § 5's notice land, and L2 is
    /// granted on another connection. B, under L2, is refused `.releaseInProgress` before it reads
    /// anything: a previous lease's unwind is in progress. A then fails on its ended lease and
    /// undoes fan 0. B's retry once A has returned is applied, fan 0 is manual under L2, and § 5's
    /// next cycle marks nothing.
    ///
    /// **Mutation:** key the claim per lease (`if let inFlight = applying, inFlight == lease`).
    /// Run: red, B engages and commands fan 0 under L2 and is answered applied, then A's undo
    /// restores it.
    @Test("An apply under a newer lease is refused while an ended lease's apply unwinds")
    func anApplyUnderANewerLeaseIsRefusedWhileAnEndedLeasesApplyUnwinds() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let ended = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let engagement = HopParking()
        await writes.interfere(beforeEngageStep: 2) { await engagement.park() }

        let unwinding = observing {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: ended)
        }
        #expect(await yieldUntil("A to park in fan 1's engagement") { await engagement.isParked })
        try await machine.leases.releaseLease(id: ended, from: machine.holder)
        // The fixture's restorer writes nothing and tells § 5 nothing: the release's restore and
        // its notice, by hand.
        try await machine.plane.restoreToAutomatic(.fan(0))
        await machine.watchdog.manualControlReleased(fanAt: 0)
        let other = ConnectionID()
        let newer = try await machine.leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: other
        ).id
        let before = await machine.attempts.count
        let refused = await LeaseApplierAnswerTests.answer {
            try await levelSix.applier.apply(fixed((0, 3_000)), leaseID: newer, from: other)
        }
        let during = await machine.attempts.dropFirst(before)
        await engagement.release()
        let unwound = await LeaseApplierAnswerTests.answer { try await finished("A", unwinding) }

        try await levelSix.applier.apply(fixed((0, 3_000)), leaseID: newer, from: other)
        try await finished("§ 5's cycle", observing { await machine.watchdog.cycle() })

        #expect(
            refused as? AeolusXPCFault == .manualControlUnavailable(reason: .releaseInProgress),
            "B was answered \(refused as Any)")
        #expect(during.isEmpty, "B reached the firmware while A unwound: \(Array(during))")
        #expect(unwound as? AeolusXPCFault == .leaseUnknown)
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual)
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 3_000)
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "§ 5 marked L2's fan")
        #expect(machine.safetyLog.lines(containing: "Reclamation detected on fan 0").isEmpty)
    }

    /// **The lease core first.** Another connection naming the lease while A is in flight is
    /// refused as `heldLease(id:from:)` refuses it, not as an `apply` in flight: the claim says
    /// nothing to a caller the lease core has not authorised.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, check the claim before `heldLease(id:from:)`. Run:
    /// red, answered `helperFailed` with the in-flight detail.
    @Test("Another connection naming the lease is refused by the lease core while an apply runs")
    func anotherConnectionIsRefusedByTheLeaseCoreWhileAnApplyRuns() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let engagement = HopParking()
        await writes.interfere(beforeEngageStep: 1) { await engagement.park() }

        let inFlight = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
        #expect(await yieldUntil("A to park in fan 0's engagement") { await engagement.isParked })
        let stranger = await LeaseApplierAnswerTests.answer {
            try await levelSix.applier.apply(
                fixed((0, 3_000)), leaseID: lease, from: ConnectionID())
        }
        await engagement.release()
        try await finished("the apply in flight", inFlight)

        #expect(stranger as? AeolusXPCFault == .leaseNotHeldByThisConnection)
        #expect(await machine.commandedRPMs == [2_400])
    }

    // MARK: - Every exit gives the claim up

    /// One way an `apply` ends.
    enum Exit: String, CaseIterable, Sendable, CustomStringConvertible {
        case writePathNotBuilt = "the write path not built"
        case itemZero = "item 0's refusal"
        case aStepRefused = "a step refused, and its undo"
        case itemFour = "item 4's refusal"
        case applied = "applied"
        case cancelled = "a gate wait cancelled"

        var description: String { rawValue }

        /// What the `apply` that ends this way answers.
        var answer: AeolusXPCFault? {
            switch self {
            case .writePathNotBuilt: .manualControlUnavailable(reason: .writePathNotBuilt)
            case .itemZero: settingsRefused(LeaseApplyRules.Detail.noSettings)
            case .aStepRefused: .helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
            case .itemFour: .thermalEmergencyActive
            case .applied: nil
            case .cancelled: .manualControlUnavailable(reason: .releaseInProgress)
            }
        }
    }

    /// **The claim is given up on every exit.** An `apply` ends each way in turn, and the next
    /// `apply` under the same lease gets past the claim and is answered on its merits: applied,
    /// or, on a write path that is not built, `.writePathNotBuilt` again, never the in-flight
    /// refusal.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, replace `defer { applying = nil }` with
    /// `applying = nil` after item 4, so only an `apply` answered applied gives the claim up. Run:
    /// red on every argument but `applied`.
    @Test("The claim is given up on every exit", arguments: Exit.allCases)
    func theClaimIsGivenUpOnEveryExit(_ exit: Exit) async throws {
        let refusedTarget: [ScriptedControlPlane.Stage] = [
            .nominal(targetWrites: .refused(reason: "F0Tg refused")), .nominal(),
        ]
        let machine = ReclamationMachine(
            stages: exit == .aStepRefused ? refusedTarget : [.nominal()],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        if exit == .itemFour { await writes.interfere { await machine.engageThermalEmergency() } }
        let levelSix = machine.levelSix(
            writingThrough: writes,
            capability: exit == .writePathNotBuilt ? NotBuiltWritePath() : nil)

        let ended = try await Self.end(exit, of: levelSix, in: machine, under: lease)
        let next = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(ended as? AeolusXPCFault == exit.answer, "\(exit) answered \(ended as Any)")
        #expect(
            next as? AeolusXPCFault == (exit == .writePathNotBuilt ? exit.answer : nil),
            "the apply after \(exit) was answered \(next as Any)")
    }

    /// Ends one `apply` the way `exit` says, and leaves the machine able to apply again.
    private static func end(
        _ exit: Exit, of levelSix: LevelSix<InterferingFanStateSensing>,
        in machine: ReclamationMachine<ScriptedControlPlane>, under lease: UUID
    ) async throws -> (any Error)? {
        let apply = { @Sendable (settings: [FanSetting]) in
            await LeaseApplierAnswerTests.answer {
                try await levelSix.apply(settings, under: lease)
            }
        }
        switch exit {
        case .writePathNotBuilt, .applied:
            return await apply(fixed((0, 2_400)))
        case .itemZero:
            return await apply([])
        case .aStepRefused:
            let answer = await apply(fixed((0, 2_400)))
            await machine.plane.advance()
            return answer
        case .itemFour:
            let answer = await apply(fixed((0, 2_400)))
            _ = await machine.latch.release()
            return answer
        case .cancelled:
            let held = await machine.gate.enterForExamination(fanAt: 0)
            let waiting = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
            #expect(await yieldUntil("the step to wait") { machine.gate.waiting(onFan: 0) == 1 })
            waiting.task.cancel()
            let answer = await LeaseApplierAnswerTests.answer {
                try await finished("the cancelled apply", waiting)
            }
            machine.gate.leave(held)
            return answer
        }
    }
}
