import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// Level 6's re-adoption of a kept fan, over the **production** plane at rest (ADR 0014's P1′
/// amendment; #465's sixth obligation), with both of `Mac16,5`'s fans kept, which is the only way
/// a lease outlives a refused `apply` that kept a fan since #670. `LeaseEngagements.read`
/// re-adopts a fan whose first step reads raw `1` with nothing written, so no floor rule runs. The
/// state it can meet is raw `1` at a target of 0: an engagement at rest whose floor write was
/// refused and whose undo was refused too. This holds that the re-adopted fan does not stay there:
/// the same step commands it, at its clamped target, before the re-apply answers.
@Suite("A kept fan re-adopted at rest, over the production plane", .timeLimit(.minutes(1)))
struct ProductionReAdoptionTests {

    static let mode = smcKey("F1Md")
    static let target = smcKey("F1Tg")

    /// Both fans start in Apple's rest state, and the first `apply` keeps both, because since #670
    /// a refused `apply` that keeps one fan and hands back the other ends the lease whole. Fan 0
    /// engages and is commanded; fan 1's mode write lands, its floor write is refused, so its step
    /// throws, and the driver's undo is refused as well: level 6 keeps fan 1, at raw `1` and a
    /// target of 0. The refused `apply`'s own undo then hands fan 0 back, and that is refused too,
    /// so fan 0 is kept as well and the lease stands over two kept fans. The re-apply's first step
    /// reads each fan's `1` and writes nothing, level 6 re-adopts each, and the same step commands
    /// it: one target write per fan, at the requested speed, and no mode write.
    ///
    /// **Mutation:** in `LeaseApplier.step`, `return` straight after `driver.reAdopted(permit)`,
    /// so a re-adopted fan is not commanded. Run: red here, at the re-apply's writes and fan 1's
    /// target register.
    @Test("A kept fan re-adopted at a target of 0 is raised by its command in the same step")
    func aReAdoptedFanAtTargetZeroIsRaised() async throws {
        let machine = await ProductionWriteMachine(stoppedByApple: [0, 1])
        let lease = try await machine.lease()
        await machine.firmware.queueWrites(to: Self.target, [.refuses(code: 0x85)])
        await machine.firmware.queueWrites(to: Self.mode, [.applies, .refuses(code: 0x85)])
        await machine.firmware.queueWrites(to: smcKey("F0Md"), [.applies, .refuses(code: 0x85)])

        let refused = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 4_400, under: lease)
        }

        #expect(refused != nil, "the apply whose floor was refused was answered applied")
        #expect(await machine.firmware.register(Self.mode) == [0x01], "fan 1 was not kept")
        #expect(await machine.firmware.register(Self.target) == FirmwareSMC.flt(rpm: 0))
        #expect(await machine.firmware.register(smcKey("F0Md")) == [0x01], "fan 0 was not kept")
        #expect(
            await machine.helper.leases.leaseCount == 1,
            "the lease ended, though both its fans are kept and none was handed back")
        let mark = machine.firmware.log.entries.count

        let reApplied = await ProductionWriteMachine.answer {
            try await machine.apply(rpm: 4_400, under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(String(describing: reApplied))")
        let bytes = FirmwareSMC.flt(rpm: 4_400).map { String($0) }.joined(separator: ",")
        #expect(
            machine.writes(since: mark) == ["F0Tg=\(bytes)", "F1Tg=\(bytes)"],
            "\(machine.writes(since: mark))")
        #expect(await machine.firmware.register(Self.mode) == [0x01])
        #expect(await machine.firmware.register(Self.target) == FirmwareSMC.flt(rpm: 4_400))
        for fan in [0, 1] {
            let reAdopted = KeptFan.reAdopted.replacingOccurrences(of: "Fan 0", with: "Fan \(fan)")
            #expect(
                machine.lines.lines(containing: reAdopted).count == 1, "\(machine.lines.lines)")
        }
    }
}
