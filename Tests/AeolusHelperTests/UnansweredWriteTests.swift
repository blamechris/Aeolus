import Testing

@testable import AeolusHelper

/// A write the firmware does not answer (B1's P0, #9): `FirmwareWriteAnswer.unanswered`. B1's
/// ruling, from the #410 refused-hand-back amendment's "issued, not landed": an unanswered write
/// is counted as issued and possibly landed, never retried, never read as `0x82`, thrown, and
/// undone. `EngagementRules` decides it for both planes; the scripted one stands in for B1's. The
/// clear a force-key write is owed, whatever it answered, is `ForceKeyIssuedTests`'.
@Suite("A write the firmware does not answer", .timeLimit(.minutes(1)))
struct UnansweredWriteTests {

    /// One state a mode write's answer is decided in.
    struct StepState: Sendable, CustomStringConvertible {
        let firstStep: Bool
        let forceKey: ForceKeyPresence
        let forceKeySet: Bool

        var description: String {
            "first step \(firstStep), force key \(forceKey), set \(forceKeySet)"
        }
    }

    /// Every state a mode write's answer is decided in.
    static let everyStep: [StepState] = [true, false].flatMap { first in
        [ForceKeyPresence.present, .unknown, .absent].flatMap { key in
            [false, true].map { StepState(firstStep: first, forceKey: key, forceKeySet: $0) }
        }
    }

    /// A rig whose firmware leaves the writes `stages` script unanswered.
    private static func rig(
        unlock: ScriptedControlPlane.UnlockBehaviour, stages: [ScriptedControlPlane.Stage]
    ) async throws -> EngagementRig {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: stages, unlock: unlock)
        return try await EngagementRig(
            plane: plane, writes: InterferingFanStateSensing(plane, during: .restoreWrite))
    }

    // MARK: - The rule

    /// D3's rule, over every state: an unanswered mode write throws, a first step's and a
    /// Y-write's alike, with the force key present, unknown or absent, set or clear.
    ///
    /// **Mutation:** in `EngagementRules.afterModeWrite`, read it as `.heldBySystem` — delete its
    /// arm and write `case .heldBySystem, .unanswered:`. Run: red, `.setForceKey` on a first step
    /// with the key present or unknown and clear, and `.awaitYield` on every later step or set key.
    /// **Mutation:** retry it — `case .unanswered: return .awaitYield`. Run: red on every row.
    @Test("An unanswered mode write throws on every step")
    func anUnansweredModeWriteThrowsOnEveryStep() {
        for state in Self.everyStep {
            #expect(
                throws: FanControlPlaneError.self, "\(state)",
                performing: {
                    try EngagementRules.afterModeWrite(
                        .unanswered(detail: "no reply"), firstStep: state.firstStep,
                        forceKey: state.forceKey, forceKeySet: state.forceKeySet)
                })
        }
    }

    // MARK: - Through the driver

    /// A first step's mode write goes unanswered, landed or not: the engagement is refused with
    /// no retry and no force key, and the fan is undone, as a write that may have landed is.
    ///
    /// **Mutations:** `afterModeWrite`'s two above. Run: red — with it held, the step sets the
    /// key and polls; retried, it polls until the budget runs out.
    @Test(
        "A first mode write left unanswered is refused once, and undone",
        arguments: [ScriptedControlPlane.UnansweredWrite.landed, .lost])
    func anUnansweredFirstModeWriteIsUndone(
        _ write: ScriptedControlPlane.UnansweredWrite
    ) async throws {
        let rig = try await Self.rig(
            unlock: .naive, stages: [.nominal().leavingModeWriteUnanswered(ofFan: 0, write)])

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(await rig.plane.keyWrites == [.mode(fan: 0, value: 1), .mode(fan: 0, value: 0)])
        #expect(rig.clock.sleeps.isEmpty, "an unanswered write was retried")
        #expect(try await rig.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await rig.registry.engaged == [0], "§ 3 was not told before the undo")
        #expect(rig.plane.ledger.touchedFans == [0])
    }

    /// A Y-write goes unanswered after the force key was set: refused without another step, and
    /// undone with the key cleared.
    ///
    /// **Mutations:** `afterModeWrite`'s two above. Run: red — the later step awaits its yield,
    /// and the driver polls again.
    @Test("A Y-write left unanswered is refused without another step, and undone")
    func anUnansweredYWriteIsUndone() async throws {
        let rig = try await Self.rig(
            unlock: .heldUntilForced(stepsToYield: 3),
            stages: [.nominal(), .nominal().leavingModeWriteUnanswered(ofFan: 0, .landed)])
        let plane = rig.plane
        rig.clock.onSleep(1) { await plane.advance() }

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(
            await rig.plane.keyWrites == [
                .mode(fan: 0, value: 1), .forceKey(1), .mode(fan: 0, value: 1),
                .mode(fan: 0, value: 0), .forceKey(0),
            ])
        #expect(rig.clock.sleeps == [UnlockLimits.pollInterval], "the write was retried")
        #expect(try await rig.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await rig.plane.isForceKeySet == false)
    }

    /// The engagement's `Ftst = 1` goes unanswered, landed or not: the step throws, and the undo
    /// clears the key as well as the mode, because the key may have been set.
    ///
    /// **Mutation:** in `ScriptedControlPlane`, record the force key only once `Ftst = 1` was
    /// accepted — after `afterForceKeyWrite` returns. Run: red — the undo writes no `Ftst = 0`, and
    /// a landed key stays set.
    @Test(
        "A force-key write left unanswered is undone with the key cleared",
        arguments: [ScriptedControlPlane.UnansweredWrite.landed, .lost])
    func anUnansweredForceKeyWriteIsUndone(
        _ write: ScriptedControlPlane.UnansweredWrite
    ) async throws {
        let rig = try await Self.rig(
            unlock: .heldUntilForced(stepsToYield: 1),
            stages: [.nominal().leavingForceKeyWriteUnanswered(write)])

        await #expect(throws: FanControlPlaneError.self) {
            try await rig.driver.engageManualControl(of: rig.fan(0))
        }

        #expect(
            await rig.plane.keyWrites == [
                .mode(fan: 0, value: 1), .forceKey(1), .mode(fan: 0, value: 0), .forceKey(0),
            ])
        #expect(await rig.plane.isForceKeySet == false, "a key the write may have set was left")
        #expect(rig.plane.ledger.isForceKeySet == false)
        #expect(rig.clock.sleeps.isEmpty)
    }
}
