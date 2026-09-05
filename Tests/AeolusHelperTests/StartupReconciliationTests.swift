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
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        fanCount: Int? = nil,
        extraKeys: [String: Result<SensorReading, SensorReadFailure>] = [:],
        clock: some MonotonicClock = SystemMonotonicClock(),
        budget: Duration = ReconciliationLimits.budget
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: fans,
                stages: stages.isEmpty
                    ? [
                        .nominal(
                            temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                    ] : stages),
            snapshotProvider: fanProvider(
                fanCount: fanCount ?? fans.count, extraKeys: extraKeys),
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

    /// The cold-restart path this whole mechanism exists for, on a machine whose `FNum` will
    /// not read.
    ///
    /// Ruling D24: the keystone needs no data, so it runs wherever the pass cannot see, and
    /// an enumeration failure is the case where it can see *least*. The previous behaviour
    /// abandoned the pass and restored nothing — no per-fan restore, no machine-wide verb,
    /// and no fan recorded as unreconciled, because no fan index exists to record. A fan the
    /// dead helper left pinned stayed pinned.
    ///
    /// **Mutation:** replace the body of `reconcile()`'s enumeration `catch` with
    /// `log.reconciliationEnumerationFailed(...); return`. Run: red.
    @Test("An enumeration that fails takes the machine-wide restore, having no fan to name")
    func aFailedEnumerationStillTakesTheKeystone() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400)],
            extraKeys: [
                SMCFanEnumeration.fanCountKey: .failure(.readFailed(reason: "FNum did not answer"))
            ])

        await helper.bringUp()
        await helper.shutDown()

        let issued = await Self.restores(helper)
        #expect(
            issued == [.everyFan],
            """
            A helper that could not enumerate its fans issued \(issued) instead of one \
            unconditional machine-wide restore. This is the branch most likely to be taken \
            on the restart docs/SAFETY.md § 6 exists to cover, and abandoning it leaves \
            every fan in whatever mode the dead process left it — with no index to name, no \
            registry entry, and nothing that will look again.
            """)
        #expect(
            await helper.reconciliation.establishedNothing == false,
            "the keystone landed, so nothing is left in an unknown mode to refuse over")
    }

    /// The same branch, on firmware that refuses the keystone too.
    ///
    /// The pass then established nothing whatever — not one fan's mode, not one fan's index
    /// — and every grant is refused for the life of the process. `unreconciledFans` cannot
    /// carry that: it is a set of indices and there are none, so an empty set would read as
    /// a clean run.
    ///
    /// The refusal is asked of the baseline directly rather than through `acquireLease`,
    /// because `acquireLease` enumerates through the same failing seam and throws first.
    /// That is fail-safe, and it is also why the durable flag is worth having: the
    /// enumeration may start answering later in the process, and nothing runs this pass
    /// again to establish what it never did.
    ///
    /// **Mutation:** delete `nothingEstablished = true` from the enumeration `catch`. Run:
    /// red.
    @Test("An enumeration failure the keystone cannot cover refuses every grant durably")
    func aFailedEnumerationAndKeystoneRefusesDurably() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400)],
            writes: .refused(reason: "the firmware refused the mode write"),
            extraKeys: [
                SMCFanEnumeration.fanCountKey: .failure(.readFailed(reason: "FNum did not answer"))
            ])

        await helper.bringUp()
        await helper.shutDown()

        #expect(
            await helper.reconciliation.establishedNothing,
            """
            Neither the enumeration nor the machine-wide restore succeeded, so nothing has \
            established or changed any fan's mode — and yet a lease could be granted over \
            one. That is CLAUDE.md rule 6: control claimed over a fan nothing has looked at.
            """)
        #expect(
            await helper.reconciliation.refusalForGrant(overFans: [0], heldByAeolus: [])
                == .supervisorBlind,
            "a fan on a machine reconciliation never saw at all was not refused")
    }

    /// One-shot is a property of the mechanism, not of the one call site that exists today.
    ///
    /// A second pass would clear every durable refusal above and hand a fan back a second
    /// time — the first move of the restore contest ADR 0011's D2 declines to enter. The
    /// firmware refuses the write here so that fan 0 stays in manual afterwards: on a plane
    /// that honoured it the fan would read automatic and a second pass would find nothing to
    /// do, which would make this test pass with the guard deleted.
    ///
    /// **Mutation:** delete the `guard !hasRun` block from `reconcile()`. Run: red.
    @Test("A second reconciliation pass is declined rather than run")
    func theSecondPassIsDeclined() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400)],
            writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bringUp()
        await helper.shutDown()
        // #110's bounded restorer spends several attempts on one refused fan, so the
        // property is "the first pass's attempts and no more", not a literal count.
        let afterOnePass = await Self.restores(helper)
        #expect(
            afterOnePass.allSatisfy { $0 == .fan(0) } && !afterOnePass.isEmpty,
            "the first pass did not do the restore the second must not repeat")

        await helper.reconciliation.reconcile()

        let issued = await Self.restores(helper)
        #expect(
            issued == afterOnePass,
            """
            A second reconcile() took the restore count from \(afterOnePass.count) to \
            \(issued.count). Running the pass again re-restores a fan whatever is holding it \
            has just re-asserted, which is the two-programs-writing fight ADR 0011 refuses — \
            and it would clear the durable refusals the first pass established on its way \
            through.
            """)
        #expect(
            await helper.reconciliation.fansWithRefusedHandback == [0],
            "the second pass discarded what the first established about fan 0")
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

    /// A fan the pass found in manual and could not hand back is refused as Aeolus's own
    /// failure, not as somebody else's fan.
    ///
    /// Ruling D23. The fan is pinned, in neither safety registry, never retried and outside
    /// § 3's bridge — [#201](https://github.com/blamechris/Aeolus/issues/201) — so the one
    /// thing this process must not do is claim it. `.restoreToAutomaticFailed` is that
    /// claim's refusal and is the reason's own definition: *"it asked for automatic, was
    /// refused, and stopped asking"*.
    ///
    /// It is answered from the durable set rather than from the fresh grant-time read, and
    /// the difference is what the set buys: the read says `.foreignManualControl` while the
    /// fan still reads manual and grants the lease the moment something else hands it back
    /// — over a fan this process has proved it cannot give up.
    ///
    /// **Mutation:** delete the `handbackRefused` guard from `refusalForGrant(overFans:
    /// heldByAeolus:)`. Run: red — the refusal becomes `.foreignManualControl`.
    @Test("A fan whose reconciliation handback the firmware refused is refused durably")
    func aRefusedHandbackIsRefusedAsAeolussOwnFailure() async throws {
        let helper = Self.composed(
            fans: [0: .held(at: 2_400)],
            writes: .refused(reason: "the firmware refused the mode write"))

        await helper.bringUp()
        await helper.shutDown()

        #expect(
            await helper.reconciliation.fansWithRefusedHandback == [0],
            "a fan the firmware would not hand back was not recorded as one")
        #expect(
            await helper.reconciliation.unreconciledFans.isEmpty,
            """
            A fan whose mode was read and acted on is not unreconciled — that set means \
            "nobody looked", and this fan was looked at.
            """)
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
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

    /// The budget bounds the pass, the keystone covers what it never reached, and a fan the
    /// pass *did* reach is still grantable.
    ///
    /// Ruling D24 added the middle clause. A fan the budget never reached and a fan whose
    /// mode read threw are both fans of unknown mode, and only one of them used to get the
    /// verb that needs no data — an asymmetry nothing argued for.
    ///
    /// **The firmware refuses the write here, and that is load-bearing rather than
    /// incidental.** On a plane that honoured the keystone, every fan would be back on
    /// automatic control and the durable refusal below would be *wrong* to make — which is
    /// exactly what `restoreEveryFan()` clearing `unreconciled` on success means. The
    /// scenario worth pinning is the one where the machine-wide verb was issued and did not
    /// land: the fans stay unknown, and stay refused.
    ///
    /// **Mutation:** delete `await restoreEveryFan(because: .budgetExhausted)` from the end
    /// of `reconcile()`. Run: red.
    @Test("The budget bounds the pass, and the fans it never reached are refused")
    func anExhaustedBudgetStillReturnsAndRefusesDurably() async throws {
        let clock = TestClock()
        let scripted = ScriptedControlPlane(
            fans: [
                0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
                2: .automatic(at: 1_800),
            ],
            stages: [
                .nominal(
                    temperatures: LeaseFixture.nominalDieTemperatures,
                    writes: .refused(reason: "the firmware refused the mode write"))
            ])
        let plane = ClockAdvancingPlane(wrapping: scripted, advancing: clock)
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
        let issued = await scripted.attempts.compactMap { attempt -> FanRestoreScope? in
            guard case .restoreToAutomatic(let scope) = attempt else { return nil }
            return scope
        }
        #expect(
            issued == [.everyFan],
            """
            The budget ran out with fans 1 and 2 never read and issued \(issued). A fan \
            nobody looked at is in the same state as a fan whose read threw, and that branch \
            takes the machine-wide keystone — it needs no data, which is the whole reason \
            ADR 0007 makes it the keystone. Refusing a lease over such a fan does not spin \
            it back down (ruling D24).
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

    /// One composed helper whose *snapshot* sees fan 0 in manual while the *plane* sees it
    /// automatic, which is what lets a test both take a real lease and read a manual fan.
    ///
    /// The two sources are genuinely separate in production — the snapshot reads `F0Md`
    /// through `SnapshotFanModeReads`, and every control-path read goes through the plane —
    /// so this is a divergence the shipping code can observe, not one invented for the test.
    /// A plane that reported manual would refuse the lease as foreign control before the
    /// snapshot's own rule could be reached, and the rule under test here is the snapshot's.
    private static func helperSeeingFanZeroInManual(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .automatic(at: 2_400)],
                stages: [
                    .nominal(
                        temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                ]),
            snapshotProvider: fanProvider(
                fanCount: 1, extraKeys: ["F0Md": .reading("F0Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)
    }

    /// A fan Aeolus's own live lease covers is never reported as another program's.
    ///
    /// `F<n>Md` reads `1` for a fan Aeolus is holding and for a fan somebody else is
    /// holding, and names no owner either way — so the lease exclusion in
    /// `reportingForeignControl(of:heldByAeolus:)` is the only thing between a user and
    /// being told to go and quit software that is not running. Until this test existed the
    /// clause could be deleted with the whole non-hardware suite staying green: nothing put
    /// a fan under a live lease *and* in manual at once.
    ///
    /// **Mutation:** delete `!held.contains(fan.index)` from
    /// `ReadOnlyFanReport.reportingForeignControl(of:heldByAeolus:)`. Run: red.
    @Test("A fan under a live lease is Aeolus's own on the snapshot, not somebody else's")
    func aLeasedFanIsNotReportedAsForeign() async throws {
        let helper = Self.helperSeeingFanZeroInManual()
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        let snapshot = try await helper.authority.snapshot()

        let fan = try #require(snapshot.fans.first)
        #expect(fan.mode == .manualFixed, "the fixture no longer reports fan 0 in manual")
        #expect(
            fan.manualControlAvailability != .unavailable(.foreignManualControl),
            """
            A fan under Aeolus's own live lease is reported to the user as being held by \
            another program. That is CLAUDE.md rule 6 pointed at the user: it sends them to \
            quit software that is not holding the fan, and hides that Aeolus is.
            """)
        #expect(snapshot.activeLease != nil, "the lease vanished from the same snapshot")
    }

    /// A fan Aeolus pinned and could not hand back is Aeolus's failure, not a third party's.
    ///
    /// The snapshot and the grant path used to judge "foreign" against different sets: the
    /// grant path against `fansAeolusIsAccountableFor` (leases ∪ abandoned handbacks ∪
    /// releases in flight), the snapshot against the first lease's fans alone. So the lease
    /// core correctly refused this fan `.restoreToAutomaticFailed` while the snapshot told
    /// the user another program had it — the worst available wrong answer, because it is
    /// actionable and the action is futile.
    ///
    /// **Mutation:** return `table.all.first?.fanIndices ?? []` instead of
    /// `fansAeolusIsAccountableFor` from `LeaseAuthority.activeLeaseView()`. Run: red.
    @Test("A fan whose handback was abandoned is not reported as another program's")
    func anAbandonedHandbackIsNotReportedAsForeign() async throws {
        let helper = Self.helperSeeingFanZeroInManual(
            writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bindSafetyRegistries()
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await helper.leases.releaseLease(id: lease.id, from: connection)

        let snapshot = try await helper.authority.snapshot()

        #expect(
            snapshot.activeLease == nil, "the released lease is still reported as live")
        #expect(
            try #require(snapshot.fans.first).manualControlAvailability
                != .unavailable(.foreignManualControl),
            """
            A fan Aeolus put into manual and could not hand back is reported as somebody \
            else's. The lease core refuses it `.restoreToAutomaticFailed` in the same \
            breath, so the two halves of the helper are telling the user opposite stories \
            about whose fault it is.
            """)
    }

    /// A fan § 5 diagnosed as taken back by the operating system keeps that diagnosis.
    ///
    /// The precedence is keyed on the ledger's own cause, through `isReclaimedBySystem`,
    /// rather than on an availability value. `availability(whenLedgerSays:)` maps a
    /// reclamation to `.writePathNotBuilt` in this build — #140's rule — so the arm that
    /// looked for `.unavailable(.reclaimedBySystem)` matched nothing and the protection it
    /// documented did not exist.
    ///
    /// **Mutation:** delete `!fan.isReclaimedBySystem` from
    /// `ReadOnlyFanReport.reportingForeignControl(of:heldByAeolus:)`. Run: red.
    @Test("A fan the system reclaimed is not reported as another program's")
    func aReclaimedFanIsNotReportedAsForeign() async throws {
        let reclaimed = HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
            snapshotProvider: fanProvider(
                fanCount: 1, extraKeys: ["F0Md": .reading("F0Md", 1)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)
        await reclaimed.ledger.markReclaimed(fanAt: 0)

        let snapshot = try await reclaimed.authority.snapshot()

        let fan = try #require(snapshot.fans.first)
        #expect(fan.isReclaimedBySystem, "§ 5's ledger entry did not reach the snapshot")
        #expect(
            fan.manualControlAvailability != .unavailable(.foreignManualControl),
            """
            A fan the operating system took back is reported as being held by another \
            program. reportingForeignControl's own documentation refuses exactly this — it \
            "would blame a third party for the operating system's act" — and the guard that \
            was supposed to prevent it matched an availability nothing produces.
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
