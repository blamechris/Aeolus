import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The engaged turn's floor hold on the production plane (ADR 0014's P1′ amendment, decision 4),
/// over `FirmwareSMC` scripted in Apple's two states as P1 recorded them on `Mac16,5`: stopped at
/// rest, raw `F<n>Md = 3` with target 0, and spinning under load, raw `0` with a target at or
/// above the floor. `EngagedTargetRuleTests` pins the same rule on the scripted plane, and
/// `WritePlaneContractTests` runs both planes through one contract.
extension SMCWritePlaneTests {

    static let targetOne = smcKey("F1Tg")

    /// `Mac16,5`'s floor, `F0Mn` 1350 RPM, as the fake's `flt` bytes.
    static let floorBytes = FirmwareSMC.flt(rpm: 1_350)

    /// A write as `WritePlaneFixture.writes(since:)` spells it: `key=bytes`.
    static func written(_ key: SMCKey, _ bytes: [UInt8]) -> String {
        "\(key.rawValue)=\(bytes.map { String($0) }.joined(separator: ","))"
    }

    // MARK: - At rest: the raise

    /// A fan Apple has stopped is engaged and raised in one turn of eight round trips: the mode
    /// key's info, the pre-state `3`, the mode write, its read-back of `1`, the target's read of
    /// 0, the target's fresh key info, the floor's write and its read-back. The fan is engaged,
    /// its target is the floor, and the line records the raw target, the floor and the answer.
    ///
    /// **Mutation:** in `SMCWriteTurns.step`, delete `try holdFloor(of: fan, log: log, on:
    /// channel)`. Run: red here, at the operations, the register and the line.
    @Test("An engagement at rest raises the target to the floor in the engaging turn")
    func anEngagementAtRestRaisesTheTarget() async throws {
        let fixture = WritePlaneFixture(stoppedByApple: [0, 1])
        let mark = await fixture.prepared()

        try await fixture.engage(0)

        #expect(
            fixture.operations(since: mark) == [
                .keyInfo(Self.modeZero, .answered), .read(Self.modeZero, .answered),
                .write(Self.modeZero, [0x01], .answered), .read(Self.modeZero, .answered),
                .read(Self.targetZero, .answered), .keyInfo(Self.targetZero, .answered),
                .write(Self.targetZero, Self.floorBytes, .answered),
                .read(Self.targetZero, .answered),
            ])
        // Eight with the target's key info cached, as preparation leaves it; the cold nine, the
        // bound itself, is `everyTurnStaysWithinItsRoundTrips`'.
        #expect(fixture.roundTripsPerTurn(since: mark) == [8])
        #expect(await fixture.firmware.register(Self.targetZero) == Self.floorBytes)
        #expect(try fixture.ledger.engagedFans == [0])
        #expect(
            fixture.lines.lines(
                containing:
                    "Fan 0 read back engaged with raw F0Tg 0x0 0x0 0x0 0x0: the raise to its "
                    + "floor, 1350 RPM, answered 0x00 and read back 1350.0 RPM."
            ).count == 1, "\(fixture.lines.lines)")
    }

    /// ADR 0014's P1′ U7/1d record, on the real plane: fan 0 engaged at rest under the force key
    /// and then commanded, with fan 1 in Apple's rest state beside it. The whole log of firmware
    /// operations, by exact equality, is fan 0's: the held first write (`0x82`), `Ftst = 1`, a
    /// later step still held, the yield, the read-back of `1`, the target's read, the floor's
    /// write and its read-back, and the command. **No `F1` key is written**, and fan 1 still
    /// reads raw `3` with target 0. Run 1's 1d is void if a helper write names an `F1` key.
    ///
    /// **Mutation:** in `SMCWriteTurns.holdFloor`, after the raise, also write the floor to fan 1:
    /// `_ = try writeTarget(TargetCommand(fan: 1, rpm: floor.rpm, floor:
    /// floor.lowestCommandableRPM), log: log, on: channel)`. Run: red here, at the operations, the
    /// `F1` writes and fan 1's target.
    @Test("Engaged at rest under the force key, the whole log is fan 0's and names no F1 key")
    func anEngagementAtRestWritesOnlyItsOwnFan() async throws {
        let fixture = WritePlaneFixture(
            unlock: .heldUntilForced(stepsToYield: 1), stoppedByApple: [0, 1])
        let mark = await fixture.prepared()

        try await fixture.engage(0)
        try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))

        let held = FirmwareLog.Answer.threw(.firmware(code: 0x82))
        let stepHead: [FirmwareLog.Entry] = [
            .keyInfo(Self.modeZero, .answered), .read(Self.modeZero, .answered),
        ]
        #expect(
            fixture.operations(since: mark)
                == stepHead + [
                    .write(Self.modeZero, [0x01], held),
                    .keyInfo(Self.forceKey, .answered), .write(Self.forceKey, [0x01], .answered),
                ] + stepHead + [.write(Self.modeZero, [0x01], held)] + stepHead + [
                    .write(Self.modeZero, [0x01], .answered), .read(Self.modeZero, .answered),
                    .read(Self.targetZero, .answered), .keyInfo(Self.targetZero, .answered),
                    .write(Self.targetZero, Self.floorBytes, .answered),
                    .read(Self.targetZero, .answered),
                    .keyInfo(Self.targetZero, .answered),
                    .write(Self.targetZero, FirmwareSMC.flt(rpm: 2_400), .answered),
                    .read(Self.targetZero, .answered),
                ])
        let writes = fixture.writes(since: mark)
        #expect(writes.filter { $0.hasPrefix("F1") }.isEmpty, "\(writes)")
        #expect(await fixture.firmware.register(Self.modeOne) == [0x03])
        #expect(await fixture.firmware.register(Self.targetOne) == FirmwareSMC.flt(rpm: 0))
    }

    /// The raise belongs to the turn that read back `1`, and to no other (#637's P9, on the real
    /// plane). A fan Apple has stopped whose mode write is accepted but reads back `3` is not
    /// engaged: the step throws on the read-back, before any target is read or written.
    ///
    /// **Mutation:** move the floor hold ahead of the read-back — in `SMCWriteTurns.unlockStep`'s
    /// `.readBack` case, call `holdFloor` before `rawByte(of: modeKey, on: channel)`, passing the
    /// permit through. Run: red here, at the writes.
    @Test("No target is written unless the read-back confirmed the engagement")
    func noTargetIsWrittenWithoutAConfirmedEngagement() async throws {
        let fixture = WritePlaneFixture(unlock: .readsBack(rawMode: 3), stoppedByApple: [0])
        let mark = await fixture.prepared()

        fixture.plane.beginEngagement(fanAt: 0)
        await #expect(throws: FanControlPlaneError.engagementNotConfirmed(index: 0, rawMode: 3)) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }

        #expect(fixture.writes(since: mark) == ["F0Md=1"], "a target was written")
        #expect(
            !fixture.operations(since: mark).contains { $0 == .read(Self.targetZero, .answered) },
            "the target was read before the read-back confirmed the engagement")
        #expect(try fixture.ledger.engagedFans.isEmpty)
    }

    /// The floor is the permit's, never below `FanSafetyLimits.minimumManualRPM`: a fan whose
    /// permit declares a minimum of 0 is raised to 100 RPM at rest, never left at 0.
    ///
    /// **Mutation:** in `SMCWriteTurns.holdFloor`, raise to the declared minimum —
    /// `TargetCommand(fan: floor.fanIndex, rpm: fan.envelope.declaredMinimumRPM, floor:
    /// fan.envelope.declaredMinimumRPM)`. Run: red here: `writeTarget`'s own floor refuses 0, so
    /// the step throws rather than engaging.
    @Test("A fan declaring a minimum of 0 is raised to the manual minimum, never left at 0")
    func theFloorIsNeverBelowTheManualMinimum() async throws {
        let fixture = WritePlaneFixture(stoppedByApple: [0])
        let mark = await fixture.prepared()
        let permit = try commandableFan(0, declaring: .zeroMinimum)

        fixture.plane.beginEngagement(fanAt: 0)
        #expect(try await fixture.plane.engageManualControl(of: permit) == .engaged)

        let manualMinimum = FirmwareSMC.flt(rpm: Float(FanSafetyLimits.minimumManualRPM))
        #expect(
            fixture.writes(since: mark) == ["F0Md=1", Self.written(Self.targetZero, manualMinimum)])
        #expect(await fixture.firmware.register(Self.targetZero) == manualMinimum)
    }

    // MARK: - Under load: nothing more

    /// Engaging while Apple spins the fan: its target is at or above the floor, so the step
    /// writes only the mode, in five round trips, and the target is as Apple left it. 1350 is P1's
    /// twelve-way load, at exactly the floor; 3455 its sixteen-way plateau.
    ///
    /// **Mutation:** in `SMCWriteTurns.holdFloor`, raise unconditionally — write
    /// `fan.target(for: fan.envelope.lowestCommandableRPM)` whatever the rule answered. Run: red
    /// here, on both arguments.
    @Test(
        "An engagement under load keeps Apple's target, and nothing more is written",
        arguments: [Float(1_350), 3_455])
    func anEngagementUnderLoadWritesNoTarget(_ rpm: Float) async throws {
        let fixture = WritePlaneFixture()
        await fixture.firmware.spinByApple(fan: 0, at: rpm)
        let mark = await fixture.prepared()

        try await fixture.engage(0)

        #expect(fixture.writes(since: mark) == ["F0Md=1"])
        #expect(fixture.roundTripsPerTurn(since: mark) == [5])
        #expect(await fixture.firmware.register(Self.targetZero) == FirmwareSMC.flt(rpm: rpm))
        #expect(try fixture.ledger.engagedFans == [0])
    }

    // MARK: - A floor the firmware does not take

    /// A floor the firmware refuses, leaves unanswered, or accepts and does not hold at the
    /// read-back fails the step with that answer, after the floor's write: the step is recorded
    /// refused, the fan is never engaged, and the driver undoes (`WritePlaneContractTests`).
    ///
    /// **Mutation:** in `SMCWriteTurns.writeTarget`, compare the read-back against `.infinity`.
    /// Run: red here, on the not-held row.
    @Test(
        "A floor the firmware refuses, leaves unanswered, or does not hold fails the step",
        arguments: [
            FirmwareSMC.WriteAnswer.refuses(code: 0x85), .acceptsWithoutApplying,
            .unanswered(.truncatedReply(expected: 80, received: 0), applied: true),
        ])
    func aFloorTheFirmwareDoesNotTakeFailsTheStep(_ answer: FirmwareSMC.WriteAnswer) async throws {
        let fixture = WritePlaneFixture(stoppedByApple: [0])
        let mark = await fixture.prepared()
        await fixture.firmware.queueWrites(to: Self.targetZero, [answer])
        let ledger = try fixture.ledger

        fixture.plane.beginEngagement(fanAt: 0)
        let error = await #expect(throws: FanControlPlaneError.self) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }

        switch answer {
        case .acceptsWithoutApplying:
            #expect(
                error == .targetNotConfirmed(index: 0, commandedRPM: 1_350, readBackRPM: 0),
                "\(String(describing: error))")
        default:
            #expect(error.map(Self.isRefusedControl) == true, "\(String(describing: error))")
        }
        #expect(
            fixture.writes(since: mark) == [
                "F0Md=1", Self.written(Self.targetZero, Self.floorBytes),
            ])
        #expect(ledger.engagedFans.isEmpty, "\(answer)")
        #expect(!ledger.isCurrent(fanAt: 0), "\(answer): the step was not recorded refused")
        #expect(
            fixture.lines.lines(containing: "the raise to its floor, 1350 RPM, threw").count == 1,
            "\(fixture.lines.lines)")
    }
}
