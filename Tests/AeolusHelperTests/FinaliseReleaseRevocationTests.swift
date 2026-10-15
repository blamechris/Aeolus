import FanKit
import Testing

@testable import AeolusHelper

/// #353: the terminal action revokes the lease it was holding the fan for, in the composed helper.
/// Kept out of `FinaliseReleaseLedgerTests.swift`, which is at SwiftLint's `file_length` and its
/// suite at `type_body_length`, as an extension of the same suite: it drives the same composed
/// interference fixture, whose helpers are internal for the purpose rather than copied.
extension FinaliseReleaseLedgerTests {

    /// The terminal action revokes the lease it was holding the fan for, and no other (#353).
    ///
    /// Inside § 5's hand-back the holder releases its lease — the lease core restores through
    /// the bound `HelperFanRestorer`, which tells § 5 — and a new client is granted fan 0. The
    /// terminal action used to revoke every lease, so the new client lost a lease it had just
    /// been granted, told the system had taken a fan it never held. Composed, because the
    /// release notice and its ordering are the shipping restorer's.
    ///
    /// `LeaseLog` has no recording sink, so the revocation that must not happen is observed
    /// where it would land: the table, and a third restore of fan 0 through the restorer.
    ///
    /// **Mutation:** replace the `revokeLease(id:because:)` guard in
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` with
    /// `await leases.revokeEveryLease(because: cause)`. Run: red on the new lease, the count,
    /// the restores and the notice.
    @Test("The terminal action revokes only the lease it held the fan for")
    func theTerminalActionRevokesOnlyTheLeaseItHeldTheFanFor() async throws {
        let held = try await Self.holdingThroughInterference()
        let leases = held.helper.leases
        let holder = held.holder
        let lease = held.lease
        let granted = GrantedLeases()
        await held.plane.interfere {
            do {
                try await leases.releaseLease(id: lease, from: holder)
                let next = try await leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
                await granted.record(next.id)
            } catch {
                Issue.record("the release and re-grant inside the hand-back failed: \(error)")
            }
        }

        await Self.cycleToTheTerminalAction(held.helper)

        #expect(await held.plane.didFire, "nothing was released inside the hand-back")
        #expect(
            held.log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        let next = try #require(await granted.ids.first, "the re-grant never happened")
        #expect(
            await leases.activeLease()?.id == next,
            "the terminal action revoked a lease granted after the one it held the fan for")
        #expect(await leases.leaseCount == 1)
        #expect(
            await Self.restoresOfFanZero(on: held.scripted).count == 2,
            "the hand-back and the release's restore, and no revocation's restore after them")
        #expect(held.log.lines(containing: "had already ended").count == 1)
    }

    /// **A refused registration resolves nothing** (#357's review, C2). Fan 0's episode reaches
    /// § 5's terminal action as `.systemReclaimed`, which revokes its lease and keeps the mark
    /// (#346). A registration under that lease then arrives late — an `apply` whose lease ended
    /// before it registered. It is refused, and it must not clear the mark first: nothing took
    /// the fan off automatic control, so the user is still owed `isReclaimedBySystem`.
    ///
    /// **Mutation:** in `manualControlEngaged(_:under:)`, move the `ledger.clearReclaimed` block
    /// above the refusal's `guard`. Run: red on the ledger, the snapshot and the "resolved" line.
    @Test("A refused late registration keeps the terminal action's reclamation mark")
    func aRefusedLateRegistrationKeepsTheMark() async throws {
        let (helper, log) = try await Self.holding()
        let ended = try #require(await helper.leases.activeLease()).id
        await Self.cycleToTheTerminalAction(helper)
        await Self.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the terminal action kept no mark")

        await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
            try await helper.reclamationWatchdog.manualControlEngaged(
                try commandableFan(0, declaring: .held(at: 2_400)), under: ended)
        }

        #expect(
            await helper.ledger.isReclaimed(fanAt: 0),
            "a registration § 5 refused erased the reclamation the terminal action kept")
        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(fan.isReclaimedBySystem, "the user is told the system no longer holds the fan")
        #expect(log.lines(containing: "is no longer reported as taken from Aeolus").isEmpty)
        #expect(await helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
    }

    /// **A lease that lapses during the terminal action keeps the mark through its expiry**
    /// (#361's panel). Fan 0's episode reaches § 5's terminal action, and the lease passes its
    /// deadline during the hand-back, unswept. `revokeLease` used to decline a lapsed lease and
    /// leave it to the TTL sweep; the sweep then ended it after `finalising` had closed, and its
    /// release notice erased the `.systemReclaimed` mark — #346's defect again. Main never had
    /// it, because `revokeEveryLease`'s `removeAll()` took lapsed entries too. A lapsed lease is
    /// now ended inside the call, as `.leaseExpired`, so the notice lands while `finalising`
    /// holds the fan; `LeaseRevocationTests.revokeLeaseEndsALapsedLeaseAsExpired` holds the cause.
    ///
    /// **Mutation:** decline a lapsed lease in `revokeLease(id:because:)` again — `guard let
    /// entry = table.entry(id: id), !entry.hasLapsed(asOf: clock.now) else { return .gone }`.
    /// Run: red on the ledger and the snapshot after the sweep.
    @Test(
        "A lease lapsing during the hand-back keeps the terminal action's mark through its expiry")
    func aLeaseLapsingDuringTheHandBackKeepsTheMarkThroughItsExpiry() async throws {
        let log = RecordedLog()
        let clock = TestClock()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let plane = InterferingFanStateSensing(scripted, during: .restoreWrite)
        let helper = HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            clock: clock,
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }))
        await helper.bindSafetyRegistries()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: lease.id)
        await plane.interfere { clock.advance(by: .seconds(Lease.defaultTimeToLive + 1)) }

        await Self.cycleToTheTerminalAction(helper)

        #expect(await plane.didFire, "the lease never lapsed inside the hand-back")
        #expect(log.lines(containing: "no speed to re-assert").count == 1)
        #expect(
            log.lines(containing: "had already ended").count == 1, "the lapsed lease was revoked")
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the terminal action kept no mark")

        await helper.leases.expireLapsedLeases()

        #expect(await helper.leases.leaseCount == 0, "the lapsed lease was never ended")
        #expect(
            await helper.ledger.isReclaimed(fanAt: 0),
            "the lapsed lease's ending erased the mark the terminal action kept")
        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(fan.isReclaimedBySystem, "the user is told the system no longer holds the fan")
        #expect(log.lines(containing: "is no longer reported as taken from Aeolus").isEmpty)
    }
}
