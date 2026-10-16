import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// § 5's terminal action keeps the ledger entry it gives a fan up under, **in the composed
/// helper** ([#346](https://github.com/blamechris/Aeolus/issues/346)).
///
/// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` hands the fan back and then
/// revokes the lease it was holding the fan for. In the composition the daemon runs, that
/// revocation reaches `HelperFanRestorer.restoreToAutomatic(fans:because:)`, which tells § 5 about
/// every fan it hands back — `manualControlReleased(fanAt:)` — while `finaliseRelease` is still
/// suspended inside the revocation. Until #346 that notification cleared the entry the terminal
/// action had just been given, logged it "resolved", and a fan the system had taken was reported to
/// the user as one it had not: `CLAUDE.md` rule 6, in the direction that hides a loss.
///
/// **Composed, because nothing smaller can see it.** Every watchdog suite runs over
/// `ReclamationMachine`, whose `RecordingFanRestorer` never calls back into the watchdog, so
/// the echo that erased the entry does not exist there. These build the graph
/// `HelperRestorerTests.composed` builds — the one `AeolusHelperMain` builds — bind it the way
/// bring-up binds it, and drive § 5's own cycle by hand. The supervisors are not started, for
/// that suite's reason.
///
/// **Each test proves the echo ran before it asserts what the echo did.** A restorer that was
/// never bound, or a revocation that found no lease, would leave every ledger assertion here
/// green for the wrong reason, so each checks that the revocation's restore reached the
/// firmware through the bound restorer: a second `restoreToAutomatic(.fan(0))`, after the
/// driver's own hand-back.
@Suite("§ 5's terminal action keeps its ledger entry, composed", .timeLimit(.minutes(1)))
struct FinaliseReleaseLedgerTests {

    /// What `SafetyLog.reclamationResolved(fan:)` says, and nothing else does.
    private static let resolved = "is no longer reported as taken from Aeolus"

    /// A composed helper whose safety log is recorded, bound, holding fan 0 under a live lease
    /// and registered with both safety actors in E3's order: lease, then engage.
    ///
    /// Not `private`, with the two helpers below it: `TerminalActionAvailabilityTests` (#355)
    /// asks what the snapshot and the grant say after this same terminal action. Its third
    /// scenario needs the snapshot's `F0Md` to move, which is `snapshotProvider`; `nil` reads the
    /// firmware's own, as `HelperRestorerTests.composed` does (#360).
    static func holding(
        afterwards: [ScriptedControlPlane.Stage] = [],
        snapshotProvider: (any SensorProvider)? = nil
    ) async throws -> (helper: HelperComposition<ScriptedControlPlane>, log: RecordedLog) {
        let log = RecordedLog()
        let helper = HelperRestorerTests.composed(
            snapshotProvider: snapshotProvider,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }),
            afterwards: afterwards)
        await helper.bindSafetyRegistries()
        #expect(
            await helper.restorer.isBound,
            "the restorer is unbound, so the echo this suite is about cannot happen")
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: lease.id)
        return (helper, log)
    }

    /// Cycles § 5 until the terminal action, which for both scenarios here is the
    /// `blindCyclesBeforeDivergence`th cycle — the registration grace for an uncommanded fan
    /// reading automatic, and the blindness threshold for one that cannot be read. Bounded, by
    /// `cycledToTheTerminalAction(_:sourceLocation:)`, so a revocation that never returns fails
    /// the test rather than hanging the run (#368).
    static func cycleToTheTerminalAction<Plane: FanControlPlane>(
        _ helper: HelperComposition<Plane>, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await cycledToTheTerminalAction(
            helper.reclamationWatchdog, sourceLocation: sourceLocation)
    }

    /// The driver's hand-back, then the revocation's restore through the bound restorer — which
    /// tells § 5 before it writes. Two restores of fan 0 is the evidence the echo ran.
    static func expectTheRevocationRestoredThroughTheRestorer(
        _ helper: HelperComposition<ScriptedControlPlane>
    ) async {
        let restores = await Self.restoresOfFanZero(on: helper.plane)
        #expect(
            restores.count == 2,
            """
            fan 0 was restored \(restores.count) time(s). The terminal action's hand-back and its \
            revocation's restore through HelperFanRestorer should each have reached the \
            firmware once, and without the second nothing here exercised the echo.
            """)
        #expect(await helper.leases.leaseCount == 0, "the terminal action revoked no lease")
    }

    static func restoresOfFanZero(
        on plane: ScriptedControlPlane
    ) async -> [ScriptedControlPlane.Attempt] {
        await plane.attempts.filter { $0 == .restoreToAutomatic(.fan(0)) }
    }

    /// The graph `HelperRestorerTests.composed` builds, over a plane it cannot take, for the
    /// scenarios that need two fans or a write moment. Every argument but the plane and the
    /// provider's fan count is that fixture's.
    ///
    /// **Its snapshot provider is `fanProvider`, which has no `F<n>Md`**, so its snapshots read
    /// every fan's mode unread while the plane answers it. Nothing over it asserts an
    /// availability — its tests read the ledger, the log and `isReclaimedBySystem` — so that is
    /// harmless here and would not be for an availability claim (#360). Moving it onto
    /// `PlaneBackedProvider`, which needs the scripted firmware beneath the wrapping plane, is
    /// [#370](https://github.com/blamechris/Aeolus/issues/370).
    static func composed<Plane: FanControlPlane>(
        over plane: Plane, fanCount: Int = 1, log: RecordedLog
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: fanCount),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }))
    }

    /// Fan 0 held, as `holding()` holds it, over `InterferingFanStateSensing` at `.restoreWrite`:
    /// the first restore that lands is the terminal action's hand-back, because nothing restored
    /// fan 0 before it.
    struct Interfered {
        let helper: HelperComposition<InterferingFanStateSensing>
        let plane: InterferingFanStateSensing
        let scripted: ScriptedControlPlane
        let holder: ConnectionID
        /// The lease fan 0 is held under, which the terminal action revokes.
        let lease: UUID
        let log: RecordedLog
    }

    static func holdingThroughInterference() async throws -> Interfered {
        let log = RecordedLog()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let plane = InterferingFanStateSensing(scripted, during: .restoreWrite)
        let helper = Self.composed(over: plane, log: log)
        await helper.bindSafetyRegistries()
        let holder = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: lease.id)
        return Interfered(
            helper: helper, plane: plane, scripted: scripted, holder: holder, lease: lease.id,
            log: log)
    }

    // MARK: - The entry is kept

    /// A fan the system took back, with nothing ever commanded on it, is still reported as
    /// reclaimed once the revocation that gave it up has run.
    ///
    /// Fan 0 reads automatic from the first cycle: `.modeReclaimed`, graced while nothing is
    /// commanded and then the terminal action with `.systemReclaimed` — no speed to re-assert.
    /// The entry is asserted on the ledger and on the field the user reads.
    ///
    /// **Mutation:** make `ReclamationWatchdog.Registry.release(fanAt:)` return `true` while the
    /// fan is being finalised — the skip `manualControlReleased(fanAt:)` guards on. Run: red on
    /// the ledger, the snapshot and the "resolved" assertions.
    @Test("A reclamation § 5 gave up on is still reported after its own revocation")
    func aSystemReclamationSurvivesTheRevocation() async throws {
        let (helper, log) = try await Self.holding()

        try await Self.cycleToTheTerminalAction(helper)

        #expect(
            log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        await Self.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(
            await helper.ledger.isReclaimed(fanAt: 0),
            """
            the system took fan 0 back and § 5 gave it up for that, but the ledger no longer \
            says so: the revocation's release notification erased the entry finaliseRelease \
            keeps.
            """)
        let snapshot = try await helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(
            fan.isReclaimedBySystem,
            "the user is told the system did not take a fan it took — CLAUDE.md rule 6")
        #expect(
            log.lines(containing: Self.resolved).isEmpty,
            "the reclamation was logged resolved by the revocation that gave the fan up")
    }

    /// A fan § 5 gave up because it could not read it keeps `.supervisorBlind` the same way.
    ///
    /// The other caller of the terminal action, and the same echo: the lease is taken while the
    /// firmware answers, then every read fails, and the blindness threshold gives the fan up.
    ///
    /// **Mutation:** as above. Run: red on the ledger and the "resolved" assertions.
    @Test("A fan given up for blindness is still recorded so after its own revocation")
    func aBlindEpisodeSurvivesTheRevocation() async throws {
        let (helper, log) = try await Self.holding(afterwards: [.blind()])
        await helper.plane.advance()

        try await Self.cycleToTheTerminalAction(helper)

        #expect(
            log.lines(containing: "because the helper cannot read its state").count == 1,
            "§ 5 never gave the blind fan up, so nothing here was tested")
        await Self.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(
            await helper.ledger.isSupervisorBlind(fanAt: 0),
            "the record that § 5 gave fan 0 up blind was erased by the revocation it ran")
        #expect(await helper.ledger.isReclaimed(fanAt: 0) == false)
        #expect(
            log.lines(containing: Self.resolved).isEmpty,
            "the blind episode was logged resolved by the revocation that gave the fan up")
    }

    /// The entry is kept through the **whole** terminal action, not only its revocation.
    ///
    /// The holder's connection dies while § 5's own hand-back is on the wire. The lease core
    /// drops the lease and restores through `HelperFanRestorer`, which sends § 5 the same
    /// notice the revocation would have — about a fan § 5 has already judged reclaimed and is
    /// already giving up. The revocation then finds no lease. The guard has to be open by then,
    /// so it is opened before the hand-back's suspension rather than around the revocation.
    ///
    /// **Mutation:** move the `registry.beginFinalising(fanAt:for:)` guard and its `defer` in
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` to just above
    /// `leases.revokeLease(id:forFan:because:)`. Run: red on the ledger and the "resolved"
    /// assertions.
    @Test("A lease ending during the terminal action's hand-back does not erase its entry")
    func aTeardownDuringTheHandBackKeepsTheEntry() async throws {
        let held = try await Self.holdingThroughInterference()
        let leases = held.helper.leases
        let holder = held.holder
        await held.plane.interfere { await leases.connectionDidInvalidate(holder) }

        try await Self.cycleToTheTerminalAction(held.helper)

        #expect(await held.plane.didFire, "the connection never died inside the hand-back")
        #expect(
            held.log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        #expect(
            await Self.restoresOfFanZero(on: held.scripted).count == 2,
            "the hand-back, then the teardown's restore through the restorer, and nothing else")
        #expect(
            await held.helper.ledger.isReclaimed(fanAt: 0),
            """
            a lease ending during § 5's hand-back erased the reclamation § 5 was giving the fan \
            up for: the guard opened too late.
            """)
        #expect(
            held.log.lines(containing: Self.resolved).isEmpty,
            "the reclamation was logged resolved by a teardown racing the terminal action")
    }

    // MARK: - And it is not frozen

    /// The entry is kept through the terminal action's own revocation **and no longer**: an
    /// ordinary lease ending afterwards clears it, as `manualControlReleased(fanAt:)` always has
    /// — a fan Aeolus stopped asking for is not a fan the system took.
    ///
    /// The guard the fix added must not outlive the call it guards. A window left open would
    /// keep the mark for the life of the process through every later release, which is rule 6
    /// in the other direction: a fan reported lost long after something else has had it.
    ///
    /// § 3 is cycled before the second grant so its read-back confirms the terminal action's
    /// hand-back, which is what the grant's foreign-control step waits for (#303).
    ///
    /// **Mutation:** delete `defer { registry.endFinalising(fanAt: index) }` from
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)`. Run: red on the ledger and
    /// the "resolved" assertions.
    @Test("A later, ordinary lease release still clears the kept entry")
    func anOrdinaryReleaseAfterwardsStillClearsTheEntry() async throws {
        let (helper, log) = try await Self.holding()
        try await Self.cycleToTheTerminalAction(helper)
        await Self.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "the setup kept no entry to clear")
        await helper.thermalEmergency.cycle()

        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await helper.leases.releaseLease(id: lease.id, from: connection)

        #expect(
            await helper.ledger.causes.isEmpty,
            """
            an ordinary lease release after the terminal action left fan 0 reported as \
            reclaimed: the terminal action's guard outlived the call it guards.
            """)
        #expect(log.lines(containing: Self.resolved).count == 1)
    }

    /// The guard is **per fan**: the revocation's release notice still clears a mark on any
    /// other fan the revoked lease covered.
    ///
    /// Fan 1 carries a mark kept by an earlier terminal action. A new lease covers both fans and
    /// only fan 0 is engaged, so fan 1 is in no registry and `finaliseRelease`'s sibling loop never
    /// sees it. When fan 0 is given up, the revocation hands fan 1 back as well, and that release
    /// notice is the only thing that clears fan 1's mark: a fan Aeolus stopped asking for is not a
    /// fan the system took.
    ///
    /// **Mutation (M4):** replace `return finalising[index] == nil` with
    /// `return finalising.isEmpty` in `ReclamationWatchdog.Registry.release(fanAt:)`. Run: red
    /// on fan 1's mark and its "resolved" line.
    @Test("The terminal action's revocation still clears another fan's kept mark")
    func anotherFansMarkIsClearedByTheRevocation() async throws {
        let log = RecordedLog()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400), 1: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let helper = Self.composed(over: scripted, fanCount: 2, log: log)
        await helper.bindSafetyRegistries()
        let first = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 1, in: helper, under: first.id)
        try await Self.cycleToTheTerminalAction(helper)
        #expect(await helper.ledger.isReclaimed(fanAt: 1), "the setup kept no mark on fan 1")
        await helper.thermalEmergency.cycle()

        let second = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper, under: second.id)
        try await Self.cycleToTheTerminalAction(helper)

        #expect(log.lines(containing: "no speed to re-assert").count == 2)
        #expect(
            await scripted.attempts.filter { $0 == .restoreToAutomatic(.fan(1)) }.count == 3,
            "fan 1's second revocation never reached the restorer, so nothing here was tested")
        #expect(await helper.ledger.isReclaimed(fanAt: 0), "fan 0's own mark was not kept")
        #expect(
            await helper.ledger.isReclaimed(fanAt: 1) == false,
            """
            fan 1 was handed back by a revocation over a lease nothing engaged it under, and is \
            still reported as taken by the system: the guard is skipping every fan's clear.
            """)
        #expect(log.lines(containing: "Fan 1 \(Self.resolved)").count == 1)
    }

    /// A registration under the lease the terminal action is giving up is **refused, and the
    /// mark is kept**.
    ///
    /// The holder registers fan 0 again during § 5's hand-back, under the lease § 5 has not
    /// revoked yet. **This is the deliberate reversal of #346's pinning**, decided in #361. #346
    /// pinned that such an engagement clears the mark. The reason to reverse it is `CLAUDE.md`
    /// rule 6 and consistency with C3, not identity: the same `finaliseRelease` call revoked that
    /// lease before identity too, so its restore has always undone the engagement and the record
    /// has always been dropped after the hand-back, and clearing the mark has always told the
    /// user the system no longer holds a fan it did reclaim. C3 is that outcome by another route,
    /// and this test is the same rule. The refusal is A6's engagement failure, so `apply` hands
    /// the fan back too, which matches the revocation.
    ///
    /// **Mutation:** drop `givenUp[index] != lease` from the refusal in
    /// `ReclamationWatchdog.Registry.register(_:fanAt:live:since:)`. Run: red on the refusal. The
    /// ledger, the snapshot and the "resolved" line stay green since #366: the registration lands
    /// mid-episode, and an accepted one there leaves the mark to the episode.
    @Test("A registration under the lease being given up is refused, and the mark is kept")
    func aSameLeaseRegistrationDuringTheHandBackIsRefusedAndKeepsTheMark() async throws {
        let held = try await Self.holdingThroughInterference()
        let permit = try commandableFan(0, declaring: .held(at: 2_400))
        let watchdog = held.helper.reclamationWatchdog
        let leases = held.helper.leases
        let lease = held.lease
        let probe = LeaseProbe()
        await held.plane.interfere {
            let live = await leases.hasLiveLease(id: lease, coveringFan: 0)
            await probe.record(live)
            await #expect(throws: EngagementRefusal.leaseNotLive(fan: 0)) {
                try await watchdog.manualControlEngaged(permit, under: lease)
            }
        }

        try await Self.cycleToTheTerminalAction(held.helper)

        #expect(await held.plane.didFire, "nothing registered fan 0 inside the hand-back")
        #expect(
            await probe.liveAtEngagement == true,
            "the lease had already ended, so this was not the holder re-registering")
        #expect(held.log.lines(containing: "no speed to re-assert").count == 1)
        #expect(await held.helper.leases.leaseCount == 0, "the terminal action revoked no lease")
        #expect(
            await held.helper.ledger.isReclaimed(fanAt: 0),
            "a registration under the lease being given up erased the terminal action's mark")
        let snapshot = try await held.helper.authority.snapshot()
        let fan = try #require(snapshot.fans.first { $0.index == 0 })
        #expect(fan.isReclaimedBySystem, "the user is told the system no longer holds the fan")
        #expect(held.log.lines(containing: Self.resolved).isEmpty)
        #expect(await held.helper.reclamationWatchdog.fansUnderManualControl.isEmpty)
    }
}

/// What the lease table answered inside an interference effect, so a scenario can prove the
/// lease it is about was still live at that instant.
private actor LeaseProbe {
    private(set) var liveAtEngagement: Bool?

    func record(_ live: Bool) { liveAtEngagement = live }
}
