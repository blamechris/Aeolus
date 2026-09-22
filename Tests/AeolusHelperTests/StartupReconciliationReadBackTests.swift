import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// [#204](https://github.com/blamechris/Aeolus/issues/204): the keystone earns a read-back,
/// and only the read-back clears a refusal — and the snapshot says what the grant path says.
///
/// Before #204, `restoreEveryFan(because:)` cleared `unreconciled` and `nothingEstablished`
/// the moment `restoreToAutomatic(.everyFan)` returned. That is a write that did not throw,
/// not a fan in automatic, and `docs/SAFETY.md` § 5 is built on the difference. The plane
/// below accepts the machine-wide write and leaves named fans in manual: the one firmware
/// behaviour the old code could not see.
@Suite("Startup reconciliation's keystone read-back", .timeLimit(.minutes(1)))
struct StartupReconciliationReadBackTests {

    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    private static func everyFanRestores(_ plane: ScriptedControlPlane) async -> Int {
        await plane.attempts.filter { $0 == .restoreToAutomatic(.everyFan) }.count
    }

    // MARK: - The read-back

    /// The case #204 names: firmware accepts `.everyFan` and does not apply it to one fan.
    ///
    /// What the pre-#204 code did here was not grant a lease — the grant path's fresh read
    /// refuses a fan reading manual — but refuse it as `.foreignManualControl`, blaming
    /// another program, and only for as long as it kept reading manual.
    ///
    /// **Mutation:** in `restoreEveryFan(because:until:)`, replace
    /// `await confirmKeystone(until: deadline)` with the pre-#204 body,
    /// `unreconciled = []; nothingEstablished = false`. Run: red — fan 1 is refused as
    /// `.foreignManualControl`, not durably.
    @Test("A keystone the firmware accepts but does not apply leaves that fan refused")
    func anUnappliedKeystoneKeepsTheRefusal() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let plane = ReadBackScriptedPlane(
            wrapping: scripted, modeReadsFailingFirst: 1, keystoneMisses: [1])
        let reconciliation = LeaseFixture.reconciliation(
            over: plane, enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(await Self.everyFanRestores(scripted) == 1, "the keystone was never issued")
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [1], heldByAeolus: [], awaitingConfirmation: [])
                == .supervisorBlind,
            """
            Fan 1 still reads manual after a machine-wide restore the firmware accepted, and \
            was not refused durably. Before #204 the write not throwing cleared the refusal, \
            so the grant path fell through to its fresh read and blamed another program — \
            and granted the moment anything toggled the fan, over a mode never confirmed.
            """)
        #expect(
            await reconciliation.unreconciledFans == [1],
            """
            A fan still manual after an accepted keystone stays unreconciled (#204's spec). It \
            is not a refused handback: the firmware said yes, and one read cannot tell an \
            unapplied write from a foreign writer re-asserting, or from a write not settled.
            """)
        #expect(await reconciliation.fansWithRefusedHandback.isEmpty)
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: []) == nil,
            "fan 0 read back automatic, and was refused anyway — the read-back over-refuses")
    }

    /// The other direction, so the read-back is not simply "refuse everything".
    ///
    /// **Mutation:** in `confirmKeystone(until:)`, replace
    /// `unreconciled = unconfirmed` with `unreconciled = owed`.
    /// Run: red.
    @Test("A keystone every fan reads back automatic from clears every refusal")
    func aConfirmedKeystoneClears() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted, modeReadsFailingFirst: 1),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(await reconciliation.unreconciledFans.isEmpty)
        #expect(await reconciliation.fansWithRefusedHandback.isEmpty)
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0, 1], heldByAeolus: [], awaitingConfirmation: []) == nil,
            """
            Both fans read back automatic after the keystone, and a grant was still refused. \
            The read-back is what clears a refusal; a read-back that never clears one leaves \
            every machine with one flaky F<n>Md read unleasable for the life of the process.
            """)
    }

    /// The enumeration branch: no fan could be named before the keystone, so the read-back
    /// has to ask the enumeration again.
    ///
    /// **Mutation:** in `confirmKeystone(until:)`, delete `nothingEstablished = false`.
    /// Run: red.
    @Test("An enumeration that answers after the keystone is read back fan by fan")
    func aRecoveredEnumerationIsReadBack() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted, keystoneMisses: [0]),
            enumeration: RecoveringFanEnumeration(indices: [0, 1], failingFirst: 1))

        await reconciliation.reconcile()

        #expect(await Self.everyFanRestores(scripted) == 1, "the keystone was never issued")
        #expect(
            await reconciliation.establishedNothing == false,
            """
            The enumeration answered after the keystone and every fan was read back, so the \
            machine-wide "nothing established" flag should have given way to per-fan facts.
            """)
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [])
                == .supervisorBlind,
            "fan 0 read back manual after the keystone and was not refused durably")
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [1], heldByAeolus: [], awaitingConfirmation: []) == nil,
            "fan 1 read back automatic and was refused anyway")
    }

    /// The budget bounds the read-back too, so an exhausted budget clears nothing.
    ///
    /// The existing budget test refuses the keystone, so the read-back is never reached
    /// there. This one honours it: every fan would read back automatic, if anything read it.
    ///
    /// **Mutation:** in `confirmKeystone(until:)`, delete the `guard clock.now < deadline`
    /// block. Run: red — fans 1 and 2 are read and cleared past the deadline.
    @Test("A keystone issued after the budget ran out reads nothing back and clears nothing")
    func anExhaustedBudgetReadsNothingBack() async throws {
        let clock = TestClock()
        let scripted = ScriptedControlPlane(
            fans: [
                0: .automatic(at: 1_800), 1: .automatic(at: 1_800), 2: .automatic(at: 1_800),
            ],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ClockAdvancingPlane(wrapping: scripted, advancing: clock),
            enumeration: ScriptedFanEnumeration(indices: [0, 1, 2]),
            clock: clock, budget: .seconds(1))

        await reconciliation.reconcile()

        #expect(await Self.everyFanRestores(scripted) == 1, "the keystone was never issued")
        #expect(
            await reconciliation.unreconciledFans == [1, 2],
            """
            The budget was spent before fans 1 and 2 were read, and the read-back cleared them \
            anyway. ReconciliationLimits.budget bounds the whole pass; a read-back that ignores \
            it delays the listener by one read per fan on exactly the machine whose reads are \
            already too slow.
            """)
    }

    /// A fan handed back by name is read back too, when the keystone runs.
    ///
    /// Fan 0 reads manual and is restored by name; the firmware accepts that write, and the
    /// keystone after it, and applies neither. Fan 1's mode never reads, so the keystone runs. A read-back over the
    /// refused fans alone would leave fan 0 with a clean record.
    ///
    /// **Mutation:** in `confirmKeystone(until:)`, replace
    /// `owed = unreconciled.union(handedBackByName)` with `owed = unreconciled`. Run: red —
    /// fan 0 is refused as `.foreignManualControl`, not durably.
    @Test("A fan handed back by name is read back when the keystone runs")
    func aFanHandedBackByNameIsReadBack() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(
                wrapping: scripted, unreadableModes: [1], keystoneMisses: [0],
                perFanMisses: [0]),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [])
                == .supervisorBlind,
            """
            Fan 0 was handed back by name, the write did not throw, and it still reads manual \
            after the keystone. It was not read back, so nothing durable refuses it.
            """)
    }

    /// [#291](https://github.com/blamechris/Aeolus/issues/291) item 1, and the one rule the
    /// test above now shares: a complete pass — every fan read, no keystone — reads back the
    /// fan it handed back by name, exactly as a pass that reached the keystone does.
    ///
    /// Before #291 the outcome for fan 0 depended on fan 1. Here fan 1 reads cleanly, so the
    /// keystone never runs, and fan 0 was never read back: the grant path's fresh read then
    /// blamed another program for a write the firmware may simply not have applied.
    ///
    /// **Mutation:** in `reconcile()`, replace
    /// `await confirmHandbacksByName(until: deadline, fans: fans.count)` with
    /// `log.reconciliationCompleted(fans: fans.count)`. Run: red — fan 0 is refused as
    /// `.foreignManualControl`, not durably.
    @Test("A complete pass reads back a fan it handed back by name")
    func aCompletePassReadsBackAHandbackByName() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: ScriptedControlPlane.FanCondition()],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted, perFanMisses: [0]),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(await Self.everyFanRestores(scripted) == 0, "the keystone ran; not this case")
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [])
                == .supervisorBlind,
            """
            Fan 0 was handed back by name on a complete pass, the write did not throw, and it \
            still reads manual. It was not read back, so nothing durable refuses it — the \
            outcome #291 found depending on whether an unrelated fan's read threw.
            """)
        #expect(await reconciliation.unreconciledFans == [0])
        #expect(
            await reconciliation.fansWithRefusedHandback.isEmpty,
            "an accepted write read back manual is not a refused handback (#204's constraint)")
    }

    /// #291 review finding 2: a keystone the firmware refuses is followed by no read-back, so
    /// a fan handed back by name earlier in the same pass is refused unread rather than left
    /// to the grant path's transient `.foreignManualControl`.
    ///
    /// **Mutation:** in `restoreEveryFan(because:until:)`'s `catch`, delete
    /// `unreconciled.formUnion(handedBackByName)`. Run: red — fan 0 has no durable refusal.
    @Test("A by-name handback before a refused keystone is refused unread")
    func aRefusedKeystoneRefusesTheHandbackByName() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(
                wrapping: scripted, unreadableModes: [1], perFanMisses: [0],
                keystoneRefused: true),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(await reconciliation.unreconciledFans == [0, 1])
        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [])
                == .supervisorBlind,
            "fan 0 was handed back by name, never read back, and is not refused durably")
    }

    /// The other direction: a by-name handback that reads back automatic leaves nothing.
    ///
    /// **Mutation:** in `confirmHandbacksByName(until:fans:)`, replace
    /// `unreconciled = unconfirmed` with `unreconciled = handedBackByName`. Run: red.
    @Test("A complete pass whose by-name handback reads back automatic refuses nothing")
    func aConfirmedHandbackByNameClears() async throws {
        let scripted = ScriptedControlPlane(
            fans: [0: .held(at: 2_400), 1: ScriptedControlPlane.FanCondition()],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await reconciliation.reconcile()

        #expect(await reconciliation.unreconciledFans.isEmpty)
        #expect(await reconciliation.refusalForGrant(
            overFans: [0, 1], heldByAeolus: [], awaitingConfirmation: []) == nil)
    }

    // MARK: - The deadline bounds the whole pass

    /// The deadline starts before the enumeration, so a slow `FNum` read spends the budget.
    ///
    /// **Mutation:** in `reconcile()`, move `let deadline = …` down to just above
    /// `var remaining`, and give the enumeration `catch` `until: clock.now.advanced(by:
    /// budget)`. Run: red — both fans are read and cleared.
    @Test("An enumeration that spends the budget leaves every fan unread and refused")
    func theEnumerationSpendsTheBudget() async throws {
        let clock = TestClock()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted),
            enumeration: RecoveringFanEnumeration(
                indices: [0, 1], failingFirst: 0, advancing: clock, by: .seconds(10)),
            clock: clock, budget: .seconds(1))

        await reconciliation.reconcile()

        #expect(
            await reconciliation.unreconciledFans == [0, 1],
            "the enumeration took ten times the budget and the pass read the fans anyway")
    }

    /// The same bound on the enumeration-failed branch: the keystone's read-back asks the
    /// enumeration again, and the time the failed one took counts.
    ///
    /// **Mutation:** in `reconcile()`'s enumeration `catch`, pass
    /// `until: clock.now.advanced(by: budget)` instead of `until: deadline`. Run: red.
    @Test("A failed enumeration that spent the budget reads nothing back")
    func aFailedEnumerationSpendsTheBudget() async throws {
        let clock = TestClock()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(wrapping: scripted),
            enumeration: RecoveringFanEnumeration(
                indices: [0, 1], failingFirst: 1, advancing: clock, by: .seconds(10),
                onlyWhileFailing: true),
            clock: clock, budget: .seconds(1))

        await reconciliation.reconcile()

        #expect(await reconciliation.establishedNothing == false)
        #expect(
            await reconciliation.unreconciledFans == [0, 1],
            "the failed enumeration took ten times the budget and the read-back ran anyway")
    }

    // MARK: - The snapshot agrees with the grant

    /// #204's item 2: the snapshot names the refusal the grant path would throw.
    ///
    /// Fan 0 reads automatic and is clean. Fan 1's mode never reads, so it stays
    /// `unreconciled`. Fan 2 is left in manual by a keystone the firmware accepted, and the
    /// snapshot's own `F2Md` read says manual too — the sequence a real machine produces —
    /// so the durable refusal has to outrank foreign control, not merely replace
    /// `.available`. On a seam that can write, before #204 the snapshot offered fan 1 as
    /// `.available` and blamed another program for fan 2.
    ///
    /// **Mutation A:** in `ReadOnlyFanReport.reportingForeignControl(of:heldByAeolus:
    /// reconciliation:)`, delete the `if … let durable = …` block. Run: red — fan 1 reads
    /// `.available`, fan 2 `.foreignManualControl`.
    /// **Mutation B:** insert `if fan.mode != .automatic { return restating(fan, as:
    /// .unavailable(.foreignManualControl)) }` above that block. Run: red — fan 2.
    @Test("The snapshot reports reconciliation's refusal with the reason a grant throws")
    func theSnapshotNamesReconciliationsRefusal() async throws {
        let scripted = ScriptedControlPlane(
            fans: [
                0: .automatic(at: 1_800), 1: .automatic(at: 1_800), 2: .held(at: 2_400),
            ],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = HelperComposition(
            plane: ReadBackScriptedPlane(
                wrapping: scripted, unreadableModes: [1], keystoneMisses: [2]),
            snapshotProvider: fanProvider(
                fanCount: 3, extraKeys: ["F2Md": .reading("F2Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)

        await helper.bringUp()

        let snapshot = try await helper.authority.snapshot()
        let expected: [Int: ManualControlAvailability] = [
            0: .available,
            1: .unavailable(.supervisorBlind),
            2: .unavailable(.supervisorBlind),
        ]
        for fan in snapshot.fans {
            #expect(
                fan.manualControlAvailability == expected[fan.index],
                """
                Fan \(fan.index)'s snapshot says \(fan.manualControlAvailability), and \
                reconciliation's baseline says \(String(describing: expected[fan.index])). \
                A screen offering control the grant path refuses is CLAUDE.md rule 6.
                """)
        }

        for index in [1, 2] {
            guard case .unavailable(let reason) = expected[index] else { continue }
            await #expect(throws: AeolusXPCFault.manualControlUnavailable(reason: reason)) {
                _ = try await helper.leases.acquireLease(
                    LeaseFixture.request(fans: [index]), from: ConnectionID())
            }
        }
        await helper.shutDown()
    }

    /// The same machine on today's seam, which cannot write: every grant is refused
    /// `.writePathNotBuilt` first, and the snapshot must not name a reconciliation refusal
    /// no grant returns — least of all `.restoreToAutomaticFailed`, whose firmware was never
    /// written to. Fan 1 is found in manual, its restore is refused by the build exactly as
    /// the production plane refuses it, and it keeps the pre-#204 answer, foreign control,
    /// which `HelperHardwareTests.expectHonestAvailability` holds this machine to. Fan 2's
    /// mode never reads, so it is unreconciled.
    ///
    /// **Mutation A:** delete `fan.manualControlAvailability != .unavailable(.writePathNotBuilt),`
    /// from `reportingForeignControl`. Run: red — fan 1 reads `.restoreToAutomaticFailed` and
    /// fan 2 `.supervisorBlind`.
    /// **Mutation B:** append `|| baseline.refusedHandbacks.contains(fan.index)` to that
    /// condition — the refused-handback half alone. Run: red — fan 1.
    @Test("On a seam that cannot write, the snapshot names no reconciliation refusal")
    func aSeamThatCannotWriteShowsNoDurableRefusal() async throws {
        let scripted = ScriptedControlPlane(
            fans: [
                0: .automatic(at: 1_800), 1: .held(at: 2_400), 2: .automatic(at: 1_800),
            ],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = HelperComposition(
            plane: ReadBackScriptedPlane(
                wrapping: scripted, unreadableModes: [2],
                writeCapability: .notBuilt),
            snapshotProvider: fanProvider(
                fanCount: 3, extraKeys: ["F1Md": .reading("F1Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)

        await helper.bringUp()
        #expect(
            await helper.reconciliation.fansWithRefusedHandback == [1],
            """
            Fan 1 was found in manual on a seam that cannot write, so its restore was refused \
            and it is a refused handback — the case this test exists to render. Without it the \
            assertions below cannot see `.restoreToAutomaticFailed` leak into the snapshot.
            """)

        let snapshot = try await helper.authority.snapshot()
        let expected: [Int: ManualControlAvailability] = [
            0: .unavailable(.writePathNotBuilt),
            1: .unavailable(.foreignManualControl),
            2: .unavailable(.writePathNotBuilt),
        ]
        for fan in snapshot.fans {
            #expect(
                fan.manualControlAvailability == expected[fan.index],
                "fan \(fan.index) reads \(fan.manualControlAvailability) on a seam that cannot write"
            )
        }
        for index in [0, 2] {
            await #expect(
                throws: AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
            ) {
                _ = try await helper.leases.acquireLease(
                    LeaseFixture.request(fans: [index]), from: ConnectionID())
            }
        }
        await helper.shutDown()
    }
}

// MARK: - Doubles

/// A plane that can fail mode reads and can accept a machine-wide restore without applying
/// it to named fans — the firmware behaviour #204 is about.
///
/// Everything else is `ScriptedControlPlane`'s, verbatim.
actor ReadBackScriptedPlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private var modeReadsFailingFirst: Int
    private var unreadableModes: Set<Int>
    private let keystoneMisses: Set<Int>
    private let keystoneRefused: Bool
    private let perFanMisses: Set<Int>
    nonisolated let writeCapability: FanWriteCapability

    /// - Parameters:
    ///   - wrapped: the plane every call is forwarded to.
    ///   - modeReadsFailingFirst: how many `readControlState` calls throw before any answers.
    ///   - unreadableModes: fans whose `readControlState` always throws.
    ///   - keystoneMisses: fans a `.everyFan` restore leaves in manual while returning normally.
    ///   - perFanMisses: fans a `.fan(n)` restore leaves in manual while returning normally.
    ///   - keystoneRefused: whether a `.everyFan` restore throws, as firmware refusing it would.
    ///   - writeCapability: what the seam reports; `.notBuilt` is today's production plane.
    init(
        wrapping wrapped: ScriptedControlPlane,
        modeReadsFailingFirst: Int = 0,
        unreadableModes: Set<Int> = [],
        keystoneMisses: Set<Int> = [],
        perFanMisses: Set<Int> = [],
        keystoneRefused: Bool = false,
        writeCapability: FanWriteCapability = .built
    ) {
        self.wrapped = wrapped
        self.modeReadsFailingFirst = modeReadsFailingFirst
        self.unreadableModes = unreadableModes
        self.keystoneMisses = keystoneMisses
        self.perFanMisses = perFanMisses
        self.keystoneRefused = keystoneRefused
        self.writeCapability = writeCapability
    }

    /// From now on, `fan`'s mode read throws — for a test whose setup needs it readable first.
    func makeUnreadable(_ fan: Int) {
        unreadableModes.insert(fan)
    }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        if modeReadsFailingFirst > 0 {
            modeReadsFailingFirst -= 1
            throw FanControlPlaneError.readFailed(detail: "F\(index)Md did not answer")
        }
        guard !unreadableModes.contains(index) else {
            throw FanControlPlaneError.readFailed(detail: "F\(index)Md never answers")
        }
        return try await wrapped.readControlState(ofFan: index)
    }

    func readCriticalTemperatures(_ keys: [SMCKey]) async throws -> CriticalTemperatureReport {
        try await wrapped.readCriticalTemperatures(keys)
    }

    func readEnvelope(ofFan index: Int) async throws -> FanEnvelope {
        try await wrapped.readEnvelope(ofFan: index)
    }

    func reconnect() async throws {
        try await wrapped.reconnect()
    }

    func restoreToAutomatic(_ scope: FanRestoreScope) async throws {
        // What the production plane does: a seam that cannot write refuses every write verb,
        // so a fan found in manual is abandoned by the restorer and lands in `handbackRefused`.
        guard writeCapability == .built else { throw FanControlPlaneError.controlPathNotBuilt }
        if keystoneRefused, case .everyFan = scope {
            throw FanControlPlaneError.firmwareRefusedControl(detail: "the keystone was refused")
        }
        try await wrapped.restoreToAutomatic(scope)
        let misses: Set<Int>
        switch scope {
        case .everyFan: misses = keystoneMisses
        case .fan(let index): misses = perFanMisses.intersection([index])
        }
        for fan in misses {
            await wrapped.setMode(.manual, ofFan: fan)
        }
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}

/// An enumeration that throws for its first `failingFirst` calls and then answers, and can
/// cost virtual time — on every call, or only on the calls that fail.
actor RecoveringFanEnumeration: FanEnumerating {

    private let indices: Set<Int>
    private var failuresLeft: Int
    private let clock: TestClock?
    private let cost: Duration
    private let onlyWhileFailing: Bool

    init(
        indices: Set<Int>, failingFirst: Int, advancing clock: TestClock? = nil,
        by cost: Duration = .zero, onlyWhileFailing: Bool = false
    ) {
        self.indices = indices
        self.failuresLeft = failingFirst
        self.clock = clock
        self.cost = cost
        self.onlyWhileFailing = onlyWhileFailing
    }

    func enumeratedFanIndices() async throws -> Set<Int> {
        if !onlyWhileFailing || failuresLeft > 0 { clock?.advance(by: cost) }
        guard failuresLeft == 0 else {
            failuresLeft -= 1
            throw FanControlPlaneError.readFailed(detail: "FNum did not answer")
        }
        return indices
    }
}
