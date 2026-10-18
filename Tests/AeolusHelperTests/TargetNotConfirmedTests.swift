import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// A target the firmware does not hold at its command's in-turn read-back (B1's P0, #9): the
/// scripted double's two target behaviours, and how every caller of a command routes
/// `FanControlPlaneError.targetNotConfirmed` — level 6 by item 5's table, § 5's re-assert and § 3's
/// `fire` exactly as they route a refused command.
///
/// Unreachable on every shipped build: a `.notBuilt` plane commands nothing. B1's command turn is
/// what will throw it, for a read-back outside `ReclamationLimits.targetToleranceRPM` (ADR 0004;
/// ADR 0014 D7, U4); here `Stage.targetsNotHeldAtReadBack` stands in for that firmware.
@Suite("A target the firmware does not hold at its read-back", .timeLimit(.minutes(1)))
struct TargetNotConfirmedTests {

    /// A permit for fan 0 at 2,400 RPM, through its declared envelope.
    private static func target(_ rpm: Double = 2_400) throws -> AuthorisedFanTarget {
        try commandableFan(0, declaring: .held(at: 1_800)).target(for: rpm)
    }

    /// What `commandTarget` answered, or `nil` when it returned.
    private static func outcome(
        of plane: ScriptedControlPlane, commanding rpm: Double = 2_400
    ) async throws -> (any Error)? {
        let target = try target(rpm)
        do {
            try await plane.commandTarget(target)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The scripted double

    /// `.reverted` is a target held at the read-back and discarded after it: the command returns
    /// the requested value, and only a later read sees the old target. A fan not held at the
    /// read-back keeps its old target there too, and the command throws `.targetNotConfirmed`
    /// carrying what it read. Both writes were issued.
    ///
    /// **Mutation:** in `ScriptedControlPlane.writeTarget(_:)`, swap the two — guard on
    /// `behaviour == .reverted` in place of `stage.targetsNotHeldAtReadBack.contains(index)`, so
    /// `.reverted` throws and the fan not held is honoured. Run: red on both planes' outcomes.
    @Test("A target not held at its read-back throws; a reverted one returns what was asked")
    func aTargetNotHeldThrowsAndARevertedOneReturns() async throws {
        let reverted = ScriptedControlPlane(
            fans: [0: .held(at: 1_800)], stages: [.nominal(targetWrites: .reverted)])
        let notHeld = ScriptedControlPlane(
            fans: [0: .held(at: 1_800)], stages: [.nominal().holdingNoTarget(ofFan: 0)])

        let returned = try await Self.outcome(of: reverted)
        let thrown = try await Self.outcome(of: notHeld)

        #expect(returned == nil, "a target held at its read-back threw \(returned as Any)")
        #expect(
            thrown as? FanControlPlaneError
                == .targetNotConfirmed(index: 0, commandedRPM: 2_400, readBackRPM: 1_800),
            "a target not held at its read-back answered \(thrown as Any)")
        for plane in [reverted, notHeld] {
            #expect(await plane.keyWrites == [.target(fan: 0, rpm: 2_400)])
            #expect(
                try await plane.readControlState(ofFan: 0).target == .rpm(1_800),
                "the firmware kept a target it was scripted to discard")
        }
    }

    /// A refusal is answered before any read-back: a fan not held at its read-back, on a stage
    /// that refuses the write, throws the refusal.
    ///
    /// **Mutation:** in `writeTarget(_:)`, delete `_ = try lands(behaviour)`. Run: red, the
    /// refused write answered `.targetNotConfirmed`.
    @Test("A refused target write is refused before its read-back")
    func aRefusedTargetIsRefusedFirst() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 1_800)],
            stages: [
                .nominal(targetWrites: .refused(reason: "F0Tg refused")).holdingNoTarget(ofFan: 0)
            ])

        let thrown = try await Self.outcome(of: plane)

        #expect(
            thrown as? FanControlPlaneError == .firmwareRefusedControl(detail: "F0Tg refused"),
            "the refusal answered \(thrown as Any)")
    }

    // MARK: - Level 6: item 5's row

    /// Item 5's row, as a value: `notConfirmed`'s `helperFailed`, the answer an engagement whose
    /// mode did not read back gets, so no new reason crosses the boundary and v1 clients render it.
    ///
    /// **Mutation:** drop `.targetNotConfirmed` from `LeaseApplyRules.answer(to:)`'s
    /// `.engagementNotConfirmed` row, so it falls to the residue. Run: red, `Detail.unexpected`.
    @Test("Item 5's table answers a target not confirmed as helperFailed, notConfirmed")
    func theAnswerRow() {
        let error = FanControlPlaneError.targetNotConfirmed(
            index: 0, commandedRPM: 2_400, readBackRPM: 1_800)

        #expect(
            LeaseApplyRules.answer(to: error)
                == .fault(.helperFailed(detail: LeaseApplyRules.Detail.notConfirmed)))
        #expect(
            LeaseApplyRules.answer(to: EngagementUndoRefused(fan: 0, cause: error))
                == .fault(.helperFailed(detail: LeaseApplyRules.Detail.notConfirmed)),
            "a refused undo was not answered by its cause")
    }

    /// Through the real level 6: a fan engaged and then not held at its command's read-back is
    /// answered `helperFailed` with `notConfirmed`'s detail, which v1 clients already render, and
    /// is handed back as a half-landed engagement is.
    ///
    /// **Mutation:** drop `.targetNotConfirmed` from `LeaseApplyRules.answer(to:)`'s
    /// `.engagementNotConfirmed` row. Run: red, answered with `Detail.unexpected`.
    @Test("Level 6 answers a target not held at its read-back helperFailed, and hands it back")
    func levelSixAnswersNotConfirmed() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [0: .automatic(at: 1_800)]
        let plane = ScriptedControlPlane(fans: fans, stages: [.nominal().holdingNoTarget(ofFan: 0)])
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0]).id

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.notConfirmed)
        ) {
            try await machine.levelSix().apply(fixed((0, 2_400)), under: lease)
        }
        #expect(await plane.keyWrites.contains(.target(fan: 0, rpm: 2_400)), "nothing commanded")
        #expect(await machine.didRestore(fan: 0), "the fan was left off automatic control")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    // MARK: - § 5's re-assert and § 3's fire route it as a refused command

    /// A refused target write, and one the firmware does not hold at its read-back.
    static let unconfirmedCommands: [ScriptedControlPlane.Stage] = [
        .nominal(targetWrites: .refused(reason: "F0Tg refused")),
        .nominal().holdingNoTarget(ofFan: 0),
    ]

    /// § 5's re-assert re-engages a reclaimed fan and its command is not confirmed: half-landed,
    /// so the fan is restored at once, labelled reclaimed by the system, and no attempt is retried
    /// — what `ReclamationWatchdogRecoveryTests.aHalfLandedReassertRestoresImmediately` pins for a
    /// refused command, for both.
    ///
    /// **Mutation:** in `ReclamationWatchdog.reassert`, before the command write's `catch`, add
    /// `catch FanControlPlaneError.targetNotConfirmed(let fan, let rpm, _) { recommanded =
    /// CommandedTarget(fanIndex: fan, rpm: rpm) }`. Run: red on the not-held argument.
    @Test(
        "§ 5's re-assert routes a target not held at its read-back as a refused command",
        arguments: unconfirmedCommands)
    func theReassertRoutesItAsARefusedCommand(_ stage: ScriptedControlPlane.Stage) async throws {
        let machine = ReclamationMachine(stages: [stage], fans: [0: .automatic(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        await machine.watchdog.cycle()

        #expect(await machine.attempts.contains(.engageManualControl(fan: 0)))
        #expect(await machine.commandedRPMs == [2_400])
        #expect(await machine.didRestore(fan: 0), "a fan was left holding a target nobody chose")
        #expect(machine.safetyLog.lines(containing: "could not command a target").count == 1)
        #expect(machine.safetyLog.lines(containing: "re-asserted").isEmpty)
        #expect(await machine.restorer.causes == [.systemReclaimed])
        #expect(await machine.watchdog.fansUnderManualControl.isEmpty)
    }

    /// § 3's bridge whose maximum is not confirmed is reported at `.fault` and still restored —
    /// what `ThermalEmergencyTests.aRefusedMaximumStillRestores` pins for a refused write, for
    /// both, and never logged as a maximum commanded.
    ///
    /// **Mutation:** in `ThermalEmergency.bridgeToMaximumThenRelease(_:)`, add `catch
    /// FanControlPlaneError.targetNotConfirmed(let index, let rpm, _) {
    /// log.emergencyCommandedMaximum(fan: index, rpm: rpm) }` before its first `catch`. Run: red on
    /// the not-held argument.
    @Test(
        "§ 3's fire routes a maximum not held at its read-back as a refused write",
        arguments: unconfirmedCommands)
    func fireRoutesItAsARefusedWrite(_ stage: ScriptedControlPlane.Stage) async throws {
        var hot = stage
        hot.temperatures = ScriptedControlPlane.Stage.at(96).temperatures
        let machine = ThermalMachine(stages: [.at(44), hot])
        try await machine.lease(fans: [0])
        await machine.plane.advance()

        await machine.emergency.cycle()

        let writes: [ScriptedControlPlane.Attempt] = await machine.writes
        #expect(writes == [.commandTarget(fan: 0, rpm: 5_777), .restoreToAutomatic(.fan(0))])
        #expect(await machine.latch.isActive)
        #expect(
            machine.safetyLog.faults.filter { $0.contains("could not command maximum on fan 0") }
                .count == 1)
        #expect(machine.safetyLog.lines(containing: "commanded fan 0 to").isEmpty)
    }
}
