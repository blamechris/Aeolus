import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// #670's (a) after the grant: level 6 never keeps some of a lease's fans while it hands others
/// back. A refused `apply` undoes what it engaged; unless that leaves every fan of the lease held
/// `.engaged`, or none on account, level 6 ends the lease whole and the lease core hands every
/// one of its fans back. A kept fan (`.handBackRefused`) is not held: its hand-back threw, which it
/// can do after its mode write landed, so it may be on automatic control already.
///
/// Every scenario is two fans, as on `Mac16,5`, under one lease over both.
@Suite("Level 6 ends a lease it would not hold whole (#670)", .timeLimit(.minutes(1)))
struct LeaseApplierWholeLeaseTests {

    /// Fan 0 is engaged and commanded; fan 1's envelope read then fails, after the firmware has
    /// started refusing every write, so the refused `apply`'s undo of fan 0 is refused and fan 0 is
    /// kept, while fan 1 was never engaged. That is a lease holding fan 0 beside fan 1 on automatic
    /// control under the force key fan 0's engagement wrote: ADR 0014's U7 state. Level 6 ends the
    /// lease, the lease core hands both fans back under `.applyRefused`, and the answer is the
    /// step's own refusal.
    ///
    /// **Mutation:** in `LeaseApplier.apply`, delete the `if let held =
    /// engagements.notWhollyHeld(…)` block. Run: red, the lease standing over a kept fan 0 and a
    /// free fan 1, and no restore.
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
    /// against the same refusing firmware. Both read manual here, but a kept fan's hand-back can
    /// throw after its mode write landed (the mixed rollback below), so two kept fans are not two
    /// held fans, and level 6 ends the lease whole.
    ///
    /// **Mutation:** in `LeaseEngagements.notWhollyHeld(of:under:)`, count a kept fan as held:
    /// `$0 == .engaged` → `$0 != nil`. Run: red, the lease standing over two kept fans.
    @Test("A refused apply that keeps every fan ends the lease whole")
    func aRefusedApplyThatKeepsEveryFanEndsTheLease() async throws {
        let kept = try await KeptFan.keptByTheDriver(fan: 1, of: [0, 1])

        #expect(await kept.machine.leases.leaseCount == 0, "the lease stands over two kept fans")
        #expect(
            await kept.machine.restorer.restores == [.init(fans: [0, 1], cause: .applyRefused)])
        #expect(kept.machine.safetyLog.lines(containing: "so it ended the lease").count == 1)
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

    /// PR #676's review, Codex finding 1, as reviewer T reproduced it. Both fans are engaged under
    /// the force key and fan 1's command is refused, so the undo hands back both. Fan 0's restore
    /// is refused, and fan 0 stays manual. Fan 1's `F1Md = 0` lands, but its `Ftst = 0` is
    /// refused. Both hand-backs threw, so both fans are kept: one manual and one automatic, under
    /// a key still set. Level 6 ends the lease whole.
    ///
    /// The key clear stays owed (#678): when the firmware takes writes again, the lease core's
    /// restore of each fan (`KeystoneRestoreAttempt`'s `.fan(n)`, issued here as it issues it)
    /// writes `Ftst = 0` again, and the key ends clear.
    ///
    /// **Mutation:** the "every fan kept" one above. Run: red, the lease standing over fan 0
    /// manual and fan 1 automatic. **Mutation:** in `PlaneWriteLedger.issueRestore(fanAt:)`, drop
    /// the flag when the clear is issued again (`if clearsKey { state.forceKeySet = false }`).
    /// Run: red, the restores write no `Ftst = 0` and the key stays set.
    @Test("A mixed rollback ends the lease, and the refused key clear is written again")
    func aMixedRollbackEndsTheLeaseAndTheKeyClearIsOwed() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [
            0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
        ]
        let plane = ScriptedControlPlane(
            fans: fans,
            stages: [
                .nominal(),
                .nominal(writes: .refused(reason: "mode and target writes refused")),
                .nominal(forceKeyWrites: .refused(reason: "Ftst refused")),
                .nominal(),
            ],
            unlock: .heldUntilForced(stepsToYield: 0))
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = NthWriteScriptingPlane(plane)
        await writes.before(command: 2) { await plane.advance() }
        await writes.before(restore: 2) { await plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        let answer = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }

        #expect(answer != nil, "the apply whose command was refused was answered applied")
        #expect(await writes.fired == ["command 2", "restore 2"], "the scenario never happened")
        #expect(try await plane.firmwareMode(ofFan: 0) == .manual)
        #expect(try await plane.firmwareMode(ofFan: 1) == .automatic)
        #expect(await plane.isForceKeySet, "the scenario's key clear was not refused")
        #expect(plane.ledger.isForceKeySet, "the refused key clear was taken as done")
        #expect(await machine.leases.leaseCount == 0, "the lease stands over fan 0 and fan 1")
        #expect(await machine.restorer.restores == [.init(fans: [0, 1], cause: .applyRefused)])

        await plane.advance()
        let before = await plane.keyWrites.count
        try await plane.restoreToAutomatic(.fan(0))
        try await plane.restoreToAutomatic(.fan(1))

        #expect(await plane.keyWrites.dropFirst(before).contains(.forceKey(0)))
        #expect(await plane.isForceKeySet == false, "the key was left set")
        #expect(plane.ledger.isForceKeySet == false)
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic)
    }

    /// The mix made by the undo itself: both fans engaged, fan 1's command refused, the undo hands
    /// fan 0 back and fan 1's restore is refused. The check reads the accounts after the undo, so
    /// level 6 ends the lease whole (reviewer T's T9).
    ///
    /// **Mutation:** in `LeaseApplier.apply`, move the `if let held = engagements.notWhollyHeld(…)`
    /// block above `let kept = await undo(…)`. Run: red, the lease standing over fan 1 held
    /// beside fan 0 handed back.
    @Test("The undo hands one fan back and keeps the other, and the lease ends whole")
    func theUndoMakesTheMixAndTheLeaseEnds() async throws {
        let fans: [Int: ScriptedControlPlane.FanCondition] = [
            0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
        ]
        let plane = ScriptedControlPlane(
            fans: fans,
            stages: [
                .nominal(),
                .nominal(targetWrites: .refused(reason: "F1Tg refused")),
                .nominal(writes: .refused(reason: "fan 1's restore refused")),
            ])
        let machine = ReclamationMachine(plane: plane, fans: fans)
        let lease = try await machine.lease(fans: [0, 1]).id
        let writes = NthWriteScriptingPlane(plane)
        await writes.before(command: 2) { await plane.advance() }
        await writes.before(restore: 2) { await plane.advance() }
        let levelSix = machine.levelSix(writingThrough: writes)

        let answer = await LeaseApplierAnswerTests.answer {
            try await levelSix.apply(fixed((0, 4_400), (1, 4_600)), under: lease)
        }

        #expect(answer != nil, "the apply whose command was refused was answered applied")
        #expect(await writes.fired == ["command 2", "restore 2"], "the scenario never happened")
        #expect(try await plane.firmwareMode(ofFan: 0) == .automatic, "fan 0 was not handed back")
        #expect(try await plane.firmwareMode(ofFan: 1) == .manual, "fan 1's restore landed")
        #expect(await machine.leases.leaseCount == 0, "the lease stands over fan 1 alone")
        #expect(await machine.restorer.restores == [.init(fans: [0, 1], cause: .applyRefused)])
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

/// Forwards to a scripted plane, running an effect before its nth target command and its nth
/// restore, each once (reviewer T's probe plane for PR #676).
private actor NthWriteScriptingPlane: AdmissionBlindPlane {
    private let plane: ScriptedControlPlane
    private var commands = 0
    private var restores = 0
    private var beforeCommand: [Int: @Sendable () async -> Void] = [:]
    private var beforeRestore: [Int: @Sendable () async -> Void] = [:]
    private(set) var fired: [String] = []

    init(_ plane: ScriptedControlPlane) { self.plane = plane }

    func before(command ordinal: Int, _ effect: @escaping @Sendable () async -> Void) {
        beforeCommand[ordinal] = effect
    }

    func before(restore ordinal: Int, _ effect: @escaping @Sendable () async -> Void) {
        beforeRestore[ordinal] = effect
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    nonisolated func beginEngagement(fanAt index: Int) { plane.beginEngagement(fanAt: index) }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        try await plane.readControlState(ofFan: index)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await plane.readEnvelope(ofFan: index)
    }

    func reconnect() async throws { try await plane.reconnect() }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await plane.readCriticalTemperatures(keys)
    }

    func prepareWritePath(enumerating fans: any FanEnumerating) async -> WritePathPreparation? {
        await plane.prepareWritePath(enumerating: fans)
    }

    func engageManualControl(of fan: CommandableFan) async throws -> EngagementStep {
        try await plane.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        commands += 1
        if let effect = beforeCommand.removeValue(forKey: commands) {
            await effect()
            fired.append("command \(commands)")
        }
        return try await plane.commandTarget(target)
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        restores += 1
        if let effect = beforeRestore.removeValue(forKey: restores) {
            await effect()
            fired.append("restore \(restores)")
        }
        try await plane.restoreToAutomatic(scope)
    }
}
