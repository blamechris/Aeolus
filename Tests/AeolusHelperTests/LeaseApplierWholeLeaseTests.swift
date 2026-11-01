import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #670's (a) after the grant: level 6 never keeps some of a lease's fans while it hands others
/// back. A refused `apply` undoes what it engaged; when that leaves the lease holding some of its
/// fans and not the rest, level 6 ends the lease whole and the lease core hands every one of its
/// fans back. A refused `apply` that leaves every fan held, or none, leaves the lease standing, as
/// it did before: nothing is held beside a fan on automatic control then.
///
/// Every scenario is two fans, as on `Mac16,5`, under one lease over both.
@Suite("Level 6 ends a lease it would hold only part of (#670)", .timeLimit(.minutes(1)))
struct LeaseApplierWholeLeaseTests {

    /// Fan 0 is engaged and commanded; fan 1's envelope read then fails, after the firmware has
    /// started refusing every write, so the refused `apply`'s undo of fan 0 is refused and fan 0 is
    /// kept, while fan 1 was never engaged. That is a lease holding fan 0 beside fan 1 on automatic
    /// control under the force key fan 0's engagement wrote: ADR 0014's U7 state. Level 6 ends the
    /// lease, the lease core hands both fans back under `.applyRefused`, and the answer is the
    /// step's own refusal.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, delete the `if let held = engagements.partlyHeld(…)`
    /// block. Run: red, the lease standing over a kept fan 0 and a free fan 1, and no restore.
    @Test("A refused apply that keeps one fan of two ends the lease whole")
    func aRefusedApplyThatKeepsOneFanEndsTheLease() async throws {
        let machine = Self.twoFans()
        let lease = try await machine.lease(fans: [0, 1]).id
        let envelopes = FanOneEnvelopeFailing(over: machine.plane) {
            await machine.plane.advance()
        }
        let levelSix = machine.levelSix(writingThrough: machine.plane, envelopes: envelopes)

        let answer = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }

        #expect(
            answer as? AeolusXPCFault == .manualControlUnavailable(reason: .supervisorBlind),
            "\(answer as Any)")
        #expect(await envelopes.didFire, "fan 1's envelope read never failed")
        #expect(await machine.leases.leaseCount == 0, "the lease stands over part of its fans")
        #expect(await machine.restorer.restores == [.init(fans: [0, 1], cause: .applyRefused)])
        #expect(
            machine.safetyLog.lines(containing: "so it ended the lease").count == 1,
            "\(machine.safetyLog.lines)")
    }

    /// Both fans kept: fan 1's undo refused by the driver and fan 0's by level 6's own undo, each
    /// against the same refusing firmware. Nothing is held beside a fan on automatic control, so
    /// the lease stands, and its re-apply re-adopts both (`LeaseApplierReAdoptionTests`).
    ///
    /// **Mutation:** in `LeaseEngagements.partlyHeld(of:under:)`, drop `held != covered`. Run:
    /// red, the lease ended over two kept fans.
    @Test("A refused apply that keeps every fan leaves the lease standing")
    func aRefusedApplyThatKeepsEveryFanLeavesTheLease() async throws {
        let kept = try await KeptFan.keptByTheDriver(fan: 1, of: [0, 1])

        #expect(await kept.machine.leases.leaseCount == 1, "the lease ended over two kept fans")
        #expect(await kept.machine.restorer.restores.isEmpty)
        #expect(kept.machine.safetyLog.lines(containing: "so it ended the lease").isEmpty)
    }

    /// Fan 1's command is refused and the undo hands both fans back, the firmware taking each
    /// write: nothing is held, so the lease stands with no fan off automatic control, and the
    /// client may apply again.
    @Test("A refused apply that hands every fan back leaves the lease standing")
    func aRefusedApplyThatHandsEveryFanBackLeavesTheLease() async throws {
        let machine = ReclamationMachine(
            stages: [.nominal(), .nominal(targetWrites: .refused(reason: "F1Tg refused"))],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = InterferingFanStateSensing(machine.plane, during: .restoreWrite)
        await writes.interfere(beforeEngageStep: 2) { await machine.plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        let answer = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }

        #expect(answer != nil, "the apply whose command was refused was answered applied")
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .automatic)
        #expect(try await machine.plane.firmwareMode(ofFan: 1) == .automatic)
        #expect(await machine.leases.leaseCount == 1)
        #expect(await machine.restorer.restores.isEmpty)
    }

    /// Two automatic fans, the second stage refusing every write.
    private static func twoFans() -> ReclamationMachine<ScriptedControlPlane> {
        ReclamationMachine(
            stages: [.nominal(), .nominal(writes: .refused(reason: "restores refused"))],
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
    }
}

/// `FanEnvelopeReading` whose read of fan 1 runs an effect once, outside every gate, and then
/// fails; every other read is `inner`'s.
private actor FanOneEnvelopeFailing: FanEnvelopeReading {
    private let inner: any FanEnvelopeReading
    private let effect: @Sendable () async -> Void
    private(set) var didFire = false

    init(over inner: any FanEnvelopeReading, effect: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.effect = effect
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        guard index == 1, !didFire else { return try await inner.readEnvelope(ofFan: index) }
        didFire = true
        await effect()
        throw FakeProviderError(description: "fan 1's bounds did not read")
    }
}
