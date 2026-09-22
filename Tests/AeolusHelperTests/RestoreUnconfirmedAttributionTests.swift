import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// [#303](https://github.com/blamechris/Aeolus/issues/303): a fan § 3 is keeping because the
/// restore-to-automatic Aeolus issued has not been confirmed by a read is refused as
/// `.restoreToAutomaticUnconfirmed`, not blamed on another program as `.foreignManualControl`.
///
/// Composed, for `AcceptedHandbackCompositionTests`' reason: the defect is wiring — § 3's two
/// registers reaching neither the grant path nor the snapshot — so the graph under test is the
/// one `HelperComposition` builds, bound as `bringUp()` binds it. The supervisors are not
/// started; every § 3 cycle below is driven by hand.
///
/// **Every test reads both sides and requires them to be the same value.** The ladder's rule
/// is that a snapshot names the reason a grant over the same fan throws, and a fix to one side
/// alone is a disagreement; so each named mutation below is on one side, and the other side's
/// assertion is what the test still holds while it goes red.
@Suite("Unconfirmed restores, as a client is told them", .timeLimit(.minutes(1)))
struct RestoreUnconfirmedAttributionTests {

    /// Fan 0 automatic under nominal temperatures, then above § 3's ceiling, then cool again so
    /// the latch releases — with `writes` as the firmware's answer to every write throughout.
    ///
    /// The snapshot reads `F0Md` through the sensor provider and the grant path through the
    /// plane, so the provider is told separately what the snapshot sees: manual for the
    /// scenarios where the firmware kept the fan manual, automatic for the one where it did not.
    private static func composed(
        writes: ScriptedControlPlane.WriteBehaviour, snapshotSeesManual: Bool = true
    ) -> HelperComposition<ControlStateGatePlane> {
        HelperComposition(
            plane: ControlStateGatePlane(
                ScriptedControlPlane(
                    fans: [0: .automatic(at: 2_400)],
                    stages: [
                        .nominal(
                            temperatures: LeaseFixture.nominalDieTemperatures, writes: writes),
                        .at(96, writes: writes),
                        .nominal(
                            temperatures: LeaseFixture.nominalDieTemperatures, writes: writes),
                    ])),
            snapshotProvider: fanProvider(
                fanCount: 1,
                extraKeys: ["F0Md": .reading("F0Md", snapshotSeesManual ? 1 : 0)]),
            criticalSensors: .mac16x5,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: AvailabilityFixture.safetyLog,
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// Binds as the daemon does, registers fan 0 with both registries, takes a lease over it
    /// and puts the firmware into manual as E3's engage write would. Returns the lease's
    /// connection and id so a scenario can end it the ordinary way.
    private static func engageUnderLease(
        in helper: HelperComposition<ControlStateGatePlane>
    ) async throws -> (ConnectionID, Lease) {
        await helper.bindSafetyRegistries()
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        await helper.plane.wrapped.setMode(.manual, ofFan: 0)
        return (connection, lease)
    }

    /// The ordinary teardown: lease taken and released, so the handback is the restorer's.
    private static func engageThenRelease(
        in helper: HelperComposition<ControlStateGatePlane>
    ) async throws {
        let (connection, lease) = try await engageUnderLease(in: helper)
        try await helper.leases.releaseLease(id: lease.id, from: connection)
    }

    /// § 3 fires on fan 0 and the machine cools, so the latch releases and a grant reaches the
    /// foreign-control step instead of stopping at `thermalEmergencyActive`.
    private static func fireAndCool(in helper: HelperComposition<ControlStateGatePlane>) async {
        await helper.plane.wrapped.advance()
        await helper.thermalEmergency.cycle()
        await helper.plane.wrapped.advance()
        await helper.thermalEmergency.cycle()
    }

    /// The snapshot's reason for fan 0, then the grant path's — in that order, so a grant a
    /// mutant wrongly makes cannot change what the snapshot was asked.
    private static func bothSides(
        of helper: HelperComposition<ControlStateGatePlane>
    ) async throws -> (shown: ManualControlAvailability, thrown: ManualControlAvailability.Reason) {
        let shown = try AvailabilityFixture.availability(
            ofFanAt: 0, in: try await helper.authority.snapshot())
        let thrown = await AvailabilityFixture.refusalForGrant(over: 0, from: helper.leases)
        return (shown, thrown)
    }

    // MARK: - The two registers, one each

    /// A fan § 3 bridged and restored itself, whose restore the firmware accepted and
    /// discarded, is refused as Aeolus's own unconfirmed restore — by the snapshot and by the
    /// grant path, with the same value.
    ///
    /// The fan is in `restoredUnconfirmed` alone, which is what lets the second test's
    /// mutation leave this one green.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.reportingForeignControl`, delete the
    /// `if awaiting.contains(fan.index)` arm. Run: red on `shown`.
    /// **Mutation:** in `StartupReconciliation.refusalForGrant`, delete the
    /// `if awaiting.contains(fan)` arm. Run: red on `thrown`.
    /// **Mutation:** in `ThermalEmergency.fansAwaitingRestoreConfirmation`, drop
    /// `.union(fansRestoredUnconfirmed)`. Run: red on both, and the second test stays green.
    /// **Mutation:** delete `await leases.bind(emergencyRestores: thermalEmergency)` from
    /// `HelperComposition.bindSafetyRegistries()`. Run: red on both — unbound is still a
    /// refusal, `.foreignManualControl`, which is the safe direction and the wrong reason.
    @Test("A fan § 3 restored itself, left manual by the firmware, is not somebody else's")
    func aFanSectionThreeRestoredIsNotBlamedOnAnotherProgram() async throws {
        let helper = Self.composed(writes: .reverted)
        _ = try await Self.engageUnderLease(in: helper)
        await Self.fireAndCool(in: helper)

        #expect(await helper.thermalEmergency.isHolding == false, "the latch never released")
        #expect(await helper.thermalEmergency.fansRestoredUnconfirmed == [0])
        #expect(
            await helper.thermalEmergency.fansOwedHandbackReadBack.isEmpty,
            "fan 0 is owed a handback read-back too, so this test no longer isolates § 3's own")

        let (shown, thrown) = try await Self.bothSides(of: helper)
        #expect(
            shown == .unavailable(.restoreToAutomaticUnconfirmed),
            """
            The snapshot tells the user another program holds a fan Aeolus's own emergency \
            restore left in manual. That sends them to quit software that is not running.
            """)
        #expect(thrown == .restoreToAutomaticUnconfirmed)
        #expect(shown == .unavailable(thrown), "the snapshot and the grant path disagree")
    }

    /// A fan whose lease handback the firmware accepted and discarded — no emergency at all —
    /// is refused the same way. The half of the set #303's text did not name.
    ///
    /// **Mutation:** in `ThermalEmergency.fansAwaitingRestoreConfirmation`, drop
    /// `.union(fansOwedHandbackReadBack)` — returning `fansRestoredUnconfirmed` alone. Run:
    /// red here, and the first test stays green: the green half is what proves the two
    /// registers are separately load-bearing, where a mutation reddening both would prove only
    /// that the accessor exists.
    @Test("A fan left manual after an accepted lease handback is not somebody else's")
    func aFanOwedAHandbackReadBackIsNotBlamedOnAnotherProgram() async throws {
        let helper = Self.composed(writes: .reverted)
        try await Self.engageThenRelease(in: helper)

        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
        #expect(await helper.thermalEmergency.fansRestoredUnconfirmed.isEmpty)

        let (shown, thrown) = try await Self.bothSides(of: helper)
        #expect(shown == .unavailable(.restoreToAutomaticUnconfirmed))
        #expect(thrown == .restoreToAutomaticUnconfirmed)
        #expect(shown == .unavailable(thrown), "the snapshot and the grant path disagree")
    }

    // MARK: - A request naming more than one fan

    /// Both fans read manual, and reconciliation has left nothing durable to refuse. Fan 1's
    /// mode read throws when `fanOneUnreadable`.
    private static func twoManualFans(
        fanOneUnreadable: Bool
    ) -> StartupReconciliation<ReadBackScriptedPlane> {
        LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(
                wrapping: ScriptedControlPlane(
                    fans: [0: .held(at: 2_400), 1: .held(at: 2_400)],
                    stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
                unreadableModes: fanOneUnreadable ? [1] : []),
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))
    }

    /// A fan § 3 is keeping does not end the gate's scan: a foreign or unreadable fan later in
    /// the same request is the answer the client gets.
    ///
    /// "Retry" is the advice `.restoreToAutomaticUnconfirmed` carries, and it is a retry
    /// forever about a request that also names a fan another program holds, or one nobody can
    /// read. Fan 0 is the kept one **because** the scan is in index order: kept-first is the only
    /// order in which stopping early could hide fan 1. The last expectation is non-vacuity —
    /// fan 0 on its own is the kept reason, so the first is not passing for want of one.
    ///
    /// **Mutation:** in `StartupReconciliation.refusalForGrant`, replace
    /// `firstUnconfirmed = firstUnconfirmed ?? fan` and the `continue` after it with
    /// `return .restoreToAutomaticUnconfirmed`. Run: red on the first expectation, for both
    /// arguments; the non-vacuity expectation stays green.
    @Test(
        "A fan § 3 is keeping does not hide a foreign or unreadable fan later in the request",
        arguments: [false, true])
    func aKeptFanDoesNotEndTheScan(fanOneUnreadable: Bool) async {
        let reconciliation = Self.twoManualFans(fanOneUnreadable: fanOneUnreadable)

        let reason = await reconciliation.refusalForGrant(
            overFans: [0, 1], heldByAeolus: [], awaitingConfirmation: [0])
        #expect(
            reason == (fanOneUnreadable ? .supervisorBlind : .foreignManualControl),
            "a kept fan's reason was given for a request fan 1's state outranks")

        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [0])
                == .restoreToAutomaticUnconfirmed)
    }

    /// A fan § 3 is keeping whose own grant-time read throws is `.supervisorBlind`, not the kept
    /// reason: nobody can say what mode it is in, and that outranks an unconfirmed restore.
    ///
    /// **Mutation:** in `StartupReconciliation.refusalForGrant`'s `catch`, answer a kept fan as
    /// kept — `if awaiting.contains(fan) { firstUnconfirmed = firstUnconfirmed ?? fan; continue }`
    /// ahead of the `.supervisorBlind` return. Run: red.
    @Test("A fan § 3 is keeping whose read throws is blind, not unconfirmed")
    func aKeptFanWhoseReadThrowsIsBlind() async {
        let reconciliation = LeaseFixture.reconciliation(
            over: ReadBackScriptedPlane(
                wrapping: ScriptedControlPlane(
                    fans: [0: .held(at: 2_400)],
                    stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]),
                unreadableModes: [0]),
            enumeration: ScriptedFanEnumeration(indices: [0]))

        #expect(
            await reconciliation.refusalForGrant(
                overFans: [0], heldByAeolus: [], awaitingConfirmation: [0]) == .supervisorBlind)
    }

    // MARK: - What the fix must not do

    /// A fan in both § 3's set and `restoreAbandoned` is answered by the durable refusal, by
    /// both sides: the firmware refused the handback, which is the more consequential fact.
    ///
    /// **Mutation:** in `StartupReconciliation.refusalForGrant`, stop `held` from exempting a
    /// fan § 3 is keeping — `let candidates = fans.subtracting(held.subtracting(awaiting))`.
    /// Run: red on `thrown`. The snapshot stays `.restoreToAutomaticFailed` under the same
    /// mutation applied there, because `reportingHandbackState` composes after it and
    /// overwrites; that is why the named mutation is on the grant path, and why the agreement
    /// assertion is the one that catches it.
    @Test("Where § 3's set meets an abandoned handback, the durable refusal wins")
    func theDurableRefusalStillWinsWhereTheSetsMeet() async throws {
        let helper = Self.composed(writes: AvailabilityFixture.firmwareRefusesTheModeWrite)
        try await Self.engageThenRelease(in: helper)
        #expect(await helper.leases.fansWithAbandonedHandbacks == [0])

        try await HelperRestorerTests.engage(fan: 0, in: helper)
        await Self.fireAndCool(in: helper)
        #expect(await helper.thermalEmergency.isHolding == false, "the latch never released")
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation.contains(0),
            "fan 0 is not in § 3's set, so this test no longer reaches the intersection")
        #expect(await helper.leases.fansWithAbandonedHandbacks == [0])

        let (shown, thrown) = try await Self.bothSides(of: helper)
        #expect(shown == .unavailable(.restoreToAutomaticFailed))
        #expect(thrown == .restoreToAutomaticFailed)
        #expect(shown == .unavailable(thrown), "the snapshot and the grant path disagree")
    }

    /// A fan § 3 is still keeping that reads automatic is available and granted.
    ///
    /// The register outlives the fact it is waiting for by up to one § 3 cycle after *every*
    /// ordinary handback against compliant firmware. Refusing on membership alone would refuse
    /// re-acquisition throughout that window, and nothing else in this suite would notice.
    ///
    /// **Mutation:** in `ReadOnlyFanReport.reportingForeignControl`, move the
    /// `if awaiting.contains(fan.index)` arm above `guard fan.mode != .automatic`. Run: red on
    /// `shown`.
    /// **Mutation:** in `StartupReconciliation.refusalForGrant`, move the
    /// `if awaiting.contains(fan)` arm above `guard state.mode == .manual`. Run: red — the
    /// re-acquisition throws.
    @Test("A fan § 3 is keeping that reads automatic is granted, not refused")
    func aKeptFanThatReadsAutomaticIsGranted() async throws {
        let helper = Self.composed(writes: .honoured, snapshotSeesManual: false)
        try await Self.engageThenRelease(in: helper)
        #expect(
            await helper.thermalEmergency.fansAwaitingRestoreConfirmation == [0],
            "fan 0 is not owed a read-back, so this test proves nothing about the register")

        let shown = try AvailabilityFixture.availability(
            ofFanAt: 0, in: try await helper.authority.snapshot())
        #expect(shown == .available)
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
    }

    /// The set reaches the snapshot as its own field, never folded into `accountableFans`.
    ///
    /// **Mutation:** in `LeaseAuthority.activeLeaseView()`, pass
    /// `accountableFans: fansAeolusIsAccountableFor.union(awaiting)`. Run: red here — and the
    /// same mutant turns the first two tests' `shown` red with `shown → .available` while their
    /// `thrown` stays a refusal, because the gate reads `fansAeolusIsAccountableFor` and not
    /// this view. That is a screen offering control the click cannot get. The same union made
    /// in `fansAeolusIsAccountableFor` itself would exempt the fan on the gate too, and grant.
    @Test("The kept set is carried apart from the accountable set, not unioned into it")
    func theKeptSetIsNotFoldedIntoTheAccountableOne() async throws {
        let helper = Self.composed(writes: .reverted)
        try await Self.engageThenRelease(in: helper)

        let view = await helper.leases.activeLeaseView()
        #expect(view.restoresAwaitingConfirmation == [0])
        #expect(
            !view.accountableFans.contains(0),
            """
            A fan § 3 is keeping was folded into the accountable set. Both consumers exempt \
            that set from the foreign-control step, so the fan is reported available and the \
            lease is granted over a fan nothing has confirmed is automatic.
            """)
    }
}
