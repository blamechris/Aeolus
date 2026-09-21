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
    /// **Mutation:** in `restoreEveryFan(because:until:)`, replace
    /// `await confirmKeystone(until: deadline)` with the pre-#204 body,
    /// `unreconciled = []; nothingEstablished = false`. Run: red — fan 1 is granted.
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
            await reconciliation.refusalForGrant(overFans: [1], heldByAeolus: [])
                == .restoreToAutomaticFailed,
            """
            Fan 1 still reads manual after a machine-wide restore the firmware accepted, and \
            the grant path did not refuse it as Aeolus's own failed handback. Before #204 the \
            write not throwing was taken as the fan being automatic: a lease would be granted \
            over a fan still pinned, held in neither safety registry.
            """)
        #expect(
            await reconciliation.fansWithRefusedHandback == [1],
            """
            A fan read back in manual after Aeolus asked for automatic control is a refused \
            handback — it was looked at, so it is not `unreconciled`.
            """)
        #expect(
            await reconciliation.refusalForGrant(overFans: [0], heldByAeolus: []) == nil,
            "fan 0 read back automatic, and was refused anyway — the read-back over-refuses")
    }

    /// The other direction, so the read-back is not simply "refuse everything".
    ///
    /// **Mutation:** in `confirmKeystone(until:)`, replace `unreconciled = unknown` with
    /// `unreconciled = owed`. Run: red.
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
            await reconciliation.refusalForGrant(overFans: [0, 1], heldByAeolus: []) == nil,
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
            await reconciliation.refusalForGrant(overFans: [0], heldByAeolus: [])
                == .restoreToAutomaticFailed,
            "fan 0 read back manual after the keystone and was not refused as a failed handback")
        #expect(
            await reconciliation.refusalForGrant(overFans: [1], heldByAeolus: []) == nil,
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

    // MARK: - The snapshot agrees with the grant

    /// #204's item 2: the snapshot names the refusal the grant path would throw.
    ///
    /// Fan 0 reads automatic and is clean. Fan 1's mode never reads, so it stays
    /// `unreconciled`. Fan 2 is left in manual by a keystone the firmware accepted. The
    /// sensor provider reports all three automatic with plausible bounds on a seam that can
    /// write, so before #204 the snapshot offered all three as `.available` while the grant
    /// path refused two of them.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.reportingForeignControl(of:heldByAeolus:
    /// reconciliation:)`, delete the `if let durable = …` block. Run: red — fans 1 and 2
    /// read `.available`.
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
            snapshotProvider: fanProvider(fanCount: 3),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)

        await helper.bringUp()

        let snapshot = try await helper.authority.snapshot()
        let expected: [Int: ManualControlAvailability] = [
            0: .available,
            1: .unavailable(.supervisorBlind),
            2: .unavailable(.restoreToAutomaticFailed),
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
}

// MARK: - Doubles

/// A plane that can fail mode reads and can accept a machine-wide restore without applying
/// it to named fans — the firmware behaviour #204 is about.
///
/// Everything else is `ScriptedControlPlane`'s, verbatim.
actor ReadBackScriptedPlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private var modeReadsFailingFirst: Int
    private let unreadableModes: Set<Int>
    private let keystoneMisses: Set<Int>

    /// - Parameters:
    ///   - wrapped: the plane every call is forwarded to.
    ///   - modeReadsFailingFirst: how many `readControlState` calls throw before any answers.
    ///   - unreadableModes: fans whose `readControlState` always throws.
    ///   - keystoneMisses: fans a `.everyFan` restore leaves in manual while returning normally.
    init(
        wrapping wrapped: ScriptedControlPlane,
        modeReadsFailingFirst: Int = 0,
        unreadableModes: Set<Int> = [],
        keystoneMisses: Set<Int> = []
    ) {
        self.wrapped = wrapped
        self.modeReadsFailingFirst = modeReadsFailingFirst
        self.unreadableModes = unreadableModes
        self.keystoneMisses = keystoneMisses
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

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
        try await wrapped.restoreToAutomatic(scope)
        guard scope == .everyFan else { return }
        for fan in keystoneMisses {
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

/// An enumeration that throws for its first `failingFirst` calls and then answers.
actor RecoveringFanEnumeration: FanEnumerating {

    private let indices: Set<Int>
    private var failuresLeft: Int

    init(indices: Set<Int>, failingFirst: Int) {
        self.indices = indices
        self.failuresLeft = failingFirst
    }

    func enumeratedFanIndices() async throws -> Set<Int> {
        guard failuresLeft == 0 else {
            failuresLeft -= 1
            throw FanControlPlaneError.readFailed(detail: "FNum did not answer")
        }
        return indices
    }
}
