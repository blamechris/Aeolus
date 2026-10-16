import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Level 6 writes a fixed setting whole, and its writer's ramp memory is reset at every engagement
/// and hand-back it makes (ADR 0014's A6 PR-2 amendment, risk 2 of the architect's A6 consult).
///
/// The memory lives as long as the writer, so without the resets the target one lease left behind
/// is the origin of the next lease's first step: run 1b's "100 %" after "50 %" commanded as 3,764
/// RPM, a reply saying applied, and `CLAUDE.md` rule 6. `GovernedFanWriterHoldTests` is the
/// writer's half.
@Suite("Level 6's whole write and its ramp memory", .timeLimit(.minutes(1)))
struct LeaseApplierRampTests {

    /// **The acceptance.** Lease A applies 3,564 and is released; lease B applies 5,777, and its
    /// first command is 5,777. Inside that command write the writer remembers nothing: the
    /// engagement under lease B reset what lease A left.
    ///
    /// **Mutations:** in `LeaseApplier.step`, write with `writer.command(towards: rpm, of: permit,
    /// since: .seconds(1))` instead of `hold`, and delete the reset at the engagement. Run: red,
    /// 3,764 commanded. Delete only the reset at the engagement. Run: red on the memory inside the
    /// write, 3,564.
    @Test("A second lease's first command is 5,777 after 3,564")
    func aSecondLeasesFirstCommandIsWhole() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let first = try await machine.lease(fans: [0]).id
        try await levelSix.apply(fixed((0, 3_564)), under: first)
        try await machine.leases.releaseLease(id: first, from: machine.holder)
        // The fixture's restorer records and writes nothing, so the release's restore is this.
        try await machine.plane.restoreToAutomatic(.fan(0))

        let second = try await machine.lease(fans: [0]).id
        let remembered = Sightings<Double?>()
        await writes.interfere {
            await remembered.record(await levelSix.writer.lastCommanded(ofFan: 0))
        }
        try await levelSix.apply(fixed((0, 5_777)), under: second)

        #expect(await machine.commandedRPMs == [3_564, 5_777], "a fixed setting was ramped")
        #expect(
            await remembered.seen == [nil],
            "lease B's engagement kept the target lease A left as its ramp origin")
        #expect(await levelSix.writer.lastCommanded(ofFan: 0) == 5_777)
    }

    /// **The hand-back's reset.** A refused `apply` hands fan 0 back, and the writer forgets the
    /// 2,400 it wrote there.
    ///
    /// **Mutation:** delete the reset from `LeaseApplier.undo`. Run: red, 2,400 remembered for a
    /// fan on automatic control.
    @Test("The undo's hand-back resets the ramp memory")
    func theUndoResetsTheRampMemory() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused"))],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let remembered = Sightings<Double?>()
        await writes.interfere(beforeEngageStep: 2) {
            await remembered.record(await levelSix.writer.lastCommanded(ofFan: 0))
            await machine.plane.advance()
        }

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }

        #expect(await remembered.seen == [2_400], "fan 0 was never written, so nothing is tested")
        #expect(await machine.didRestore(fan: 0))
        #expect(
            await levelSix.writer.lastCommanded(ofFan: 0) == nil, "the undo kept the ramp memory")
    }
}
