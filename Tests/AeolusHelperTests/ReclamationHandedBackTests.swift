import Foundation
import Testing

@testable import AeolusHelper

/// `ReclamationWatchdog.manualControlHandedBack(fanAt:under:)`, through the actor: level 6's undo
/// tells § 5 a fan it engaged is being handed back, before the driver restores it (ADR 0014's A6
/// PR-2 amendment). Without it, § 5 reads the restored fan as `.modeReclaimed` under a live lease,
/// marks it and re-engages a fan the client was told was refused.
///
/// The transition itself, its identity check, its generation and the mark it keeps through the
/// terminal action, is `ReclamationRegistryTests.aHandBackForgetsOnlyItsOwnLeasesRecord`.
@Suite("§ 5's hand-back notice from level 6", .timeLimit(.minutes(1)))
struct ReclamationHandedBackTests {

    /// Fan 0 is held under the lease with a mark on it. The notice forgets it and clears the mark,
    /// and once the fan is back on automatic the next cycle neither marks nor re-engages it.
    ///
    /// **Mutation:** empty the body of `manualControlHandedBack(fanAt:under:)`. Run: red on the
    /// record, the mark, and the cycle's re-engage.
    @Test("The notice forgets the fan, clears its mark, and the next cycle leaves it alone")
    func theNoticeForgetsTheFanAndClearsItsMark() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id
        _ = await machine.ledger.markReclaimed(fanAt: 0)

        await machine.watchdog.manualControlHandedBack(fanAt: 0, under: lease)
        await machine.plane.setMode(.automatic, ofFan: 0)
        await machine.watchdog.cycle()

        #expect(await machine.watchdog.fansUnderManualControl.isEmpty, "the record survived")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the mark survived")
        #expect(
            await machine.attempts.contains(.engageManualControl(fan: 0)) == false,
            "§ 5 re-engaged a fan level 6 handed back")
        #expect(await machine.commandedRPMs.isEmpty)
    }

    /// A notice under another lease is not about this record: it stays, and so does its mark.
    ///
    /// **Mutation:** drop the identity guard from `Registry.handBack(fanAt:under:)`. Run: red.
    @Test("A notice under another lease changes nothing")
    func aNoticeUnderAnotherLeaseChangesNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        _ = await machine.ledger.markReclaimed(fanAt: 0)

        await machine.watchdog.manualControlHandedBack(fanAt: 0, under: UUID())

        #expect(await machine.watchdog.fansUnderManualControl == [0])
        #expect(await machine.ledger.isReclaimed(fanAt: 0))
    }
}
