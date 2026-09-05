import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 6's one-shot pass, and the baseline it leaves behind.
///
/// Every test here composes the **real** graph — `HelperComposition` over
/// `ScriptedControlPlane` — rather than driving `StartupReconciliation` in isolation. The
/// mechanism is only correct in a particular position (after the registries are bound,
/// before the supervisors start, before the listener resumes), so a suite that constructed
/// the actor by hand would test the pass and not the thing #164 is about.
@Suite("Startup reconciliation and foreign manual control", .timeLimit(.minutes(1)))
struct StartupReconciliationTests {

    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    private static func composed(
        fans: [Int: ScriptedControlPlane.FanCondition],
        stages: [ScriptedControlPlane.Stage] = [],
        fanCount: Int? = nil,
        clock: some MonotonicClock = SystemMonotonicClock(),
        budget: Duration = ReconciliationLimits.budget
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: fans,
                stages: stages.isEmpty
                    ? [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)] : stages),
            snapshotProvider: fanProvider(fanCount: fanCount ?? fans.count),
            criticalSensors: .mac16x5,
            clock: clock,
            reconciliationBudget: budget,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog)
    }

    private static func restores(
        _ helper: HelperComposition<ScriptedControlPlane>
    ) async -> [FanRestoreScope] {
        await helper.plane.attempts.compactMap { attempt -> FanRestoreScope? in
            guard case .restoreToAutomatic(let scope) = attempt else { return nil }
            return scope
        }
    }

    // MARK: - The pass itself

    @Test("A fan found in manual at bring-up is restored exactly once")
    func aManualFanIsRestoredOnceAndOnlyOnce() async throws {
        let helper = Self.composed(fans: [0: .held(at: 2_400)])

        await helper.bringUp()
        await helper.shutDown()

        #expect(
            await Self.restores(helper) == [.fan(0)],
            """
            Startup reconciliation did not hand fan 0 back exactly once. Zero restores \
            leaves a fan the previous helper died holding pinned with nothing counting a \
            TTL, which is docs/SAFETY.md § 6's whole purpose; two is the beginning of the \
            restore loop ADR 0011 refuses to enter with another writer.
            """)
        #expect(
            try await helper.plane.readControlState(ofFan: 0).mode == .automatic,
            "the fan is still off automatic control after a restore the plane honoured")
        #expect(
            await helper.reconciliation.unreconciledFans.isEmpty,
            "a fan whose mode was read and acted on is not unreconciled")
    }

    @Test("A fan already on automatic control is left alone")
    func anAutomaticFanIsNotWrittenTo() async throws {
        let helper = Self.composed(fans: [0: .automatic(at: 1_800)])

        await helper.bringUp()
        await helper.shutDown()

        #expect(
            await Self.restores(helper).isEmpty,
            """
            A fan already on Apple's thermal management was written to anyway. The keystone \
            verb is idempotent, so this is not unsafe — it is a root daemon issuing a \
            firmware write at every start for no reason, and it would make the fault line \
            that says "this machine had a fan in manual" fire on every boot.
            """)
    }

    @Test("A mode read that fails takes the machine-wide restore, not a per-fan one")
    func aFailedReadFallsBackToEveryFan() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [.blind(reason: "F0Md did not answer")])

        await helper.bringUp()
        await helper.shutDown()

        let issued = await Self.restores(helper)
        #expect(
            issued == [.everyFan],
            """
            A helper that could not read F<n>Md issued \(issued) \
            instead of one unconditional machine-wide restore. ADR 0007's assumption table \
            settles this: the keystone needs no data, so a helper that cannot say which \
            fans are held hands back all of them. Returning early instead leaves every fan \
            in whatever mode the dead process left it.
            """)
        #expect(
            await helper.reconciliation.unreconciledFans.isEmpty,
            """
            The machine-wide restore was honoured, so no fan is left in an unknown mode and \
            none should be refused a lease on account of reconciliation.
            """)
    }

    @Test("A machine-wide restore the firmware refuses leaves every fan refused durably")
    func aRefusedEveryFanRestoreRefusesEveryLease() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
            stages: [
                ScriptedControlPlane.Stage(
                    temperatures: LeaseFixture.nominalDieTemperatures,
                    reads: .failed(reason: "F0Md did not answer"),
                    writes: .refused(reason: "the firmware refused the mode write"))
            ])

        await helper.bringUp()
        await helper.shutDown()

        #expect(
            await helper.reconciliation.unreconciledFans == [0, 1],
            """
            Neither the per-fan reads nor the machine-wide restore succeeded, so nothing has \
            established or changed any fan's mode — and yet a lease could be granted over \
            one. That is CLAUDE.md rule 6: control claimed over a fan nothing has looked at.
            """)
    }

    // MARK: - The baseline, at grant time

    @Test("A fan taken into manual after reconciliation is refused, not restored")
    func aFanTakenAfterwardsIsForeignControl() async throws {
        let helper = Self.composed(fans: [0: .automatic(at: 1_800)])
        await helper.bringUp()
        await helper.shutDown()

        // Something outside Aeolus takes the fan. No attempt is recorded, because Aeolus did
        // not write it — which is the condition the whole mechanism has to recognise.
        await helper.plane.setMode(.manual, ofFan: 0)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .foreignManualControl)
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(
            await Self.restores(helper).isEmpty,
            """
            The helper restored a fan it had already reconciled once. A restore loop against \
            a live writer is the fight ADR 0011 declines: two programs undoing each other's \
            mode write over a machine's cooling, several times a second.
            """)
        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            """
            § 5's registry gained a fan Aeolus never engaged. Its cycle judges divergence \
            from what *Aeolus* commanded, so a foreign fan in there is read as the operating \
            system reclaiming a fan — and the watchdog then contests a write it has no \
            business contesting.
            """)
        #expect(await helper.leases.leaseCount == 0, "a refused grant left a lease behind")
    }

    @Test("A fan a live lease covers is Aeolus's own, never reported as somebody else's")
    func aLeasedFanIsNotForeign() async throws {
        let helper = Self.composed(fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
        await helper.bringUp()
        await helper.shutDown()
        let holder = ConnectionID()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)

        // E3's engage, simulated: the fan Aeolus holds goes into manual.
        await helper.plane.setMode(.manual, ofFan: 0)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient)
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    @Test("A grant-time read that fails refuses rather than guessing")
    func anUnreadableFanIsRefusedAtGrantTime() async throws {
        let helper = Self.composed(
            fans: [0: .automatic(at: 1_800)],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
                .blind(reason: "the SMC stopped answering after bring-up"),
            ])
        await helper.bringUp()
        await helper.shutDown()
        await helper.plane.advance()

        // The curated telemetry read fails on the same blind stage and refuses first, which
        // is the correct precedence — § 3 is a precondition of § 1. The fan-state gate is
        // asked directly here so that its own branch is covered rather than shadowed.
        let refusal = await helper.reconciliation.refusalForGrant(
            overFans: [0], heldByAeolus: [])
        #expect(
            refusal == .supervisorBlind,
            """
            A fan whose control state could not be read was not refused. A lease granted now \
            claims a fan nothing has looked at, and § 5 cannot tell divergence from silence \
            on it either.
            """)
    }

    // MARK: - The budget

    @Test("The budget bounds the pass, and the fans it never reached are refused")
    func anExhaustedBudgetStillReturnsAndRefusesDurably() async throws {
        let clock = TestClock()
        let plane = ClockAdvancingPlane(
            wrapping: ScriptedControlPlane(
                fans: [
                    0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
                    2: .automatic(at: 1_800),
                ],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
            advancing: clock)
        let bounded = HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 3),
            criticalSensors: .mac16x5,
            clock: clock,
            reconciliationBudget: .seconds(1),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)

        // Each mode read costs the whole budget and then some, so fan 0 is read and the
        // deadline is spent before fan 1. The assertion that matters is that this returns
        // at all: `bringUp()` is what `listener.resume()` waits on.
        await bounded.bringUp()
        await bounded.shutDown()

        #expect(
            await bounded.reconciliation.unreconciledFans == [1, 2],
            """
            The budget did not bound the pass in the way the refusal depends on. Fans 1 and \
            2 were never read, so nothing has established their mode.
            """)
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .supervisorBlind)
        ) {
            _ = try await bounded.leases.acquireLease(
                LeaseFixture.request(fans: [1]), from: ConnectionID())
        }
        // Fan 0 *was* read, and reads automatic. The refusal is per fan, not machine-wide:
        // a budget that ran out must not cost a client the fans reconciliation did reach.
        _ = try await bounded.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }
}

/// What a client is told about a fan something outside Aeolus is holding.
///
/// Its own suite because the subject is different: the tests above are about the one-shot
/// pass and the refusal it leaves behind, and these are about the **snapshot** — a read
/// path that performs no restore, consults no budget, and is reached by a client rather
/// than by bring-up. Nothing here calls `bringUp()`, deliberately: a reconciliation pass
/// would restore the very fan whose reporting is under test.
@Suite("Foreign manual control, as a client is shown it", .timeLimit(.minutes(1)))
struct ForeignManualControlReportingTests {

    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    @Test("The snapshot reports the firmware's own mode for a fan nobody in Aeolus holds")
    func theSnapshotReportsForeignManualControl() async throws {
        // The snapshot path reads `F0Md` through the sensor provider, not through the plane,
        // so the provider is what has to say the fan is in manual — exactly as the two
        // sources would on a machine another tool is holding. Nothing here brings the helper
        // up: this is the snapshot's own rule, and a reconciliation pass would restore the
        // fan out from under it.
        let manualHelper = HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
            snapshotProvider: fanProvider(
                fanCount: 1, extraKeys: ["F0Md": .reading("F0Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)

        let snapshot = try await manualHelper.authority.snapshot()

        let fan = try #require(snapshot.fans.first)
        #expect(
            fan.mode == .manualFixed,
            """
            The snapshot reports fan 0 as automatic while F0Md reads 1. A client rendering \
            that shows a fan on Apple's management when another program is holding it, and \
            the user has no way to find out why their machine is loud.
            """)
        #expect(
            fan.manualControlAvailability == .unavailable(.foreignManualControl),
            """
            The snapshot does not say *why* manual control is unavailable for a fan \
            something else is holding. `.writePathNotBuilt` sends the user to look at Aeolus; \
            the truthful answer sends them to the program that has the fan.
            """)
    }

    @Test("A fan § 5 has already diagnosed keeps its own cause")
    func theLedgersCauseOutranksTheBaseline() async throws {
        let observed = HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
            snapshotProvider: fanProvider(
                fanCount: 1, extraKeys: ["F0Md": .reading("F0Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)
        await observed.ledger.markSupervisorBlind(fanAt: 0)

        let snapshot = try await observed.authority.snapshot()

        #expect(
            try #require(snapshot.fans.first).manualControlAvailability
                == .unavailable(.supervisorBlind),
            """
            The foreign-control baseline overwrote § 5's own diagnosis. The ledger holds \
            fans *Aeolus engaged*, so "the helper has gone blind on this fan" is both more \
            specific and about a different subject than "somebody else has it".
            """)
    }
}

// MARK: - Doubles

/// A plane whose every read costs virtual time.
///
/// The reconciliation budget is checked against a `MonotonicClock`, so exhausting it needs
/// time to pass **inside** the pass rather than around it — the same shape
/// `ClockAdvancingProvider` gives `SupervisedFanAuthorityTests` for the snapshot's ordering.
/// A real delay would make the test slow and flaky; this makes it exact.
actor ClockAdvancingPlane: FanControlPlane {

    private let wrapped: ScriptedControlPlane
    private let clock: TestClock
    private let cost: Duration

    init(
        wrapping wrapped: ScriptedControlPlane,
        advancing clock: TestClock,
        costing cost: Duration = .seconds(10)
    ) {
        self.wrapped = wrapped
        self.clock = clock
        self.cost = cost
    }

    nonisolated var writeCapability: FanWriteCapability { .built }

    func readControlState(ofFan index: Int) async throws -> FanControlState {
        clock.advance(by: cost)
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
    }

    func engageManualControl(of fan: CommandableFan) async throws {
        try await wrapped.engageManualControl(of: fan)
    }

    @discardableResult
    func commandTarget(_ target: AuthorisedFanTarget) async throws -> CommandedTarget {
        try await wrapped.commandTarget(target)
    }
}
