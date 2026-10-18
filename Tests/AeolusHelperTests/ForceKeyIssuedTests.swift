import Testing

@testable import AeolusHelper

/// Every issued `Ftst = 1` is owed a clear, whatever the firmware answered (B1's P0, #9; ADR 0014's
/// B1 amendment, superseding D5's "accepted"). A refusal, like a lost answer, does not prove the
/// register unchanged — the #410 refused-hand-back amendment's "issued, not landed" — so the
/// ledger records the key as set from the moment the plane issues the write, and the restore that
/// undoes the engagement clears it once no engaged fan depends on it (D5's gate).
@Suite("A force-key write is owed a clear, whatever it answered", .timeLimit(.minutes(1)))
struct ForceKeyIssuedTests {

    /// Every answer `Ftst = 1` can get on a scripted stage: accepted, accepted and discarded,
    /// refused, and unanswered, landed or lost.
    static let everyAnswer: [ScriptedControlPlane.Stage] = [
        .nominal(),
        .nominal(forceKeyWrites: .reverted),
        .nominal(forceKeyWrites: .refused(reason: "Ftst refused")),
        .nominal().leavingForceKeyWriteUnanswered(.landed),
        .nominal().leavingForceKeyWriteUnanswered(.lost),
    ]

    /// A rig whose firmware is `stages`, its plane's steps observed at `moment`.
    private static func rig(
        fans: [Int] = [0], stages: [ScriptedControlPlane.Stage],
        unlock: ScriptedControlPlane.UnlockBehaviour,
        during moment: InterferingFanStateSensing.Moment = .refusedEngageStep
    ) async throws -> EngagementRig {
        let plane = ScriptedControlPlane(
            fans: Dictionary(uniqueKeysWithValues: fans.map { ($0, .nominal) }), stages: stages,
            unlock: unlock)
        return try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: moment), fans: fans)
    }

    // MARK: - The plane's record

    /// Whatever `Ftst = 1` answers, the ledger records the key as one a restore must clear, and
    /// the next restore of the fan clears it.
    ///
    /// **Mutation:** in `ScriptedControlPlane`, record the force key only once `Ftst = 1` was
    /// accepted — move `ledger.recordForceKeyIssued()` out of `answerForceKeyWrite()` to after
    /// `EngagementRules.afterForceKeyWrite` returns. Run: red on the refused and unanswered rows.
    @Test("Every issued force-key write is owed a clear", arguments: everyAnswer)
    func everyIssuedForceKeyWriteIsOwedAClear(_ stage: ScriptedControlPlane.Stage) async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], stages: [stage], unlock: .heldUntilForced(stepsToYield: 1))
        let fan = try commandableFan(0, declaring: .nominal)

        _ = try? await plane.ticketedStep(of: fan)

        #expect(await plane.keyWrites == [.mode(fan: 0, value: 1), .forceKey(1)])
        #expect(plane.ledger.isForceKeySet, "an issued Ftst = 1 was not recorded as owed a clear")
        plane.ledger.restoreRequested(.fan(0))
        #expect(plane.ledger.plan(for: .fan(0)).writes == [.mode(fan: 0), .forceKey])
    }

    // MARK: - Through the driver

    /// Fan 0's `Ftst = 1` is refused, with no other fan engaged, and the driver's undo clears the
    /// key as well as the mode. When the refused write did land, as a refusal does not rule out,
    /// the undo is what puts the key back.
    ///
    /// **Mutation:** the acceptance-only record above. Run: red — the undo writes no `Ftst = 0`,
    /// and a landed key stays set.
    @Test(
        "A refused force-key write is undone with the key cleared", arguments: [true, false])
    func aRefusedForceKeyWriteIsUndone(landed: Bool) async throws {
        let rig = try await Self.rig(
            stages: [.nominal(forceKeyWrites: .refused(reason: "Ftst refused")), .nominal()],
            unlock: .heldUntilForced(stepsToYield: 1))
        let plane = rig.plane
        // After the refusal and before the undo: the write landed or not, and the next writes
        // are honoured, so the undo's own answer is not what this test reads.
        await rig.writes.interfere {
            if landed { await plane.setForceKey(true) }
            await plane.advance()
        }

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never reached the refused step")
        #expect(
            await plane.keyWrites == [
                .mode(fan: 0, value: 1), .forceKey(1), .mode(fan: 0, value: 0), .forceKey(0),
            ])
        #expect(await plane.isForceKeySet == false, "a key the refused write set was left set")
        #expect(plane.ledger.isForceKeySet == false)
        #expect(await rig.registry.engaged == [0])
        #expect(await rig.registry.accepted == [0])
    }

    /// With fan 1 engaged, fan 0's refused `Ftst = 1` is undone by its mode alone — the key is
    /// never cleared under an engaged fan (D5's gate) — and the clear stays owed: fan 1's hand-back
    /// writes it.
    ///
    /// Fan 1 engages without writing the key, because the firmware's key was already set, as a
    /// dead helper leaves it; the key then drops, as sleep resets it (U12), so fan 0's first step
    /// is held and issues `Ftst = 1`.
    ///
    /// **Mutation:** the acceptance-only record above. Run: red — fan 1's hand-back writes no
    /// `Ftst = 0`. **Mutation:** in `PlaneWriteLedger.issueRestore(fanAt:)`, drop
    /// `state.engaged.isEmpty` from `clearsKey`. Run: red — fan 0's undo clears the key under
    /// fan 1.
    @Test("Under another engaged fan, the clear waits for that fan's hand-back")
    func theClearWaitsForTheLastEngagedFan() async throws {
        let rig = try await Self.rig(
            fans: [0, 1],
            stages: [.nominal(forceKeyWrites: .refused(reason: "Ftst refused")), .nominal()],
            unlock: .heldUntilForced(stepsToYield: 0))
        let plane = rig.plane
        await plane.setForceKey(true)
        try await rig.driver.engageManualControl(of: rig.fan(1))
        await plane.setForceKey(false)
        await rig.writes.interfere { await plane.advance() }

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.writes.didFire, "the scenario never reached the refused step")
        #expect(
            await plane.keyWrites == [
                .mode(fan: 1, value: 1), .mode(fan: 0, value: 1), .forceKey(1),
                .mode(fan: 0, value: 0),
            ],
            "fan 0's undo cleared the key under fan 1, or fan 1 wrote a key of its own")
        #expect(plane.ledger.engagedFans == [1])
        #expect(plane.ledger.isForceKeySet, "the clear fan 0's write is owed was dropped")

        try await rig.driver.handBack(fanAt: 1)

        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 1, value: 0), .forceKey(0)])
        #expect(plane.ledger.isForceKeySet == false)
    }
}
