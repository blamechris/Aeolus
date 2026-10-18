import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `LeaseApplierClaimTests`' cases about the claim's edges: it covers the undo, a refused entrant
/// never gives it up, and two applies arriving together admit one. An extension of the same
/// suite, in a file of its own so the suite's body stays under `type_body_length`.
extension LeaseApplierClaimTests {

    /// **The claim covers the undo.** A, under L1, commands fan 0 and is held in fan 1's
    /// engagement; L1 is released, fan 0 restored and L2 granted on another connection, so A's
    /// fan-1 step is refused. B, under L2, applies fan 0 from inside A's first hand-back notice,
    /// the undo's first act: B is refused, and nothing is commanded beyond A's own write, so A's
    /// undo cannot restore a fan B has engaged.
    ///
    /// **Mutations:** in `LeaseApplier.apply`, make `applying = nil` the catch's first statement;
    /// separately, move `defer { applying = nil }` inside the `do` block. Run: red, B answered
    /// applied and 3,000 commanded before A's undo restores the fan.
    @Test("An apply under a newer lease arriving during an ended lease's undo is refused")
    func anApplyArrivingDuringAnEndedLeasesUndoIsRefused() async throws {
        let machine = ReclamationMachine(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let ended = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let undo = UndoHookRole(machine.watchdog)
        let levelSix = machine.levelSix(writingThrough: writes, reclamation: undo)
        let other = ConnectionID()
        let newer = Sightings<UUID>()
        await writes.interfere(beforeEngageStep: 2) {
            do {
                try await machine.leases.releaseLease(id: ended, from: machine.holder)
                // The fixture's restorer writes nothing and tells § 5 nothing: by hand.
                try await machine.plane.restoreToAutomatic(.fan(0))
                await machine.watchdog.manualControlReleased(fanAt: 0)
                let lease = try await machine.leases.acquireLease(
                    LeaseFixture.request(fans: [0, 1]), from: other)
                await newer.record(lease.id)
            } catch {
                Issue.record("the lease change inside A's engagement threw \(error)")
            }
        }
        let inside = Sightings<String>()
        await undo.onFirstHandBack {
            guard let lease = await newer.seen.first else { return }
            let answer = await LeaseApplierAnswerTests.answer {
                try await levelSix.applier.apply(fixed((0, 3_000)), leaseID: lease, from: other)
            }
            await inside.record(answer.map { String(describing: $0) } ?? "applied")
        }

        let unwound = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: ended)
        }

        #expect(await writes.didFire)
        #expect(unwound as? AeolusXPCFault == .leaseUnknown, "A answered \(unwound as Any)")
        let seen = await inside.seen
        let refused = String(
            describing: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress))
        #expect(seen == [refused], "B, inside A's undo, was answered \(seen)")
        #expect(await machine.commandedRPMs == [2_400], "B wrote a target during A's undo")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
    }

    /// **A refused entrant never gives up the incumbent's claim.** A is held in fan 1's
    /// engagement; B, under the same lease, is refused, and then so is C, and neither reaches the
    /// firmware.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, hoist `defer { applying = nil }` above the `if let
    /// inFlight = applying` check. Run: red, B's refusal clears A's claim and C is applied.
    @Test("A third apply after a refused second is refused too")
    func aThirdApplyAfterARefusedSecondIsRefused() async throws {
        let machine = ReclamationMachine(
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
        let third = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 3_200)), under: lease)
        }
        let during = await machine.attempts.dropFirst(before)
        await engagement.release()
        try await finished("A", first)

        #expect(second as? AeolusXPCFault == Self.inProgress, "B was answered \(second as Any)")
        #expect(third as? AeolusXPCFault == Self.inProgress, "C was answered \(third as Any)")
        #expect(during.isEmpty, "an entrant reached the firmware while A was in flight")
        #expect(await machine.commandedRPMs == [2_400, 2_600])
    }

    /// **Two applies arriving together admit exactly one.** Both start at once under one lease,
    /// and whichever is admitted is held in its engagement until the other has been answered or
    /// has queued for the gate: exactly one is refused. Twenty runs over fresh machines, because
    /// whether two calls meet between the check and the claim is the scheduler's to decide.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, `await Task.yield()` between the `if let inFlight`
    /// block and `applying = lease`. Run: red, both admitted in a run where they meet there.
    @Test("Two applies arriving together admit exactly one")
    func twoAppliesArrivingTogetherAdmitExactlyOne() async throws {
        for run in 1...20 {
            let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
            let lease = try await machine.lease(fans: [0]).id
            let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
            let levelSix = machine.levelSix(writingThrough: writes)
            let engagement = HopParking()
            await writes.interfere(beforeEngageStep: 1) { await engagement.park() }

            let one = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
            let two = observing { try await levelSix.apply(fixed((0, 3_000)), under: lease) }
            _ = await yieldUntil("one apply to engage, and the other to be answered or to queue") {
                guard await engagement.isParked else { return false }
                if machine.gate.waiting(onFan: 0) == 1 { return true }
                let oneDone = await one.isFinished.isSet
                let twoDone = await two.isFinished.isSet
                return oneDone || twoDone
            }
            await engagement.release()
            let answers = [
                await LeaseApplierAnswerTests.answer { try await finished("one", one) },
                await LeaseApplierAnswerTests.answer { try await finished("two", two) },
            ]

            let refused = answers.compactMap { $0 as? AeolusXPCFault }
            #expect(refused == [Self.inProgress], "run \(run): answered \(answers)")
            if refused != [Self.inProgress] { return }
        }
    }

    /// The refusal a second `apply` under the same lease gets.
    private static let inProgress = AeolusXPCFault.helperFailed(
        detail: LeaseApplyRules.Detail.applyInProgress)
}

/// § 5 as level 6 sees it, running a hook once inside the first hand-back notice: the first act
/// of a refused `apply`'s undo, before its restore. The registration and the notice go on to the
/// watchdog; the report answers `.recorded` without it, since the role's report is synchronous
/// on its conformer, and the scenario judges answers and writes.
private actor UndoHookRole: ReclamationRegistrationRole {
    private let watchdog: ReclamationWatchdog<ScriptedControlPlane>
    private var hook: (@Sendable () async -> Void)?

    init(_ watchdog: ReclamationWatchdog<ScriptedControlPlane>) { self.watchdog = watchdog }

    func onFirstHandBack(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }

    func manualControlEngaged(_ fan: CommandableFan, under lease: UUID) async throws {
        try await watchdog.manualControlEngaged(fan, under: lease)
    }

    func commandedTarget(_ commanded: CommandedTarget, under lease: UUID) -> ReportReceipt {
        .recorded
    }

    func manualControlHandedBack(fanAt index: Int, under lease: UUID) async {
        await watchdog.manualControlHandedBack(fanAt: index, under: lease)
        guard let hook else { return }
        self.hook = nil
        await hook()
    }
}
