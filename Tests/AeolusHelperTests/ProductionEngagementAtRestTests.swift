import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// Engagements at rest through the composed graph — `apply`, `LeaseApplier`, `EngagementDriver`,
/// and the **production** plane over `FirmwareSMC` (ADR 0014's P1′ amendment, decision 4). The
/// plane's own tests drive its verbs directly, and the contract suite issues the undo by hand; this
/// holds what the driver and level 6 do around the engaged turn's floor hold.
@Suite("Engagements at rest, over the composed production machine", .timeLimit(.minutes(1)))
struct ProductionEngagementAtRestTests {

    static let modeZero = smcKey("F0Md")
    static let targetZero = smcKey("F0Tg")
    static let modeOne = smcKey("F1Md")
    static let targetOne = smcKey("F1Tg")

    /// How the firmware answers the floor's write.
    enum FloorFailure: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Refused with a result byte.
        case refused
        /// Accepted, and not held at the read-back: `.targetNotConfirmed`.
        case acceptedNotApplied
        /// No answer, and not landed.
        case unanswered

        var answer: FirmwareSMC.WriteAnswer {
            switch self {
            case .refused: return .refuses(code: 0x85)
            case .acceptedNotApplied: return .acceptsWithoutApplying
            case .unanswered:
                return .unanswered(.truncatedReply(expected: 80, received: 0), applied: false)
            }
        }

        var testDescription: String { rawValue }
    }

    /// A write as the machine spells it: `key=bytes`.
    static func written(_ key: SMCKey, _ bytes: [UInt8]) -> String {
        "\(key.rawValue)=\(bytes.map { String($0) }.joined(separator: ","))"
    }

    /// A floor the firmware does not take fails the step after its mode write, and the **driver's
    /// own undo**, on the production path, hands the fan back: the `apply` is refused, the writes
    /// are the mode, the floor and the undo's `F0Md = 0`, and the fan reads automatic again. That
    /// the step's throw reaches the undo — and is not taken as one that wrote nothing — is what
    /// keeps a fan from staying in manual control at Apple's target of 0.
    ///
    /// **Mutations:** in `EngagementDriver.engageManualControl(of:)`, replace `try await
    /// handBack(fanAt: index)` with `_ = index`. Run: red here, on every row: no `F0Md = 0`, and
    /// the fan stays at raw `1`. In `EngagementDriver.wroteNothing`, add `.targetNotConfirmed?` to
    /// the cases that wrote nothing. Run: red here, on the acceptedNotApplied row.
    @Test(
        "A floor refused, not held or unanswered is handed back by the driver's undo",
        arguments: FloorFailure.allCases)
    func theDriverUndoesAFloorNotTaken(_ failure: FloorFailure) async throws {
        let machine = await ProductionWriteMachine(stoppedByApple: [0, 1])
        let lease = try await machine.lease()
        await machine.firmware.queueWrites(to: Self.targetZero, [failure.answer])
        let mark = machine.firmware.log.entries.count

        let refused = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        #expect(refused != nil, "\(failure): the apply whose floor failed was answered applied")
        let floor = Self.written(Self.targetZero, FirmwareSMC.flt(rpm: 1_350))
        #expect(
            machine.writes(since: mark) == ["F0Md=1", floor, "F0Md=0"],
            "\(failure): \(machine.writes(since: mark))")
        #expect(
            await machine.firmware.register(Self.modeZero) == [0x00],
            "\(failure): the fan was not handed back")
        #expect(
            try await machine.plane.readControlState(ofFan: 0).mode == .automatic,
            "\(failure): the fan does not read automatic")
    }

    /// Both fans engaged at rest in one lease, as `fanctl set all` takes them — and, if U7 fails,
    /// the only lease shape (ADR 0014's P1′ amendment). Each fan is engaged and commanded in turn
    /// under the force-key path (`heldUntilForced(stepsToYield: 1)`). The whole write log, by exact
    /// equality and with each answer: fan 0's held first write, then `Ftst = 1`, written once and
    /// only there; fan 0's held later step, its accepted write, **its own floor** and its command;
    /// then fan 1's first write, held under the key and writing no second `Ftst`, its accepted
    /// write, **its own floor** and its command. Both fans end engaged at the commanded target,
    /// with the key still set.
    ///
    /// **Mutation:** in `SMCWriteTurns.holdFloor`, read fan 0's target whatever the fan —
    /// `SMCKey.fanTargetRPM(0)` for `SMCKey.fanTargetRPM(fan.index)`. Every one-fan test stays
    /// green. Run: red here: fan 1's hold reads fan 0's commanded target, holds, and writes no
    /// `F1Tg` floor.
    @Test("Two fans engaged at rest in one lease each take their own floor, under one Ftst")
    func twoFansEngageAtRestInOneLease() async throws {
        let machine = await ProductionWriteMachine(
            unlock: .heldUntilForced(stepsToYield: 1), stoppedByApple: [0, 1])
        let lease = try await machine.lease(fans: [0, 1])
        let mark = machine.firmware.log.entries.count

        let answer = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 2_400, fans: [0, 1], under: lease)
        }

        #expect(answer == nil, "the apply was answered \(String(describing: answer))")
        let held = FirmwareLog.Answer.threw(.firmware(code: 0x82))
        let floor = FirmwareSMC.flt(rpm: 1_350)
        let target = FirmwareSMC.flt(rpm: 2_400)
        let one: [UInt8] = [0x01]
        let writes = machine.firmware.log.entries.dropFirst(mark).filter(\.isWrite)
        #expect(
            Array(writes) == [
                .write(Self.modeZero, one, held), .write(SMCKey.forceTest, one, .answered),
                .write(Self.modeZero, one, held), .write(Self.modeZero, one, .answered),
                .write(Self.targetZero, floor, .answered),
                .write(Self.targetZero, target, .answered),
                .write(Self.modeOne, one, held), .write(Self.modeOne, one, .answered),
                .write(Self.targetOne, floor, .answered), .write(Self.targetOne, target, .answered),
            ], "\(machine.writes(since: mark))")
        for (mode, key) in [(Self.modeZero, Self.targetZero), (Self.modeOne, Self.targetOne)] {
            #expect(await machine.firmware.register(mode) == one, "\(mode) is not engaged")
            #expect(await machine.firmware.register(key) == target, "\(key)")
        }
        #expect(await machine.firmware.register(SMCKey.forceTest) == one)
    }
}
