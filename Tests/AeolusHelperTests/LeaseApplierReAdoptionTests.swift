import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// A kept fan is § 3's, and its re-adoption is its own
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)'s #410 refused-hand-back amendment):
/// every route that opens a `.handBackRefused` account leaves the fan in § 3's registry, a
/// re-adoption registers it with § 3 again before anything commands it, and each fan is kept and
/// re-adopted by its own index.
///
/// Every scenario runs the real `LeaseApplier` over a `ReclamationMachine`, and each test names the
/// mutation it kills.
@Suite("A kept fan is § 3's, and is re-adopted by its own index", .timeLimit(.minutes(1)))
struct LeaseApplierReAdoptionTests {

    /// **A re-adopted fan is registered with § 3 again.** Level 6's driver reaches § 3 through a
    /// role that records each registration and forwards it. Fan 0 is kept in manual; its re-apply
    /// re-adopts it, and the role records one registration of fan 0 before the command is
    /// attempted, as a returning engagement's is.
    ///
    /// **Mutation:** delete `await driver.reAdopted(permit)` from `LeaseApplier.step`. Run: red, no
    /// registration. **Mutation:** move it after `writer.hold`. Run: red, the command first.
    @Test("A re-adopted fan is registered with § 3 again, before it is commanded")
    func aReAdoptedFanIsRegisteredWithTheEmergencyAgain() async throws {
        let order = Sightings<String>()
        let kept = try await KeptFan.inManual(recordingInto: order)
        #expect(await order.seen == ["registered 0"], "the first engagement registered nothing")
        await kept.writes.interfere(beforeCommandTarget: 2) { await order.record("command 0") }

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 2_000)), under: kept.lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(kept.machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1)
        let reApply = Array(await order.seen.dropFirst())
        #expect(
            reApply == ["registered 0", "command 0"],
            "the re-apply's registration and command: \(reApply)")
    }

    /// Every route that opens a `.handBackRefused` account.
    enum KeptBy: String, CaseIterable, Sendable {
        /// Level 6's own undo, after a command the firmware refused.
        case levelSixsUndo
        /// The driver's undo, after a read-back that did not confirm the write (#406).
        case driversUndo
        /// Level 6's undo of a fan whose report § 5 answered `.notHeld`.
        case undoAfterNotHeld
    }

    /// **Every kept fan is held by the emergency.** One row per route that opens the account: the
    /// fan is in § 3's registry when the refusal returns, so the next emergency bridges it.
    ///
    /// **Mutation:** delete the driver's `if !registered { … }` registration before its undo. Run:
    /// red on the driver's row, a fan in manual that no emergency bridges.
    @Test("Every route that keeps a fan leaves it in § 3's registry", arguments: KeptBy.allCases)
    func everyKeptFanIsHeldByTheEmergency(_ route: KeptBy) async throws {
        let kept: KeptFan
        switch route {
        case .levelSixsUndo: kept = try await KeptFan.inManual()
        case .driversUndo: kept = try await KeptFan.keptByTheDriver()
        case .undoAfterNotHeld: kept = try await KeptFan.keptAfterNotHeld()
        }

        #expect(
            await kept.machine.emergency.fansUnderManualControl.contains(0),
            "a fan kept by \(route) is not in § 3's registry")
    }

    /// **Both kept fans are re-adopted, each by its own index.** Fan 0 is commanded, fan 1's
    /// command is refused, and both hand-backs are refused: both are kept. The re-apply names both,
    /// and each is re-adopted with nothing written to its mode, with a notice naming each.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, `keep(0, …)` in place of the fan's own index. Run:
    /// red, fan 1 answered `foreignManualControl`. **Mutation:** the re-adoption's notice names
    /// fan 0 whatever the fan. Run: red, no notice names fan 1.
    @Test("Both kept fans are re-adopted, each by its own index")
    func bothKeptFansAreReAdoptedEachByItsOwnIndex() async throws {
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
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        #expect(await writes.didFire)
        #expect(try await machine.plane.firmwareMode(ofFan: 0) == .manual)
        #expect(try await machine.plane.firmwareMode(ofFan: 1) == .manual)
        await machine.plane.advance()
        let writesBefore = await machine.plane.keyWrites.count

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000), (1, 2_200)), under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        let notices = machine.safetyLog.lines(
            containing: "whose hand-back level 6 could not confirm")
        #expect(notices.count == 2)
        #expect(notices.contains { $0.contains("Fan 0, whose") }, "no notice named fan 0")
        #expect(notices.contains { $0.contains("Fan 1, whose") }, "no notice named fan 1")
        #expect(await machine.watchdog.fansUnderManualControl == [0, 1])
        let modeWrites = await machine.plane.keyWrites.dropFirst(writesBefore).filter {
            if case .mode = $0 { true } else { false }
        }
        #expect(modeWrites.isEmpty, "a re-adoption wrote a mode: \(modeWrites)")
    }

    /// **A driver undo refused on fan 1 keeps fan 1's account.** The driver's own undo of fan 1's
    /// engagement is refused, so the wrapper reaches the answer and is answered by its cause,
    /// `notConfirmed`. Fan 1 is kept, and its re-apply re-adopts it.
    ///
    /// **Mutation:** in `LeaseEngagements.read`, `keep(0, …)` in place of the fan's own index. Run:
    /// red, fan 1 answered `foreignManualControl`. **Mutation:** delete
    /// `LeaseApplyRules.answer(to:)`'s first arm. Run: red, the refusal answered `unexpected`
    /// instead of `notConfirmed`.
    @Test("A driver undo refused on fan 1 keeps fan 1's account, answered by its cause")
    func aDriverUndoRefusedOnFanOneKeepsFanOnesAccount() async throws {
        let kept = try await KeptFan.keptByTheDriver(fan: 1, of: [0, 1])
        let machine = kept.machine
        #expect(
            kept.refusal as? AeolusXPCFault
                == .helperFailed(detail: LeaseApplyRules.Detail.notConfirmed),
            "the refused undo was not answered by its cause: \(kept.refusal as Any)")
        let notice = machine.safetyLog.lines(containing: "Level 6's apply was refused")
        #expect(
            notice.allSatisfy { $0.contains("The hand-back of [1] was refused") }, "\(notice)")

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((1, 2_000)), under: kept.lease)
        }

        #expect(reApplied == nil, "Aeolus's own fan 1 was answered \(reApplied as Any)")
        #expect(await machine.watchdog.fansUnderManualControl == [1])
    }

    /// **A `.notHeld` fan whose hand-back is refused is kept, and re-adopted.** § 5 is told fan 0
    /// was released while its command lands, so the report is `.notHeld` and the fan leaves the
    /// account; the undo still hands it back, the restore is refused, and the fan is kept again.
    /// Its re-apply re-adopts it, and § 5 holds it.
    ///
    /// **Mutation:** in `LeaseApplier.undo`, keep only a fan that still has an account. Run: red,
    /// Aeolus's own fan answered `foreignManualControl`.
    @Test("A notHeld fan whose hand-back is refused is kept, and re-adopted")
    func aNotHeldFanWhoseHandBackIsRefusedIsKeptAndReAdopted() async throws {
        let kept = try await KeptFan.keptAfterNotHeld()

        let reApplied = await LeaseApplierAnswerTests.answer {
            try await kept.levelSix.apply(fixed((0, 2_000)), under: kept.lease)
        }

        #expect(reApplied == nil, "Aeolus's own fan was answered \(reApplied as Any)")
        #expect(kept.machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1)
        #expect(await kept.machine.watchdog.fansUnderManualControl == [0])
    }

    /// **A kept fan that § 3 forgot is registered with § 3 again before it is commanded.** This is
    /// the route `LeaseEngagements`' header names: a hand-back of the same fan by § 5 that lands
    /// while the lease is live. A two-fan `apply` engages and commands fan 0. The firmware takes
    /// fan 0 back, § 5 re-engages it, and § 5's own driver undoes that engagement, the undo
    /// landing. Fan 1's envelope read then fails, and level 6's undo of fan 0 is refused, so fan 0
    /// is kept. A sighted § 3 cycle reads fan 0 automatic and forgets it, with the lease live and
    /// the account still `.handBackRefused`. Another program writes raw `1`, and the re-apply is
    /// answered applied: it re-adopted the fan, and § 3's registry held fan 0 when the command
    /// was issued.
    ///
    /// It is the one scenario in which deleting `reAdopted` under-fires. On every other route the
    /// fan is still in § 3's registry when it is re-adopted, so the registration repeats one.
    ///
    /// **Mutation:** delete `await driver.reAdopted(permit)` from `LeaseApplier.step`. Run: red at
    /// the registry assertion, `atTheCommand == [[0]]`: fan 0 commanded with § 3's registry empty.
    @Test("A kept fan that § 3 forgot is registered with § 3 again before it is commanded")
    func aKeptFanTheEmergencyForgotIsRegisteredAgainBeforeItIsCommanded() async throws {
        let (machine, envelopes) = try await Self.fanZeroTakenBackDuringFanOnesEnvelopeRead()
        let lease = try await machine.leaseID()
        let (plane, emergency) = (machine.plane, machine.emergency)
        let writes = InterferingFanStateSensing(plane, during: .commandWrite)
        let atTheCommands = Sightings<Set<Int>>()
        await writes.interfere(beforeCommandTarget: 2) {
            await atTheCommands.record(await emergency.fansUnderManualControl)
        }
        let levelSix = machine.levelSix(writingThrough: writes, envelopes: envelopes)

        let first = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_400), (1, 2_600)), under: lease)
        }
        #expect(await envelopes.didFire, "fan 1's envelope read never failed")
        #expect(
            first as? AeolusXPCFault == .manualControlUnavailable(reason: .supervisorBlind),
            "the first apply was answered \(first as Any)")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "§ 5's undo landed")
        #expect(await emergency.fansUnderManualControl == [0], "the refusal left fan 0 outside § 3")
        await plane.advance()
        _ = await emergency.cycle()
        #expect(await machine.leases.hasLiveLease(id: lease, coveringFan: 0), "the lease ended")
        #expect(
            await emergency.fansUnderManualControl.isEmpty,
            "§ 3 still holds fan 0, so the route under test was not reached")

        await plane.setMode(.manual, ofFan: 0)
        let reApplied = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 2_000)), under: lease)
        }

        #expect(reApplied == nil, "the re-apply was answered \(reApplied as Any)")
        #expect(
            machine.safetyLog.lines(containing: KeptFan.reAdopted).count == 1,
            "the account did not stand, so nothing was re-adopted")
        #expect(await writes.didFire, "the re-apply never reached its command")
        let atTheCommand = await atTheCommands.seen
        #expect(atTheCommand == [[0]], "§ 3's registry when fan 0 was commanded: \(atTheCommand)")
    }

    /// Two automatic fans under one lease, `machine.leaseID()`, on three cool stages so that § 3's
    /// cycles are sighted, the second refusing every write. The returned envelope reader fails fan
    /// 1's read, outside every gate, and first moves the world: the firmware takes fan 0 back, § 5
    /// re-engages it and its own driver's undo lands, and the plane advances to the stage that
    /// refuses every write.
    private static func fanZeroTakenBackDuringFanOnesEnvelopeRead() async throws -> (
        machine: ReclamationMachine<ScriptedControlPlane>, envelopes: EnvelopeFailingAfterAnEffect
    ) {
        let cool = ["TPD0": 50.0]
        let fans: [Int: ScriptedControlPlane.FanCondition] = [
            0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
        ]
        let plane = ScriptedControlPlane(
            fans: fans,
            stages: [
                .nominal(temperatures: cool),
                .nominal(temperatures: cool, writes: .refused(reason: "restores refused")),
                .nominal(temperatures: cool),
            ])
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let watchdog = machine.watchdog
        let envelopes = EnvelopeFailingAfterAnEffect(over: plane, failingFan: 1)
        await envelopes.arm {
            await plane.setMode(.automatic, ofFan: 0)
            await plane.setRawMode(0, ofFan: 0)
            await watchdog.cycle()
            await plane.setRawMode(nil, ofFan: 0)
            await plane.advance()
        }
        _ = try await machine.lease(fans: [0, 1])
        return (machine, envelopes)
    }
}

/// `FanEnvelopeReading` whose read of one fan runs an effect once, outside every gate, and then
/// fails: the world moving while level 6 reads that fan's bounds. Every other read, and that fan's
/// once the effect has run, is `inner`'s.
private actor EnvelopeFailingAfterAnEffect: FanEnvelopeReading {
    private let inner: any FanEnvelopeReading
    private let failingFan: Int
    private var effect: (@Sendable () async -> Void)?
    private(set) var didFire = false

    init(over inner: any FanEnvelopeReading, failingFan: Int) {
        self.inner = inner
        self.failingFan = failingFan
    }

    /// Sets what happens inside the failing fan's read, which is assigned after construction
    /// because the effect needs the machine this read feeds.
    func arm(_ effect: @escaping @Sendable () async -> Void) {
        self.effect = effect
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        guard index == failingFan, let effect else {
            return try await inner.readEnvelope(ofFan: index)
        }
        self.effect = nil
        didFire = true
        await effect()
        throw FanControlPlaneError.readFailed(detail: "fan \(index) envelope: the read failed")
    }
}
