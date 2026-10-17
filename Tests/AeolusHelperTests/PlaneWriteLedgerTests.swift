import Testing

@testable import AeolusHelper

/// `PlaneWriteLedger`'s sets and the scripted unlock model's record of an engagement
/// (ADR 0014 D3, D5): what a restore issues, what the touched set holds, and when a step is a
/// first step.
@Suite("The plane's write ledger", .timeLimit(.minutes(1)))
struct PlaneWriteLedgerTests {

    private static func fan(_ index: Int) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    /// Steps `index` until it engages, giving up after `limit` steps, having taken the
    /// engagement's ticket first as the driver does.
    private static func engage(
        _ index: Int, on plane: ScriptedControlPlane, limit: Int = 6
    ) async throws -> EngagementStep {
        plane.beginEngagement(fanAt: index)
        var last = EngagementStep.awaitingYield
        for _ in 0..<limit {
            last = try await plane.engageManualControl(of: fan(index))
            if last == .engaged { break }
        }
        return last
    }

    /// A plane whose bring-up enumeration failed, so a machine-wide restore can write only
    /// what the touched set names.
    private static func unprepared(
        fans: [Int] = [0], unlock: ScriptedControlPlane.UnlockBehaviour = .naive
    ) async -> ScriptedControlPlane {
        let plane = ScriptedControlPlane(
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .nominal) }),
            unlock: unlock, prepared: false)
        _ = await plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(failure: FakeProviderError(description: "FNum")))
        return plane
    }

    // MARK: - Requested, then issued

    /// D5: the engaged set changes when a restore is **issued**, not when it is requested. Fan
    /// 1's Y-write was admitted before a restore of fan 0 was requested and completes during
    /// that restore's wait for its turn; issued afterwards, the restore finds fan 1 engaged and
    /// leaves the force key it depends on.
    ///
    /// **Mutation:** decide the key's clear in `restoreRequested(_:)` from the engaged set as it
    /// is then, and issue that decision. Run: red.
    @Test("A restore's turn sees an engagement that completed while it waited")
    func aRestoreIsPlannedWhenIssued() throws {
        let ledger = PlaneWriteLedger(enumerated: [0, 1], forceKey: .present)
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first)
        ledger.recordForceKeyWrite(answered: .accepted)
        ledger.recordEngaged(fanAt: 0)
        ledger.beginEngagement(fanAt: 1)
        #expect(try ledger.admitStep(fanAt: 1) == .first)
        #expect(try ledger.admitStep(fanAt: 1) == .continuing)

        ledger.restoreRequested(.fan(0))
        ledger.recordEngaged(fanAt: 1)
        let plan = ledger.plan(for: .fan(0))

        #expect(plan.writes == [.mode(fan: 0)], "the key was cleared while fan 1 depended on it")
        #expect(ledger.isForceKeySet)
        #expect(ledger.engagedFans == [1])
    }

    /// D5's gate, for an engagement that has not joined yet: a restore of fan 0 is requested,
    /// fan 1's first step is then admitted under the **current** epoch, sets the key and awaits
    /// its yield. That restore does not supersede it, so when it is issued it must not clear the
    /// key fan 1 may have set.
    ///
    /// **Mutation:** revert `issueRestore(fanAt:)`'s `clearsKey` to
    /// `state.forceKeySet && state.engaged.isEmpty`. Run: red.
    @Test("A restore's turn leaves the key an engagement under the current epoch may have set")
    func aRestoreLeavesAKeyACurrentEngagementSet() throws {
        let ledger = PlaneWriteLedger(enumerated: [0, 1], forceKey: .present)
        ledger.restoreRequested(.fan(0))
        ledger.beginEngagement(fanAt: 1)
        #expect(try ledger.admitStep(fanAt: 1) == .first)
        ledger.recordForceKeyWrite(answered: .accepted)

        let plan = ledger.plan(for: .fan(0))

        #expect(plan.writes == [.mode(fan: 0)], "the key was cleared under an engagement it began")
        #expect(ledger.isForceKeySet)
    }

    // MARK: - The touched set

    /// A fan is touched from its first mode write, before anything confirms it: an accepted
    /// write that read back no `1` may still have left it off automatic control.
    ///
    /// **Mutation:** delete `ledger.recordModeWriteIssued(fanAt:)` from the scripted mode
    /// write. Run: red — and `PlaneWriteLedger.recordModeWriteIssued(fanAt:)` is the call B1's
    /// production write must make.
    @Test("A fan whose mode write was not confirmed is still written machine-wide")
    func anUnconfirmedModeWriteIsTouched() async throws {
        let plane = await Self.unprepared(unlock: .readsBack(rawMode: 3))
        await #expect(throws: FanControlPlaneError.self) {
            try await plane.ticketedStep(of: Self.fan(0))
        }

        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(await plane.keyWrites.contains(.mode(fan: 0, value: 0)))
    }

    /// An engaged fan is written by a machine-wide restore that cannot enumerate.
    @Test("An engaged fan is written by a machine-wide restore that cannot enumerate")
    func anEngagedFanIsTouched() async throws {
        let plane = await Self.unprepared()
        #expect(try await Self.engage(0, on: plane) == .engaged)

        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await plane.restoreToAutomatic(.everyFan)
        }
        #expect(await plane.keyWrites.contains(.mode(fan: 0, value: 0)))
    }

    /// The touched set never shrinks: a machine-wide restore does not forget it.
    @Test("The touched set survives a machine-wide restore")
    func theTouchedSetNeverShrinks() async throws {
        let plane = await Self.unprepared()
        try await plane.restoreToAutomatic(.fan(0))
        for _ in 0..<2 { _ = try? await plane.restoreToAutomatic(.everyFan) }

        #expect(
            await plane.keyWrites.filter { $0 == .mode(fan: 0, value: 0) }.count == 3,
            "a machine-wide restore forgot fan 0")
    }

    /// A machine-wide restore empties the engaged set and clears the flag, so the unlock
    /// re-runs with no special case after it (D6's post-wake re-acquire).
    @Test("The unlock re-runs after a machine-wide restore")
    func theUnlockReRunsAfterAMachineWideRestore() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal], unlock: .heldUntilForced(stepsToYield: 0))
        #expect(try await Self.engage(0, on: plane) == .engaged)
        #expect(try await Self.engage(1, on: plane) == .engaged)
        try await plane.restoreToAutomatic(.everyFan)
        #expect(plane.ledger.engagedFans.isEmpty)
        #expect(plane.ledger.isForceKeySet == false)

        #expect(try await Self.engage(0, on: plane) == .engaged, "the re-run unlock never yielded")
        try await plane.restoreToAutomatic(.fan(0))

        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(await plane.isForceKeySet == false)
    }

    // MARK: - When a step is a first step

    /// A refused first step ends the engagement, so the next attempt reads the pre-state again
    /// instead of being admitted as a continuation — and writes over nobody's fan.
    @Test("A fan refused as not automatic is refused again")
    func aRefusedStepEndsTheEngagement() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], unlock: .naive)
        await plane.setMode(.manual, ofFan: 0)
        for _ in 0..<2 {
            await #expect(throws: FanControlPlaneError.notAutomatic(index: 0, rawMode: 1)) {
                try await plane.ticketedStep(of: Self.fan(0))
            }
        }
        #expect(await plane.keyWrites.isEmpty, "the second attempt wrote over someone else's fan")
    }

    /// A finished engagement is not a step in progress: engaging an engaged fan again reads the
    /// pre-state, which is no longer `0`.
    @Test("Engaging an already engaged fan reads the pre-state again")
    func anEngagedFanIsNotInProgress() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], unlock: .naive)
        #expect(try await plane.ticketedStep(of: Self.fan(0)) == .engaged)
        await #expect(throws: FanControlPlaneError.notAutomatic(index: 0, rawMode: 1)) {
            try await plane.ticketedStep(of: Self.fan(0))
        }
    }

    // MARK: - The force key

    /// A refused `Ftst = 1` is a refusal, and the plane does not believe it set the key.
    @Test("A refused force-key write is not recorded as set")
    func aRefusedForceKeyWriteIsNotBelieved() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(forceKeyWrites: .refused(reason: "Ftst refused"))],
            unlock: .heldUntilForced(stepsToYield: 0))
        await #expect(throws: FanControlPlaneError.self) {
            try await plane.ticketedStep(of: Self.fan(0))
        }
        #expect(plane.ledger.isForceKeySet == false, "a refused Ftst = 1 was recorded as set")
    }

    /// A force key whose key info would not read is treated as present (D3 step 3).
    @Test("An unknown force key is set when the firmware holds the fan")
    func anUnknownForceKeyIsTreatedAsPresent() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], forceKey: .unknown, unlock: .heldUntilForced(stepsToYield: 0))
        #expect(try await Self.engage(0, on: plane) == .engaged)
        #expect(await plane.keyWrites.contains(.forceKey(1)))
    }
}
