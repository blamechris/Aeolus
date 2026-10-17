import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Item 5's table, row by row, through the real level 6, and then as a value (ADR 0014's A6 and
/// A6 PR-2 amendments). Row 3, item 0's refusals, is
/// `LeaseApplierTests.itemZeroRefusesBeforeAnythingIsTouched`, and row 6's second half, § 3's
/// latch at item 4, is `LeaseApplierTests.aLatchMidApplyIsNeverApplied`.
///
/// Each row's mutation is its own line in `LeaseApplyRules.answer(to:)` or `LeaseApplier`, and
/// each was run.
@Suite("Level 6's apply answers each outcome as item 5's table says", .timeLimit(.minutes(1)))
struct LeaseApplierAnswerTests {

    /// What `apply` threw, or `nil` when it returned.
    static func answer(_ work: () async throws -> Void) async -> (any Error)? {
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Before any fan

    /// **Row 1.** A fault `heldLease(id:from:)` throws is the answer: no such lease, another
    /// connection's, and one that has lapsed. Nothing is read, written or entered.
    ///
    /// **Mutation:** in `apply`, catch the first `heldLease(id:from:)`'s fault and throw
    /// `.leaseUnknown` instead. Run: red on the other two.
    @Test("Row 1: a fault the lease core throws is the answer")
    func rowOneTheLeaseCoresFaultIsTheAnswer() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()

        await #expect(throws: AeolusXPCFault.leaseUnknown) {
            try await levelSix.apply(fixed((0, 2_400)), under: UUID())
        }
        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            try await levelSix.applier.apply(
                fixed((0, 2_400)), leaseID: lease, from: ConnectionID())
        }
        machine.lapseLease()
        await #expect(throws: AeolusXPCFault.leaseExpired) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        await LeaseApplierTests.expectNothingTouched(machine)
    }

    /// **Row 2.** A write path that is not built answers `.writePathNotBuilt`, before item 0 and
    /// before anything is read. A lease granted where the write path is not built is a state only a
    /// test can build: the lease core refuses every grant there.
    ///
    /// **Mutation:** delete `apply`'s capability `guard`. Run: red, the fan engaged and commanded.
    @Test("Row 2: a write path that is not built answers writePathNotBuilt")
    func rowTwoAWritePathNotBuilt() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix(
            writingThrough: machine.plane, capability: NotBuiltWritePath())

        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)) {
            try await levelSix.apply([], under: lease)
        }
        await LeaseApplierTests.expectNothingTouched(machine)
    }

    // MARK: - The envelope

    /// **Row 4, a read that failed.** `.supervisorBlind`, and the gate is never entered.
    ///
    /// **Mutation:** in `LeaseApplier.step`, rethrow the envelope read's error unchanged. Run: red,
    /// answered `.helperFailed`.
    @Test("Row 4: an envelope that will not read answers supervisorBlind")
    func rowFourAnEnvelopeThatWillNotRead() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix(
            writingThrough: machine.plane, envelopes: EnvelopeRefusingSensing(machine.plane))

        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .supervisorBlind)) {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        await LeaseApplierTests.expectNothingTouched(machine)
    }

    /// **Row 4, a read that was cancelled.** A cancellation says nothing about the machine: it is
    /// thrown as it is, never answered `.supervisorBlind`.
    ///
    /// **Mutation:** in `LeaseApplier.step`, delete the envelope read's `catch let cancellation as
    /// CancellationError` clause. Run: red, answered `.supervisorBlind`.
    @Test("Row 4: an envelope read that was cancelled is thrown as a cancellation")
    func rowFourACancelledEnvelopeRead() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix(
            writingThrough: machine.plane, envelopes: CancelledEnvelopeRead())

        let answered = await Self.answer {
            try await levelSix.apply(fixed((0, 2_400)), under: lease)
        }
        #expect(answered is CancellationError, "answered \(answered as Any)")
        await LeaseApplierTests.expectNothingTouched(machine)
    }

    /// **Row 4, implausible bounds.** `boundsImplausible(fanIndex:detail:)` for the fan whose
    /// `F0Mx` reads byte-swapped after the grant, and the gate is never entered.
    ///
    /// **Mutation:** in `LeaseApplier.step`, answer an implausible envelope with
    /// `.manualControlUnavailable(reason: .boundsImplausible)`. Run: red.
    @Test("Row 4: implausible bounds answer boundsImplausible for that fan")
    func rowFourImplausibleBounds() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), ScriptedControlPlane.Stage(maximumReads: [0: .reads(1e14)])],
            fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        await machine.plane.advance()

        let answered = await Self.answer {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }
        guard case .boundsImplausible(fanIndex: 0, _)? = answered as? AeolusXPCFault else {
            Issue.record(
                "answered \(String(describing: answered)), not boundsImplausible for fan 0")
            return
        }
        #expect(machine.gate.entrants == 0)
        #expect(await machine.attempts == [.readEnvelope(fan: 0)])
    }

    // MARK: - The gate, a superseded step, and the lease

    /// **Row 5, `stepWait`.** The fan's gate is held and `stepWait` passes: `.releaseInProgress`,
    /// with nothing engaged or written, because level 6 never engages a fan or commands a target
    /// without the gate.
    ///
    /// **Mutation:** in `LeaseApplier.step`, take the pass as optional and carry on without it
    /// when it is `nil`. Run: red, the fan engaged and commanded without its gate.
    @Test("Row 5: a gate not granted within stepWait answers releaseInProgress")
    func rowFiveTheGateNotGranted() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        let held = await machine.gate.enterForExamination(fanAt: 0)

        let apply = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
        #expect(await yieldUntil("the step to wait") { machine.gate.waiting(onFan: 0) == 1 })
        machine.gateClock.advance(by: FanExaminationGate.stepWait)
        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)) {
            try await finished("the step refused at stepWait", apply)
        }

        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(await machine.commandedRPMs.isEmpty, "level 6 wrote without the gate")
        machine.gate.leave(held)
        #expect(machine.gate.isIdle)
    }

    /// **Row 5, superseded.** A restore is requested inside the first step, after its mode write:
    /// the driver undoes the fan and the lease still stands, so `.releaseInProgress`.
    ///
    /// **Mutation:** in `LeaseApplyRules.answer(to:)`, map `.superseded, .supersededAfterWrite` to
    /// `.fault(.helperFailed(detail: Detail.unexpected))`. Run: red.
    @Test("Row 5: a superseded step answers releaseInProgress while the lease stands")
    func rowFiveASupersededStep() async throws {
        let plane = ScriptedControlPlane(fans: [0: .automatic(at: 1_800)], unlock: .neverYields)
        let machine = ReclamationMachine(plane: plane, fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        await plane.duringNextModeWrite { plane.ledger.restoreRequested() }

        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)) {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await machine.didRestore(fan: 0), "the driver did not undo its step")
        #expect(await machine.commandedRPMs.isEmpty)
    }

    /// **Row 5, a lease that has gone.** The lease ends while the fan's mode write is landing: the
    /// driver's after-check refuses `.leaseNotLive`, and the lease has gone, so the answer is the
    /// fault `heldLease(id:from:)` throws now.
    ///
    /// **Mutation:** in `LeaseApplier.refusal(for:leaseID:from:)`, answer `.releaseInProgress`
    /// without asking the lease core. Run: red.
    @Test("Row 5: a lease that has gone answers with its own fault")
    func rowFiveALeaseThatHasGone() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .engageWrite)
        await writes.interfere { await machine.endLease() }

        await #expect(throws: AeolusXPCFault.leaseUnknown) {
            try await machine.levelSix(writingThrough: writes).apply(
                fixed((0, 2_400)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.didRestore(fan: 0), "the engagement was not undone")
    }

    /// **Row 5, a registration refused under a live lease.** Fan 0's release notice lands while § 5
    /// asks the lease core about the registration, so § 5 refuses it `.leaseNotLive`. The lease
    /// still stands: `.releaseInProgress`, and the fan is undone.
    ///
    /// **Mutation:** in `LeaseApplyRules.answer(to:)`, map `.leaseNotLive` to
    /// `.fault(.thermalEmergencyActive)`. Run: red.
    @Test("Row 5: a registration refused under a live lease answers releaseInProgress")
    func rowFiveARegistrationRefusedUnderALiveLease() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)], parkingLeaseHops: true)
        let hops = try #require(machine.leaseHops)
        let lease = try await machine.lease(fans: [0]).id
        let levelSix = machine.levelSix()
        await hops.parkNextAnswer()

        let apply = observing { try await levelSix.apply(fixed((0, 2_400)), under: lease) }
        #expect(await yieldUntil("the registration's lease hop to park") { await hops.isParked })
        await machine.watchdog.manualControlReleased(fanAt: 0)
        await hops.release()

        await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)) {
            try await finished("the refused registration", apply)
        }
        #expect(await machine.didRestore(fan: 0), "the engaged fan was not undone")
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - The driver's refusals

    /// **Row 6.** § 3's latch is set before the first step: the driver is pre-empted, nothing is
    /// written, and the answer is `.thermalEmergencyActive`.
    ///
    /// **Mutation:** in `LeaseApplyRules.answer(to:)`, map `.preempted` to
    /// `.releaseInProgressUnlessTheLeaseHasGone`. Run: red.
    @Test("Row 6: a pre-empted step answers thermalEmergencyActive")
    func rowSixAPreemptedStep() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id
        await machine.engageThermalEmergency()

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)) == false)
        #expect(await machine.commandedRPMs.isEmpty)
    }

    /// **Row 7.** Something outside Aeolus holds fan 0 in manual: the first step refuses it
    /// `.notAutomatic`, writes nothing and restores nothing, and the answer is
    /// `.foreignManualControl`.
    ///
    /// **Mutation:** in `LeaseApplyRules.answer(to:)`, map `.notAutomatic` to
    /// `.fault(.helperFailed(detail: Detail.unexpected))`. Run: red.
    @Test("Row 7: a fan that is not automatic answers foreignManualControl")
    func rowSevenAFanThatIsNotAutomatic() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        let lease = try await machine.lease(fans: [0]).id

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .foreignManualControl)
        ) {
            try await machine.levelSix().apply(fixed((0, 2_000)), under: lease)
        }
        #expect(await machine.plane.keyWrites.isEmpty, "a foreign fan was written")
        #expect(await machine.commandedRPMs.isEmpty)
    }

    /// One of row 8's three firmware outcomes.
    struct Unlock: Sendable, CustomStringConvertible {
        let description: String
        let unlock: ScriptedControlPlane.UnlockBehaviour
        let stage: ScriptedControlPlane.Stage
        let detail: String
    }

    static let firmwareOutcomes = [
        Unlock(
            description: "a yield that never arrives", unlock: .neverYields, stage: .nominal(),
            detail: LeaseApplyRules.Detail.yieldDidNotArrive),
        Unlock(
            description: "a refused mode write", unlock: .naive,
            stage: .nominal(writes: .refused(reason: "F0Md refused")),
            detail: LeaseApplyRules.Detail.firmwareRefused),
        Unlock(
            description: "a mode that does not read back manual", unlock: .readsBack(rawMode: 0),
            stage: .nominal(), detail: LeaseApplyRules.Detail.notConfirmed),
    ]

    /// **Row 8.** The D3 outcomes run 1 (D8) has not observed answer `.helperFailed` with a fixed
    /// detail, once the driver has undone what it wrote, or said at `.fault` that it could not.
    ///
    /// **Mutations, one per outcome, in `LeaseApplyRules.answer(to:)`:** map `.yieldDidNotArrive`,
    /// `.firmwareRefusedControl` and `.engagementNotConfirmed` each to `Detail.unexpected`. Run:
    /// red on that argument.
    @Test("Row 8: the firmware's refusals answer helperFailed", arguments: firmwareOutcomes)
    func rowEightTheFirmwaresRefusals(_ outcome: Unlock) async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)], stages: [outcome.stage], unlock: outcome.unlock)
        let machine = ReclamationMachine(plane: plane, fans: [0: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0]).id

        await #expect(throws: AeolusXPCFault.helperFailed(detail: outcome.detail)) {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await machine.commandedRPMs.isEmpty)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - The table, as a value

    /// Every error `apply`'s loop can see, mapped as the table says, the residue included: a
    /// cancellation and a fault already in the client's vocabulary are thrown as they are, and an
    /// error the table does not name is `.helperFailed`.
    ///
    /// **Mutation:** drop `is CancellationError` from the first case of
    /// `LeaseApplyRules.answer(to:)`. Run: red, a cancellation answered `.helperFailed`.
    @Test("Item 5's table as a value, the residue included")
    func theTableAsAValue() {
        typealias Rules = LeaseApplyRules
        let unexpected = Rules.Answer.fault(.helperFailed(detail: Rules.Detail.unexpected))
        let cases: [(any Error, Rules.Answer)] = [
            (AeolusXPCFault.leaseExpired, .unchanged),
            (CancellationError(), .unchanged),
            (Rules.GateNotGranted(), .releaseInProgressUnlessTheLeaseHasGone),
            (EngagementRefusal.leaseNotLive(fan: 0), .releaseInProgressUnlessTheLeaseHasGone),
            (FanControlPlaneError.superseded, .releaseInProgressUnlessTheLeaseHasGone),
            (FanControlPlaneError.supersededAfterWrite, .releaseInProgressUnlessTheLeaseHasGone),
            (
                EngagementRefusal.preempted(fan: 0, by: .thermalEmergency),
                .fault(.thermalEmergencyActive)
            ),
            (
                FanControlPlaneError.notAutomatic(index: 0, rawMode: 1),
                .fault(.manualControlUnavailable(reason: .foreignManualControl))
            ),
            (
                EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35),
                .fault(.helperFailed(detail: Rules.Detail.yieldDidNotArrive))
            ),
            (
                FanControlPlaneError.firmwareRefusedControl(detail: "no"),
                .fault(.helperFailed(detail: Rules.Detail.firmwareRefused))
            ),
            (
                FanControlPlaneError.engagementNotConfirmed(index: 0, rawMode: 0),
                .fault(.helperFailed(detail: Rules.Detail.notConfirmed))
            ),
            (
                Rules.ApplyInFlight(underTheSameLease: true),
                .fault(.helperFailed(detail: Rules.Detail.applyInProgress))
            ),
            (
                Rules.ApplyInFlight(underTheSameLease: false),
                .releaseInProgressUnlessTheLeaseHasGone
            ),
            (Rules.ReportNotRecorded.notHeld, .releaseInProgressUnlessTheLeaseHasGone),
            (Rules.ReportNotRecorded.refused, unexpected),
            (FanControlPlaneError.readFailed(detail: "no"), unexpected),
            (FanControlPlaneError.controlPathNotBuilt, unexpected),
            (UnnamedFailure(), unexpected),
        ]
        for (error, expected) in cases {
            #expect(Rules.answer(to: error) == expected, "\(error)")
        }
    }
}

/// An error no row of the table names.
private struct UnnamedFailure: Error {}

/// An envelope read whose task was cancelled.
private struct CancelledEnvelopeRead: FanEnvelopeReading {
    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope { throw CancellationError() }
}
