import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// Level 6 writes a fixed setting whole, and its writer's ramp memory is reset at every engagement
/// and hand-back it makes (ADR 0014's A6 PR-2 amendment).
///
/// The memory lives as long as the writer, so without the resets the target one lease left behind
/// is the origin of the next lease's first step: run 1b's "100 %" after "50 %" commanded as 3,764
/// RPM, a reply saying applied, and `CLAUDE.md` rule 6. `GovernedFanWriterHoldTests` is the
/// writer's half.
@Suite("Level 6's whole write and its ramp memory", .timeLimit(.minutes(1)))
struct LeaseApplierRampTests {

    /// **The acceptance.** Lease A applies 4,670 (75 %, above the client floor) and is released;
    /// lease B applies 5,777, and its first command is 5,777. Inside that command write the writer
    /// remembers nothing: the engagement under lease B reset what lease A left.
    ///
    /// **Mutations:** in `LeaseApplier.step`, write with `writer.command(towards: rpm, of: permit,
    /// since: .seconds(1))` instead of `hold`, and delete the reset at the engagement. Run: red,
    /// 4,870 commanded. Delete only the reset at the engagement. Run: red on the memory inside the
    /// write, 4,670.
    @Test("A second lease's first command is 5,777 after 4,670")
    func aSecondLeasesFirstCommandIsWhole() async throws {
        let machine = ReclamationMachine(fans: [0: .automatic(at: 1_800)])
        let writes = InterferingFanStateSensing(machine.plane, during: .commandWrite)
        let levelSix = machine.levelSix(writingThrough: writes)
        let first = try await machine.lease(fans: [0]).id
        try await levelSix.apply(fixed((0, 4_670)), under: first)
        try await machine.leases.releaseLease(id: first, from: machine.holder)
        // The fixture's restorer records and writes nothing, so the release's restore is this.
        try await machine.plane.restoreToAutomatic(.fan(0))

        let second = try await machine.lease(fans: [0]).id
        let remembered = Sightings<Double?>()
        await writes.interfere {
            await remembered.record(await levelSix.writer.lastCommanded(ofFan: 0))
        }
        try await levelSix.apply(fixed((0, 5_777)), under: second)

        #expect(await machine.commandedRPMs == [4_670, 5_777], "a fixed setting was ramped")
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
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }

        #expect(await remembered.seen == [4_400], "fan 0 was never written, so nothing is tested")
        #expect(await machine.didRestore(fan: 0))
        #expect(
            await levelSix.writer.lastCommanded(ofFan: 0) == nil, "the undo kept the ramp memory")
    }

    /// **A re-adopted fan's reset** (ADR 0014's #410 refused-hand-back amendment). Fan 0 is
    /// commanded 2,400, fan 1's command is refused, and both hand-backs are refused, so fan 0 is
    /// kept in manual with its ramp memory. Its re-apply reads it as still the lease's, with
    /// nothing written, and resets the memory as an engagement does: inside its command write the
    /// writer remembers nothing.
    ///
    /// **Mutation:** in `LeaseApplier.step`, reset the memory only after an engagement that
    /// returned, not after a re-adoption. Run: red, 2,400 remembered as the ramp origin.
    @Test(
        "A kept fan read as still the lease's has its ramp memory reset",
        .disabled(
            """
            Unreachable while a refused apply that keeps a fan ends its lease whole (#670): no \
            re-apply follows under that lease, so no kept fan is re-adopted. Re-enable when run \
            1d lifts the rule.
            """))
    func aReAdoptedFansRampMemoryIsReset() async throws {
        let machine = ReclamationMachine(
            stages: [
                .nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused")),
                .nominal(writes: .refused(reason: "restores refused")), .nominal(),
            ],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .refusedCommandWrite)
        await writes.interfere(beforeCommandTarget: 2) { await machine.plane.advance() }
        await writes.interfere { await machine.plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        await #expect(
            throws: AeolusXPCFault.helperFailed(detail: LeaseApplyRules.Detail.firmwareRefused)
        ) {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual, "fan 0 was handed back")
        #expect(
            await levelSix.writer.lastCommanded(ofFan: 0) == 4_400,
            "fan 0 kept no memory, so nothing is tested")

        await machine.plane.advance()
        let remembered = Sightings<Double?>()
        await writes.interfere(beforeCommandTarget: 3) {
            await remembered.record(await levelSix.writer.lastCommanded(ofFan: 0))
        }
        try await levelSix.apply(fixed((0, 4_500), (1, 4_600)), under: lease)

        #expect(machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1)
        #expect(
            await remembered.seen == [nil],
            "the re-adopted fan kept the target written before its refused hand-back as its origin")
        #expect(await levelSix.writer.lastCommanded(ofFan: 0) == 4_500)
    }
}
