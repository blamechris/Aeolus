import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// K4 (#440): a restorer lent to the lease core hands back inside the bracket every teardown
/// uses, `restore(_:because:through:)`.
///
/// § 3's revocation is the one teardown that does not restore through the lease core's own
/// `restorer`: it borrows § 3's handback for the call. What that must not cost is the handback
/// ledger. `releasing` is held from before the restore until it returns, so a grant arriving
/// meanwhile is refused `.releaseInProgress`; a refusal lands in `restoreAbandoned`, so the next
/// grant over the fan is refused durably. Both are what `handback-ledger.md` argues for every path,
/// and a lent restorer called outside the bracket would keep neither while every restore still
/// reached the firmware.
///
/// And it keeps the notices: § 3's own revocation, driven through `cycle()`, tells § 5 about the
/// fans it hands back, because the handback lends its bound to `HelperFanRestorer.handBack`.
@Suite("A lent handback runs inside the handback ledger's bracket", .timeLimit(.minutes(1)))
struct HandbackLendingBracketTests {

    /// A grant arriving while the lent restorer is still handing back is refused
    /// `.releaseInProgress`, the fan is in `releasing` throughout, and the lent restorer — not the
    /// lease core's own — is the one asked, under § 3's label.
    ///
    /// The lease core's own restorer signals `entered` too, so a verb that restored through it
    /// instead of the one it was lent fails at the expectations below at once, rather than parking
    /// on a signal nothing sends until the time limit.
    ///
    /// **Mutation (K4):** in `revokeEveryLease(handingBackThrough:)`, call
    /// `handback.restoreToAutomatic(fans: fans, because: cause)` directly instead of
    /// `restore(fans, because: cause, through: handback)`. Run: red — the fan is not mid-handback
    /// and the grant succeeds.
    /// **Mutation (K2b):** the verb lends `restorer` instead of `handback`. Run: red at once — the
    /// fan has left `releasing`, the grant succeeds, and the wrong restorer was asked.
    @Test("A grant during a lent handback is refused, with the fan mid-handback throughout")
    func aGrantDuringALentHandbackIsRefused() async throws {
        let entered = AsyncSignal()
        let standing = RecordingFanRestorer(entered: entered)
        let leases = LeaseFixture.authority(restorer: standing)
        _ = try await leases.acquireLease(LeaseFixture.request(fans: [0]), from: ConnectionID())

        let release = AsyncSignal()
        let lent = RecordingFanRestorer(entered: entered, release: release)
        let revocation = Task { await leases.revokeEveryLease(handingBackThrough: lent) }
        try await entered.wait()

        #expect(await leases.fansMidHandback == [0], "the lent handback is outside `releasing`")
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        ) {
            _ = try await leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        await release.signal()
        await revocation.value

        #expect(await leases.fansMidHandback.isEmpty, "the fan never left `releasing`")
        #expect(
            await lent.restores
                == [RecordingFanRestorer.Restore(fans: [0], cause: .thermalEmergencyRevocation)])
        #expect(await standing.restores.isEmpty, "the lease core's own restorer was asked")
    }

    /// § 3's own route, end to end: a fan level 6 engaged is in § 5's registry, § 3 fires over it,
    /// and its revocation — through the handback, in the lane — tells § 5 to stop watching it.
    /// Nothing else in the firing tells § 5: the bridge does not, and § 5 is not cycled here.
    ///
    /// **Mutation:** at `ThermalEmergency`'s three revocations, lend a hand-built bound,
    /// `BoundedFanRestorer(attempting: KeystoneRestoreAttempt(writer: writer))`, instead of
    /// `handback`. Run: red here — the restores still reach the lane, and § 5 is never told.
    @Test("§ 3's firing revocation tells § 5 about the fans it hands back")
    func sectionThreesFiringTellsSectionFive() async throws {
        let firmware = ScriptedControlPlane(
            fans: [0: .automatic(at: 1_800)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures), .at(96)])
        let helper = HelperComposition(
            plane: firmware,
            snapshotProvider: PlaneBackedProvider(over: firmware, fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: TestClock(),
            log: HelperRestorerTests.helperLog, leaseLog: LeaseFixture.log,
            safetyLog: HelperRestorerTests.safetyLog,
            teardown: TeardownSeams(
                sources: RecordingSignalSources(), terminate: TeardownJournal().terminate))
        await helper.bindSafetyRegistries()
        let holder = ConnectionID()
        let lease = try await helper.authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        try await helper.authority.apply(
            [FanSetting(fanIndex: 0, control: .fixed(rpm: 2_400))], leaseID: lease.id, from: holder)
        #expect(await helper.reclamationWatchdog.fansUnderManualControl == [0])

        await firmware.advance()
        await helper.thermalEmergency.cycle()

        #expect(await helper.latch.isActive, "the cycle did not fire")
        #expect(await helper.leases.leaseCount == 0, "the firing did not revoke the lease")
        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            "§ 5 still watches a fan § 3's revocation handed back")
    }

    /// § 3's own handback, as the composition gave it to § 3, refused by the firmware on every
    /// attempt: the fan lands in the lease core's abandoned register, and the next grant over it
    /// is refused `.restoreToAutomaticFailed`.
    ///
    /// **Mutation (K4):** the same direct call. Run: red — nothing is recorded abandoned, and the
    /// grant succeeds.
    @Test("A refused lent handback is recorded abandoned, and refuses the next grant durably")
    func aRefusedLentHandbackIsRecordedAbandoned() async throws {
        let helper = HelperRestorerTests.composed(
            writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bindSafetyRegistries()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        await helper.leases.revokeEveryLease(
            handingBackThrough: try HelperRestorerTests.sectionThreesHandback(in: helper))

        #expect(await helper.leases.fansWithAbandonedHandbacks == [0])
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }
}
