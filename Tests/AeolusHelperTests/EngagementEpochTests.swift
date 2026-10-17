import Foundation
import Testing

@testable import AeolusHelper

/// The restore epoch around the driver (ADR 0014 D4): which restores supersede an engagement, the
/// engagement's ticket that makes a restore before its first step one the step's admission sees,
/// and the first-step retry (ADR 0014's #410 ticket-and-seal amendment). The ticket's own scenarios
/// — the handback before it, the retry's fresh one, and the after-check it leaves standing — are
/// `EngagementTicketTests`'.
@Suite("The engagement driver and the restore epoch", .timeLimit(.minutes(1)))
struct EngagementEpochTests {

    // MARK: - Every restore supersedes an engagement past its first step

    /// A restore of the engaging fan itself, while it waits for its yield, supersedes it: the
    /// next step writes nothing, and the engagement is undone.
    ///
    /// **Mutation:** delete `state.epoch &+= 1` from `PlaneWriteLedger.restoreRequested(_:)`.
    /// Run: red — the next step is admitted as a continuation and the fan is re-engaged. The first
    /// version's mutation, erasing the fan's in-progress record in `issueRestore(fanAt:)`, is now
    /// equivalent: the next step then finds no record and no ticket, which its first step
    /// consumed, and is refused anyway (ADR 0014's #410 ticket-and-seal amendment).
    @Test("A restore of the same fan mid-poll supersedes the engagement")
    func aSameFanRestoreSupersedes() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        rig.clock.onSleep(1) { _ = try? await rig.plane.restoreToAutomatic(.fan(0)) }

        await #expect(throws: FanControlPlaneError.superseded) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await Self.forwardWrites(after: .mode(fan: 0, value: 0), on: rig.plane).isEmpty)
        #expect(rig.plane.ledger.engagedFans.isEmpty)
        #expect(await rig.plane.isForceKeySet == false)
    }

    /// A machine-wide restore mid-poll supersedes it too — § 4's order is the case: the leases
    /// are released, then `.everyFan`, and no step may write after the keystone.
    ///
    /// **Mutation:** delete `state.epoch &+= 1` from `PlaneWriteLedger.restoreRequested(_:)`.
    /// Run: red. Erasing every in-progress record in `issueMachineWideRestore()`, the mutation this
    /// cited before the ticket, is now equivalent, for the reason the test above gives.
    @Test("A machine-wide restore mid-poll supersedes the engagement")
    func aMachineWideRestoreSupersedes() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        rig.clock.onSleep(1) { _ = try? await rig.plane.restoreToAutomatic(.everyFan) }

        await #expect(throws: FanControlPlaneError.superseded) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await Self.forwardWrites(after: .forceKey(0), on: rig.plane).isEmpty)
        #expect(rig.plane.ledger.engagedFans.isEmpty)
        #expect(await rig.plane.isForceKeySet == false)
    }

    /// The production shape: the restore lands **after** the driver's entitlement check and
    /// before the step's turn. No mode or key write follows it.
    @Test("A restore between the entitlement check and a later step's turn writes nothing after")
    func aRestoreBeforeALaterStepsTurnSupersedesIt() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        await rig.writes.interfere(beforeEngageStep: 2) {
            _ = try? await rig.plane.restoreToAutomatic(.fan(0))
        }

        await #expect(throws: FanControlPlaneError.superseded) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(await Self.forwardWrites(after: .mode(fan: 0, value: 0), on: rig.plane).isEmpty)
    }

    /// **The second throw site.** A restore requested inside the first step's turn — after its
    /// `0x82` mode write, before its `Ftst = 1` (D3 step 3's re-check) — stops the step, and the
    /// mode write it already issued may have landed. That is `.supersededAfterWrite`: never
    /// retried, and always registered with § 3 and undone.
    ///
    /// **Mutation:** delete the step-3 re-check from the scripted step. Run: red — the key is
    /// written after the restore was requested. **Mutation:** retry `.supersededAfterWrite` in
    /// `EngagementDriver.firstStep(of:)`. Run: red — the engagement runs on instead of stopping.
    /// **Mutation:** count `.supersededAfterWrite` as writing nothing. Run: red — no
    /// registration, no undo.
    @Test("A restore inside the first step, after its mode write, is undone and never retried")
    func aRestoreAfterTheFirstModeWriteIsUndone() async throws {
        let rig = try await EngagementRig(unlock: .neverYields)
        await rig.plane.duringNextModeWrite { rig.plane.ledger.restoreRequested(.fan(0)) }

        await #expect(throws: FanControlPlaneError.supersededAfterWrite) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)],
            "the force key was written after a restore was requested, or nothing was undone")
        #expect(await rig.registry.engaged == [0], "the fan was not registered before its undo")
        #expect(await rig.registry.accepted == [0])
        #expect(rig.log.lines(containing: "Nothing was written").isEmpty)
        #expect(rig.log.lines(containing: "retrying it once").isEmpty, "a written step was retried")
    }

    /// The exit's restore requested inside the first step's turn, after its `0x82` mode write and
    /// before its `Ftst = 1`, stops the step as any restore does: `.forExit` moves the epoch as
    /// well as sealing, and D3 step 3's in-turn re-check reads the epoch alone (ADR 0014's #410
    /// ticket-and-seal amendment). So the key is not written, and the undo, a restore the seal
    /// never refuses, hands the fan back.
    ///
    /// **Mutation:** in `PlaneWriteLedger.restoreRequested(_:)`, skip the epoch bump for
    /// `.forExit`. Run: red, at the key-write assertion: the re-check passes and `Ftst = 1` is
    /// written.
    @Test("The exit requested inside a step writes no force key")
    func anExitRequestedInsideAStepWritesNoForceKey() async throws {
        let rig = try await EngagementRig(unlock: .neverYields)
        await rig.plane.duringNextModeWrite { rig.plane.ledger.restoreRequested(.forExit) }

        await #expect(throws: FanControlPlaneError.supersededAfterWrite) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        let writes = await rig.plane.keyWrites
        #expect(!writes.contains(.forceKey(1)), "the key was written after the exit: \(writes)")
        #expect(writes == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)], "nothing was undone")
        #expect(await rig.registry.engaged == [0], "the fan was not registered before its undo")
        #expect(await rig.registry.accepted == [0])
    }

    // MARK: - The first step, and its retry

    /// An engagement's undo is a restore, so it leaves the fan's record out of date; the next
    /// engagement's ticket clears it, and that engagement's first step is admitted with no retry
    /// (ADR 0014's #410 ticket-and-seal amendment). Until the ticket, the driver's retry was what
    /// made a fresh engagement possible here, and this test expected one retry line.
    ///
    /// **Mutation:** in `PlaneWriteLedger.beginEngagement(fanAt:)`, skip the clear of the fan's
    /// in-progress record. Run: red, at the retry line: the fresh step meets the stale record, is
    /// superseded and is retried. The old mutation — make `firstStep(of:)` call the step once,
    /// with no retry — no longer turns this red, because nothing here is retried.
    @Test("A fresh engagement after an undo is not superseded by that undo")
    func aFreshEngagementAfterAnUndoProceeds() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 100))
        for _ in 0..<2 {
            await #expect(throws: EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35)) {
                try await rig.driver.engageManualControl(of: rig.fan(0))
            }
        }
        #expect(
            rig.log.lines(containing: "retrying it once").isEmpty,
            "the second engagement met the first one's stale record")
    }

    /// The retry asks the entitlement first, so a restore that was real — it came with § 3's
    /// latch — refuses it, with nothing written and nothing to undo. The restore is of another
    /// fan: any restore requested after the ticket supersedes the first step.
    ///
    /// **Mutation:** delete the `try await requireEntitlement(for: fan)` in
    /// `EngagementDriver.firstStep(of:)`. Run: red — the retry engages above the ceiling.
    @Test("A superseded first step is retried only if the entitlement still holds")
    func theFirstStepRetryAsksTheEntitlement() async throws {
        let rig = try await EngagementRig(
            unlock: .heldUntilForced(stepsToYield: 100), fans: [0, 1])
        await rig.writes.interfere(beforeEngageStep: 1) {
            await rig.engageThermalEmergency()
            _ = try? await rig.plane.restoreToAutomatic(.fan(1))
        }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(
            await rig.plane.keyWrites == [.mode(fan: 1, value: 0)],
            "the retry wrote above the ceiling")
        #expect(rig.log.lines(containing: "retrying it once (attempt 2)").count == 1)
    }

    // MARK: - A restore before the first step's turn (ADR 0014's #410 ticket-and-seal amendment)

    /// A real restore — it came with § 3's latch — requested after the engagement took its ticket
    /// and before the first step's turn supersedes the step at its admission. The retry's
    /// entitlement refuses on the latch, and nothing is written or undone.
    ///
    /// Until the ticket this was ADR 0009 D1's residual,
    /// `aRestoreBeforeTheFirstStepIsCaughtAfterIt`: the epoch was recorded *at* the first step, so
    /// the step wrote and the after-check undid it.
    /// `EngagementTicketTests.theAfterCheckStillUndoesALatchAfterAdmission` keeps the after-check
    /// covered, since this no longer reaches it.
    ///
    /// **Mutation:** in `PlaneWriteLedger.admitStep(fanAt:)`, admit a first step whatever its
    /// ticket, recording the epoch at admission — the rule before the ticket. Run: red, at the
    /// forward-write assertion.
    @Test("A real restore before the first step's turn is refused at the step's admission")
    func aRestoreBeforeTheFirstStepIsRefusedAtItsAdmission() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.writes.interfere(beforeEngageStep: 1) {
            await rig.engageThermalEmergency()
            _ = try? await rig.plane.restoreToAutomatic(.fan(0))
        }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 0)],
            "a step was written after a restore requested since its ticket")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged.isEmpty, "a fan nothing engaged was registered")
        #expect(await rig.registry.accepted.isEmpty, "an engagement that wrote nothing was undone")
        #expect(rig.log.lines(containing: "Nothing was written").count == 1)
    }

    // MARK: - The lease the engagement runs under (#357)

    /// The lease ends and another is granted over the fan before the first step's turn. The
    /// release's restore is requested after the engagement took its ticket, so the first step is
    /// superseded at its admission; the retry asks about the engagement's own lease, which has
    /// ended, and refuses with nothing written (ADR 0014's #410 ticket-and-seal amendment). A
    /// coverage question would be answered by the new lease, which is why the entitlement names the
    /// lease (#357).
    ///
    /// Until the ticket this was `aReleaseAndRegrantBeforeTheFirstStepIsRefusedAtTheNextStep`:
    /// the first step wrote, the check before step 2 refused, and the step was undone.
    ///
    /// **Mutation:** the rule before the ticket, as above. Run: red, at the forward-write
    /// assertion. **Mutation:** make `requireEntitlement(for:)` ignore the bound lease — ask
    /// whether any live lease covers the fan. Run: red: the retry is admitted under the new lease,
    /// writes, and the engagement runs on to `.engaged` and returns.
    @Test("A release and re-grant before the first step is refused at the step's admission")
    func aReleaseAndRegrantBeforeTheFirstStepIsRefusedAtItsAdmission() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        await rig.writes.interfere(beforeEngageStep: 1) {
            await Self.releaseAndRegrant(fan: 0, on: rig)
        }

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 0)],
            "a step was written after the lease the engagement ran under had ended")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged.isEmpty, "a fan nothing engaged was registered")
        #expect(await rig.registry.accepted.isEmpty, "an engagement that wrote nothing was undone")
    }

    /// The same release and re-grant before a naive firmware's one and only step: superseded at
    /// its admission, and the retry refused on the engagement's own lease, so nothing is written
    /// and nothing reported engaged to a caller whose lease has ended.
    ///
    /// Until the ticket this was `aReleaseAndRegrantBeforeANaiveStepIsUndoneByTheAfterCheck`, and
    /// it was what held the after-check: deleting it then turned this red. The ticket refuses the
    /// step first, so that mutation now survives here, and
    /// `EngagementTicketTests.theAfterCheckStillUndoesALatchAfterAdmission` is what holds it.
    ///
    /// **Mutation:** the rule before the ticket. Run: red, at the forward-write assertion.
    /// **Mutation:** make `requireEntitlement(for:)` ignore the bound lease. Run: red — the retry
    /// writes and the engagement returns.
    @Test("A release and re-grant before a naive step writes nothing")
    func aReleaseAndRegrantBeforeANaiveStepWritesNothing() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.writes.interfere(beforeEngageStep: 1) {
            await Self.releaseAndRegrant(fan: 0, on: rig)
        }

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(
            await rig.plane.keyWrites == [.mode(fan: 0, value: 0)],
            "a step was written after the lease the engagement ran under had ended")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged.isEmpty)
        #expect(await rig.registry.accepted.isEmpty)
    }

    /// The composed driver is bound to no lease, and refuses every step — even with a live
    /// lease over the fan. Binding is the caller's act, so forgetting it fails safe.
    ///
    /// **Mutation:** let an unbound driver through — in `requireEntitlement(for:)`, skip the
    /// lease check when `lease` is `nil`. Run: red: the unbound driver engages the fan.
    @Test("An unbound driver engages nothing")
    func anUnboundDriverEngagesNothing() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        let lease = try #require(rig.lease, "the rig holds no lease, so this proves nothing")
        #expect(await rig.leases.hasLiveLease(id: lease.id, coveringFan: 0))

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.unbound.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.attempts.isEmpty, "an unbound driver issued a step")
        #expect(await rig.registry.engaged.isEmpty)
    }

    /// The rig's lease ends the way a client dying ends it, its restore lands — moving the
    /// epoch, as every lease end's restore does — and another client is granted the fan.
    private static func releaseAndRegrant(fan index: Int, on rig: EngagementRig) async {
        await rig.leases.connectionDidInvalidate(rig.holder)
        do {
            try await rig.plane.restoreToAutomatic(.fan(index))
            _ = try await rig.leases.acquireLease(
                LeaseFixture.request(fans: [index]), from: ConnectionID())
        } catch {
            Issue.record("the release and re-grant failed: \(error)")
        }
    }

    // MARK: - Cancellation, the log, and the constants

    /// A cancelled engagement stops before its next step and undoes the one it took: § 5's
    /// supervisor stopping is a cancellation.
    ///
    /// **Mutation:** delete `try Task.checkCancellation()` from the poll loop. Run: red — the
    /// next step is written by a task that has been cancelled.
    @Test("A cancelled engagement takes no further step and is undone")
    func aCancelledEngagementIsUndone() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        // The hook runs on the engagement's own task, the unstructured one below.
        rig.clock.onSleep(1) { withUnsafeCurrentTask { $0?.cancel() } }
        let engagement = Task { try await rig.driver.engageManualControl(of: rig.fan(0)) }

        await #expect(throws: CancellationError.self) { try await engagement.value }

        let writes = await rig.plane.keyWrites
        #expect(writes.filter { $0 == .mode(fan: 0, value: 1) }.count == 1)
        #expect(writes.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
    }

    /// An undo the firmware accepted raises no fault: `.fault` is for a fan that may be pinned.
    @Test("A successful undo raises no fault")
    func aSuccessfulUndoRaisesNoFault() async throws {
        let rig = try await EngagementRig(unlock: .neverYields)
        await #expect(throws: EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }
        #expect(rig.log.faults.isEmpty, "\(rig.log.faults)")
        #expect(rig.log.lines(containing: "the restore landed").count == 1)
    }

    /// Run 1's figures, pinned where they are defined (ADR 0014 D3): a change is a decision.
    @Test("The poll interval and yield budget are run 1's")
    func theUnlockLimitsAreRunOnes() {
        #expect(UnlockLimits.pollInterval == .milliseconds(100))
        #expect(UnlockLimits.yieldBudget == .milliseconds(3_500))
    }

    /// Forward writes (`F<n>Md = 1`, `Ftst = 1`) after the first occurrence of `marker`.
    private static func forwardWrites(
        after marker: ScriptedControlPlane.KeyWrite, on plane: ScriptedControlPlane
    ) async -> [ScriptedControlPlane.KeyWrite] {
        let writes = await plane.keyWrites
        guard let start = writes.firstIndex(of: marker) else { return [.forceKey(255)] }
        return writes[start...].filter { $0 == .forceKey(1) || $0 == .mode(fan: 0, value: 1) }
    }
}
