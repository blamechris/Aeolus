import Foundation
import Testing

@testable import AeolusHelper

/// The restore contract a plane that can write keeps, and the bring-up step that prepares it
/// ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D4, D5, D7), through
/// `PlaneWriteLedger` and `RestorePlan` as `ScriptedControlPlane` holds them.
@Suite("A plane's restore contract, and the write path's preparation")
struct PlaneRestoreContractTests {

    private static func fan(_ index: Int) throws -> CommandableFan {
        try commandableFan(index, declaring: .nominal)
    }

    /// Engages `fans` on `plane` the way the driver does: a ticket, then steps until it reads back.
    private static func engage(_ fans: [Int], on plane: ScriptedControlPlane) async throws {
        for index in fans {
            plane.beginEngagement(fanAt: index)
            while try await plane.engageManualControl(of: fan(index)) == .awaitingYield {}
        }
    }

    // MARK: - The unlock reversed

    /// Every `F<n>Md = 0`, then `Ftst = 0`: each mode write is issued in the force-key state its
    /// forward write was accepted in.
    ///
    /// **Mutation:** put the force key ahead of the mode writes in `RestorePlan.init`. Run: red.
    @Test("A restore writes the mode, then clears the force key")
    func aRestoreIsTheUnlockReversed() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], unlock: .heldUntilForced(stepsToYield: 0))
        try await Self.engage([0], on: plane)

        try await plane.restoreToAutomatic(.fan(0))

        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(await plane.isForceKeySet == false)
    }

    /// A refused mode write is still followed by the key's clear — the strongest lever left — and
    /// the restore throws only after both were attempted.
    ///
    /// **Mutation:** rethrow from inside `RestorePlan.attemptEvery`'s loop. Run: red on the
    /// key's write and on the key being cleared.
    @Test("Every write in a restore is attempted, whatever the others answered")
    func everyRestoreWriteIsAttempted() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [
                .nominal(),
                .nominal(writes: .refused(reason: "firmware said no"), forceKeyWrites: .honoured),
            ],
            unlock: .heldUntilForced(stepsToYield: 0))
        try await Self.engage([0], on: plane)
        await plane.advance()

        await #expect(throws: FanControlPlaneError.self) {
            try await plane.restoreToAutomatic(.fan(0))
        }

        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(await plane.isForceKeySet == false, "the key's clear was not attempted")
        #expect(try await plane.readControlState(ofFan: 0).mode == .manual)
    }

    /// `.fan(n)` clears the key exactly when it hands back the last fan the plane engaged, and
    /// never while another engaged fan depends on it.
    ///
    /// **Mutation:** clear the key on every `.fan(n)` whose flag is set, ignoring the engaged
    /// set, in `PlaneWriteLedger.restoreRequested(fanAt:)`. Run: red on the first restore.
    @Test("A per-fan restore clears the force key only with no engaged fan left")
    func theForceKeyOutlivesEveryFanThatDependsOnIt() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal], unlock: .heldUntilForced(stepsToYield: 0))
        try await Self.engage([0, 1], on: plane)

        try await plane.restoreToAutomatic(.fan(0))
        #expect(await plane.keyWrites.last == .mode(fan: 0, value: 0))
        #expect(await plane.isForceKeySet, "the key was cleared while fan 1 depended on it")

        try await plane.restoreToAutomatic(.fan(1))
        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 1, value: 0), .forceKey(0)])
        #expect(await plane.isForceKeySet == false)
    }

    /// The window between the key's acceptance and the first fan joining: the engaged set is
    /// empty while the flag is set, so the undo of an engagement that never joined clears it.
    @Test("Undoing an engagement that never joined clears the key it set")
    func anEmptyEngagedSetClearsTheKey() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], unlock: .neverYields)
        #expect(try await plane.ticketedStep(of: Self.fan(0)) == .awaitingYield)

        try await plane.restoreToAutomatic(.fan(0))

        #expect(
            await plane.keyWrites == [
                .mode(fan: 0, value: 1), .forceKey(1), .mode(fan: 0, value: 0), .forceKey(0),
            ])
    }

    /// A request moves the epoch, before any write, and supersedes any engagement in progress,
    /// whichever fan. **Mutation:** delete `state.epoch &+= 1` from `restoreRequested(_:)`. Red.
    @Test("Any restore request supersedes an engagement in progress")
    func aRestoreRequestMovesTheEpoch() throws {
        let ledger = PlaneWriteLedger(enumerated: [0, 1], forceKey: .present)
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first)
        #expect(try ledger.admitStep(fanAt: 0) == .continuing)

        ledger.restoreRequested(.fan(1))

        #expect(ledger.isCurrent(fanAt: 0) == false)
        #expect(throws: FanControlPlaneError.superseded) { try ledger.admitStep(fanAt: 0) }
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first, "a fresh engagement was not admitted")
    }

    // MARK: - The machine-wide restore

    /// `.everyFan` writes the union of what the preparation step enumerated and what this process
    /// touched, then the key.
    @Test("A machine-wide restore writes the enumerated fans and the touched fans")
    func theMachineWideRestoreIsEnumeratedAndTouched() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal, 2: .nominal], prepared: false)
        _ = await plane.prepareWritePath(enumerating: ScriptedFanEnumeration(indices: [0]))
        try await plane.restoreToAutomatic(.fan(2))

        try await plane.restoreToAutomatic(.everyFan)

        #expect(
            await plane.keyWrites.suffix(3) == [
                .mode(fan: 0, value: 0), .mode(fan: 2, value: 0), .forceKey(0),
            ])
    }

    /// With the bring-up enumeration failed, `.everyFan` still writes every fan this process
    /// engaged or restored — a fan whose own restore was refused included — and the key, then
    /// says the rest is unknown.
    ///
    /// **Mutation:** drop `.union(state.touched)` from `machineWideRestoreRequested()`. Run: red
    /// on the mode write and the fan's mode. **Mutation:** delete the `fanSetUnknown` throw from
    /// `RestorePlan.attemptEvery`. Run: red on the throw.
    @Test("A failed enumeration still restores every touched fan, then throws fanSetUnknown")
    func aFailedEnumerationStillWritesTheTouchedSet() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal],
            stages: [
                .nominal(), .nominal(writes: .refused(reason: "firmware said no")), .nominal(),
            ],
            prepared: false)
        _ = await plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(failure: FakeProviderError(description: "FNum")))
        try await Self.engage([0], on: plane)
        await plane.advance()
        await #expect(throws: FanControlPlaneError.self) {
            try await plane.restoreToAutomatic(.fan(0))
        }
        await plane.advance()

        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await plane.restoreToAutomatic(.everyFan)
        }

        #expect(await plane.keyWrites.suffix(2) == [.mode(fan: 0, value: 0), .forceKey(0)])
        #expect(try await plane.readControlState(ofFan: 0).mode == .automatic)
        #expect(
            await plane.keyWrites.contains(.mode(fan: 1, value: 0)) == false,
            "a fan nothing enumerated or touched was written")
    }

    /// Restore issues no read, on a machine whose reads all fail.
    @Test("A restore needs no read")
    func aRestoreIssuesNoRead() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .held(at: 2_400)], stages: [.blind()])

        try await plane.restoreToAutomatic(.everyFan)

        #expect(await plane.attempts == [.restoreToAutomatic(.everyFan)])
        #expect(await plane.keyWrites == [.mode(fan: 0, value: 0), .forceKey(0)])
    }

    /// A key recorded unknown gets one zero byte; one recorded absent gets nothing.
    @Test("The force key is written when unknown, and never when absent")
    func theKeysPresenceDecidesItsWrite() async throws {
        let unknown = ScriptedControlPlane(fans: [0: .nominal], forceKey: .unknown)
        try await unknown.restoreToAutomatic(.everyFan)
        #expect(await unknown.keyWrites == [.mode(fan: 0, value: 0), .forceKey(0)])

        let absent = ScriptedControlPlane(fans: [0: .nominal], forceKey: .absent)
        try await absent.restoreToAutomatic(.everyFan)
        #expect(await absent.keyWrites == [.mode(fan: 0, value: 0)])
    }

    // MARK: - The preparation step

    /// D5 step 4, over every state the force key can be found in: one machine-wide restore when
    /// it reads set, is unknown, or will not read; nothing when it reads clear or is absent — an
    /// absent key is never read or written.
    ///
    /// **Mutation:** in `WritePathPreparation.needsMachineWideRestore`, answer `false` for
    /// `.unreadable`. Run: red on the blind case. Likewise `.unknown`, and `raw != 0`.
    @Test(
        "The preparation step restores machine-wide exactly when the key is set or unseen",
        arguments: [
            (ForceKeyPresence.present, false, false, false),
            (ForceKeyPresence.present, true, false, true),
            (ForceKeyPresence.present, false, true, true),
            (ForceKeyPresence.unknown, false, false, true),
            (ForceKeyPresence.absent, true, false, false),
        ])
    func thePreparationStepsMachineWideRestore(
        declared: ForceKeyPresence, keySet: Bool, blind: Bool, restores: Bool
    ) async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal, 1: .nominal],
            stages: [blind ? .blind() : .nominal()], forceKey: declared, prepared: false)
        await plane.setForceKey(keySet)

        let report = try #require(
            await plane.prepareWritePath(enumerating: ScriptedFanEnumeration()))

        #expect(report.enumeratedFans == [0, 1])
        #expect((report.machineWideRestore == .landed) == restores)
        #expect(await plane.attempts.contains(.restoreToAutomatic(.everyFan)) == restores)
        if declared == .absent {
            #expect(report.forceKey == .absent)
            #expect(await plane.isForceKeySet, "an absent key was written")
        } else if restores {
            #expect(await plane.isForceKeySet == false)
        }
    }

    /// A failed enumeration is recorded, not fatal: the report says so, and the next machine-wide
    /// restore knows its fan set is unknown.
    @Test("A failed enumeration is reported, and leaves the fan set unknown")
    func aFailedEnumerationIsReported() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], prepared: false)

        let report = await plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(failure: FakeProviderError(description: "FNum")))

        #expect(report?.enumeratedFans == nil)
        #expect(report?.machineWideRestore == nil)
        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await plane.restoreToAutomatic(.everyFan)
        }
    }

    /// The production plane cannot write, so its preparation step does nothing at all: no
    /// enumeration, no read, no write, and nothing reported.
    ///
    /// **Mutation:** make `SMCFanControlPlane.prepareWritePath(enumerating:)` enumerate before
    /// returning `nil`. Run: red on the enumeration count.
    @Test("On a plane that cannot write, the preparation step does nothing")
    func thePreparationStepIsANoOpOnANotBuiltPlane() async throws {
        let provider = FakeSensorProvider(keyedResults: [:])
        let enumeration = ScriptedFanEnumeration()

        let report = await supervisorPlane(over: provider)
            .prepareWritePath(enumerating: enumeration)

        #expect(report == nil)
        #expect(await enumeration.callCount == 0)
        #expect(await provider.subsetRequests.isEmpty)
        #expect(await provider.readAllCount == 0)
    }

    /// The write path's preparation step runs after the registries are bound and before
    /// reconciliation (D5).
    ///
    /// - **Before the bind**, the machine-wide restore it may issue would hand fans back with
    ///   neither safety registry bound.
    /// - **After reconciliation**, a force key a dead helper left set — with every fan already
    ///   automatic, which reconciliation's per-fan pass cannot see — would outlive the pass, and
    ///   reconciliation's own machine-wide fallback would run on a fan set nothing recorded.
    ///
    /// **Mutation:** move `await prepareWritePath()` below `await reconcileFans()`, or above
    /// `await bindSafetyRegistries()`. Run: red on the edge it moved past.
    @Test("The write path is prepared between the registry bind and reconciliation")
    func thePreparationStepSitsBetweenTheBindAndReconciliation() throws {
        let code = try HelperCompositionTests.compositionSource()
        let start = try #require(
            code.range(of: "func bringUp() async {"),
            "HelperComposition no longer has a bring-up function to order the step against")
        let end = try #require(
            code.range(of: "func observeSystemPower()", range: start.upperBound..<code.endIndex))
        let body = code[start.upperBound..<end.lowerBound]

        let bind = try #require(body.range(of: "await bindSafetyRegistries()"))
        let prepare = try #require(
            body.range(of: "await prepareWritePath()"),
            "bring-up no longer prepares the write path (ADR 0014 D5)")
        let reconcile = try #require(body.range(of: "await reconcileFans()"))

        #expect(
            bind.upperBound < prepare.lowerBound,
            "the write path is prepared before the safety registries are bound")
        #expect(
            prepare.upperBound < reconcile.lowerBound,
            "the write path is prepared after reconciliation, so a stray force key outlives it")
    }

    /// The composition's step, over the composed graph: the plane is handed the composition's
    /// own enumeration, a force key a dead helper left set is cleared, and the report is logged.
    @Test("Bring-up's preparation step clears a lingering force key and logs what it found")
    func theComposedStepClearsALingeringKey() async throws {
        let recorded = RecordedLog()
        let helper = HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .nominal, 1: .nominal],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)],
                prepared: false),
            snapshotProvider: fanProvider(fanCount: 2),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog, leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { recorded.append($0, $1) }))
        await helper.plane.setForceKey(true)

        await helper.bindSafetyRegistries()
        await helper.prepareWritePath()

        #expect(await helper.plane.preparations == 1)
        #expect(await helper.plane.isForceKeySet == false, "the lingering key was not cleared")
        #expect(
            await helper.plane.keyWrites == [
                .mode(fan: 0, value: 0), .mode(fan: 1, value: 0), .forceKey(0),
            ])
        let line = try #require(recorded.lines(containing: "preparation step").first)
        #expect(line.contains("enumerated 2 fan(s) [0, 1]"))
        #expect(line.contains("which landed"))
    }

    /// A machine-wide restore the preparation step issued and the firmware refused is a fault:
    /// a force key may still be set.
    @Test("A refused preparation restore is logged at fault")
    func aRefusedPreparationRestoreIsAFault() {
        let recorded = RecordedLog()
        SafetyLog(recording: { recorded.append($0, $1) }).writePathPrepared(
            WritePathPreparation(
                enumeratedFans: [0, 1], forceKey: .reads(1),
                machineWideRestore: .refused(detail: "no")))

        #expect(recorded.levels == [.fault])
        #expect(recorded.lines.first?.contains("which was refused") == true)
    }

    /// What the composition logs: `.fault` when the enumeration failed or the restore it issued
    /// was refused, which is what D8's start-0 check reads.
    @Test("The preparation report is logged, at fault when it found something wrong")
    func thePreparationReportIsLogged() {
        let recorded = RecordedLog()
        let log = SafetyLog(recording: { recorded.append($0, $1) })

        log.writePathPrepared(
            WritePathPreparation(
                enumeratedFans: [0, 1], forceKey: .reads(0), machineWideRestore: nil))
        log.writePathPrepared(
            WritePathPreparation(enumeratedFans: nil, forceKey: .reads(0), machineWideRestore: nil))

        #expect(recorded.levels == [.notice, .fault])
        #expect(recorded.lines.first?.contains("enumerated 2 fan(s)") == true)
        #expect(recorded.lines.last?.contains("could not enumerate the fans") == true)
    }
}

/// The composition's latch census, in an extension so the suite's body stays under
/// `type_body_length`. It is the same suite.
extension PlaneRestoreContractTests {

    /// The composition hands both drivers § 3's own latch, § 5's and level 6's — a second latch
    /// would be an entitlement check against a bit nothing sets. Each `EngagementDriver(` argument
    /// list is read to its balanced close (`SeamScanner.closingParenthesis`): level 6's holds a
    /// `SafetyActorWriter(…)` of its own, so the first `),` is not the list's end.
    ///
    /// **Mutation:** in `HelperComposition.init`, compose level 6's driver with `latch:
    /// ThermalEmergencyLatch()`. Run: red here, and in `LevelSixCompositionTests`.
    @Test("Both composed drivers read the composed latch")
    func theComposedDriverReadsTheComposedLatch() throws {
        let code = try HelperCompositionTests.compositionSource()
        var lists: [Substring] = []
        var rest = code.startIndex..<code.endIndex
        while let found = code.range(of: "EngagementDriver(", range: rest) {
            let open = code.index(before: found.upperBound)
            let close = try #require(SeamScanner.closingParenthesis(in: code, openingAt: open))
            lists.append(code[open...close])
            rest = close..<code.endIndex
        }
        #expect(
            lists.count == 2,
            "the composition builds \(lists.count) drivers, not § 5's and level 6's")
        #expect(
            lists.allSatisfy { $0.contains("latch: latch,") },
            "a composed driver reads a latch of its own: \(lists)")
    }
}
