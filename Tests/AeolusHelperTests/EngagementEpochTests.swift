import Foundation
import Testing

@testable import AeolusHelper

/// The restore epoch around the driver (ADR 0014 D4): which restores supersede an engagement,
/// the first-step retry that makes a fresh engagement possible after an undo, and the residual
/// the epoch cannot see.
@Suite("The engagement driver and the restore epoch", .timeLimit(.minutes(1)))
struct EngagementEpochTests {

    // MARK: - Every restore supersedes an engagement past its first step

    /// A restore of the engaging fan itself, while it waits for its yield, supersedes it: the
    /// next step writes nothing, and the engagement is undone.
    ///
    /// **Mutation:** in `PlaneWriteLedger.issueRestore(fanAt:)`, erase the fan's in-progress
    /// record (`state.inProgress[index] = nil`), as the first version did. Run: red — the next
    /// step is admitted as a fresh first step and the fan is re-engaged.
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
    /// **Mutation:** in `PlaneWriteLedger.issueMachineWideRestore()`, erase every in-progress
    /// record (`state.inProgress.removeAll()`). Run: red.
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
        await rig.plane.duringNextModeWrite { rig.plane.ledger.restoreRequested() }

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

    // MARK: - The first step, and its retry

    /// An engagement's undo is a restore, so a fresh engagement of the same fan finds the
    /// earlier one's record out of date. Its first step is superseded having written nothing,
    /// and the driver asks the entitlement again and retries it once.
    ///
    /// **Mutation:** make `EngagementDriver.firstStep(of:)` call the step once, with no retry.
    /// Run: red — the second engagement is refused `.superseded` before it starts.
    @Test("A fresh engagement after an undo is not superseded by that undo")
    func aFreshEngagementAfterAnUndoProceeds() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 100))
        for _ in 0..<2 {
            await #expect(throws: EngagementRefusal.yieldDidNotArrive(fan: 0, steps: 35)) {
                try await rig.driver.engageManualControl(of: rig.fan(0))
            }
        }
        // The retried attempt is logged as one (D3 logs every step's attempt), and the steps that
        // ran are counted as before: the superseded attempt wrote nothing.
        #expect(rig.log.lines(containing: "retrying it once (attempt 2)").count == 1)
    }

    /// The retry asks the entitlement first, so a restore that was real — it came with § 3's
    /// latch — refuses it, with nothing written and nothing to undo.
    ///
    /// **Mutation:** delete the `try await requireEntitlement(for: fan)` in
    /// `EngagementDriver.firstStep(of:)`. Run: red — the retry engages above the ceiling.
    @Test("A superseded first step is retried only if the entitlement still holds")
    func theFirstStepRetryAsksTheEntitlement() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 100))
        await #expect(throws: EngagementRefusal.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }
        let before = await rig.plane.keyWrites.count
        await rig.writes.interfere(beforeEngageStep: 36) { await rig.engageThermalEmergency() }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(await rig.plane.keyWrites.count == before, "the retry wrote above the ceiling")
    }

    /// **The residual the epoch cannot see** (ADR 0009 D1): a restore requested before the
    /// first step's turn is not recorded against an engagement that has not begun, so the
    /// first step writes. A real restore ends the lease (immediately before or right after the
    /// restore) or latches § 3, and the driver's check
    /// after the step catches it and undoes — acting and then checking, as D1 prescribes.
    @Test("A real restore before the first step's turn is caught by the check after the step")
    func aRestoreBeforeTheFirstStepIsCaughtAfterIt() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.writes.interfere(beforeEngageStep: 1) {
            await rig.engageThermalEmergency()
            _ = try? await rig.plane.restoreToAutomatic(.fan(0))
        }

        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.keyWrites.contains(.mode(fan: 0, value: 1)), "D1's residual")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged == [0])
        #expect(await rig.registry.accepted == [0])
    }

    // MARK: - The lease the engagement runs under (#357)

    /// The lease ends and another is granted over the fan before the first step's turn: the
    /// release's restore is requested before the step's admission, so the epoch never sees it
    /// (ADR 0009 D1's residual). D4 discharged it with "the driver's next check sees the lease
    /// gone" — which a coverage question answered by the new lease defeated. Asked about the
    /// engagement's own lease, the check before step 2 refuses, and the step taken is undone.
    ///
    /// **Mutation:** make `requireEntitlement(for:)` ignore the bound lease — ask whether any
    /// live lease covers the fan. Run: red: the engagement runs on to `.engaged` and returns.
    @Test("A release and re-grant before the first step is refused at the next step")
    func aReleaseAndRegrantBeforeTheFirstStepIsRefusedAtTheNextStep() async throws {
        let rig = try await EngagementRig(unlock: .heldUntilForced(stepsToYield: 2))
        await rig.writes.interfere(beforeEngageStep: 1) {
            await Self.releaseAndRegrant(fan: 0, on: rig)
        }

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        let writes = await rig.plane.keyWrites
        #expect(
            writes.filter { $0 == .mode(fan: 0, value: 1) }.count == 1,
            "a step was written after the lease the engagement ran under had ended: \(writes)")
        #expect(writes.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)], "nothing was undone")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged == [0], "the fan was not registered before its undo")
        #expect(await rig.registry.accepted == [0])
    }

    /// The same release and re-grant before a naive firmware's one and only step. The step
    /// writes and answers `.engaged`; the after-check asks about the engagement's own lease,
    /// refuses, and the fan is undone rather than reported engaged to a caller whose lease
    /// has ended.
    ///
    /// **Mutation (a):** as above. Run: red — the engagement returns.
    /// **Mutation (b):** delete the after-check, the `try await requireEntitlement(for: fan)`
    /// after `emergency.manualControlEngaged(fan)`. Run: red — the engagement returns.
    @Test("A release and re-grant before a naive step is undone by the after-check")
    func aReleaseAndRegrantBeforeANaiveStepIsUndoneByTheAfterCheck() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.writes.interfere(beforeEngageStep: 1) {
            await Self.releaseAndRegrant(fan: 0, on: rig)
        }

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never arranged the interleaving")
        #expect(await rig.plane.keyWrites.contains(.mode(fan: 0, value: 1)), "D1's residual")
        #expect(try await rig.plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(await rig.registry.engaged == [0])
        #expect(await rig.registry.accepted == [0])
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
