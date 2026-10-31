import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// Level 6's re-adoption of a kept fan, over the **production** plane at rest (ADR 0014's P1′
/// amendment; #465's sixth obligation). `LeaseEngagements.read` re-adopts a fan whose first step
/// reads raw `1` with nothing written, so no floor rule runs. The state it can meet is raw `1` at
/// a target of 0: an engagement at rest whose floor write was refused and whose undo was refused
/// too. This holds that the re-adopted fan does not stay there: the same step commands it, at its
/// clamped target, before the re-apply answers.
@Suite("A kept fan re-adopted at rest, over the production plane", .timeLimit(.minutes(1)))
struct ProductionReAdoptionTests {

    static let mode = smcKey("F0Md")
    static let target = smcKey("F0Tg")

    /// Fan 0 starts in Apple's rest state. The first `apply` engages it — raw `3`, the mode write,
    /// the read-back of `1` — and its floor write is refused, so the step throws; the driver's undo
    /// is refused as well, and level 6 keeps the fan, at raw `1` and a target of 0. The re-apply's
    /// first step reads that `1` and writes nothing, level 6 re-adopts the fan, and the same step
    /// commands it: one `F0Tg` write, at the requested speed, and no mode write.
    ///
    /// **Mutation:** in `LeaseApplier.step`, `return` straight after `driver.reAdopted(permit)`,
    /// so a re-adopted fan is not commanded. Run: red here, at the re-apply's writes and the
    /// target register.
    @Test("A kept fan re-adopted at a target of 0 is raised by its command in the same step")
    func aReAdoptedFanAtTargetZeroIsRaised() async throws {
        let machine = await ProductionWriteMachine(stoppedByApple: [0, 1])
        let lease = try await machine.lease()
        await machine.firmware.queueWrites(to: Self.target, [.refuses(code: 0x85)])
        await machine.firmware.queueWrites(to: Self.mode, [.applies, .refuses(code: 0x85)])

        let refused = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        #expect(refused != nil, "the apply whose floor was refused was answered applied")
        #expect(await machine.firmware.register(Self.mode) == [0x01], "the fan was not kept")
        #expect(await machine.firmware.register(Self.target) == FirmwareSMC.flt(rpm: 0))
        let mark = machine.firmware.log.entries.count

        let reApplied = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 2_400, under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(String(describing: reApplied))")
        let bytes = FirmwareSMC.flt(rpm: 2_400).map { String($0) }.joined(separator: ",")
        #expect(machine.writes(since: mark) == ["F0Tg=\(bytes)"], "\(machine.writes(since: mark))")
        #expect(await machine.firmware.register(Self.mode) == [0x01])
        #expect(await machine.firmware.register(Self.target) == FirmwareSMC.flt(rpm: 2_400))
        #expect(
            machine.lines.lines(containing: KeptFan.reAdopted).count == 1, "\(machine.lines.lines)")
    }
}
