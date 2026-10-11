import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// § 5's terminal action keeps the ledger entry it gives a fan up under, **in the composed
/// helper** ([#346](https://github.com/blamechris/Aeolus/issues/346)).
///
/// `ReclamationWatchdog.finaliseRelease(fanAt:because:)` hands the fan back and then revokes
/// every lease. In the composition the daemon runs, that revocation reaches
/// `HelperFanRestorer.restoreToAutomatic(fans:because:)`, which tells § 5 about every fan it
/// hands back — `manualControlReleased(fanAt:)` — while `finaliseRelease` is still suspended
/// inside the revocation. Until #346 that notification cleared the entry the terminal action
/// had just been given, logged it "resolved", and a fan the system had taken was reported to
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
    private static func holding(
        afterwards: [ScriptedControlPlane.Stage] = []
    ) async throws -> (helper: HelperComposition<ScriptedControlPlane>, log: RecordedLog) {
        let log = RecordedLog()
        let helper = HelperRestorerTests.composed(
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }),
            afterwards: afterwards)
        await helper.bindSafetyRegistries()
        #expect(
            await helper.restorer.isBound,
            "the restorer is unbound, so the echo this suite is about cannot happen")
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        return (helper, log)
    }

    /// Cycles § 5 until the terminal action, which for both scenarios here is the
    /// `blindCyclesBeforeDivergence`th cycle — the registration grace for an uncommanded fan
    /// reading automatic, and the blindness threshold for one that cannot be read.
    private static func cycleToTheTerminalAction<Plane: FanControlPlane>(
        _ helper: HelperComposition<Plane>
    ) async {
        for _ in 1...ReclamationLimits.blindCyclesBeforeDivergence {
            await helper.reclamationWatchdog.cycle()
        }
    }

    /// The driver's hand-back, then the revocation's restore through the bound restorer — which
    /// tells § 5 before it writes. Two restores of fan 0 is the evidence the echo ran.
    private static func expectTheRevocationRestoredThroughTheRestorer(
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

    private static func restoresOfFanZero(
        on plane: ScriptedControlPlane
    ) async -> [ScriptedControlPlane.Attempt] {
        await plane.attempts.filter { $0 == .restoreToAutomatic(.fan(0)) }
    }

    // MARK: - The entry is kept

    /// A fan the system took back, with nothing ever commanded on it, is still reported as
    /// reclaimed once the revocation that gave it up has run.
    ///
    /// Fan 0 reads automatic from the first cycle: `.modeReclaimed`, graced while nothing is
    /// commanded and then the terminal action with `.systemReclaimed` — no speed to re-assert.
    /// The entry is asserted on the ledger and on the field the user reads.
    ///
    /// **Mutation:** delete `guard !finalising.contains(index) else { return }` from
    /// `ReclamationWatchdog.manualControlReleased(fanAt:)`. Run: red on the ledger, the
    /// snapshot and the "resolved" assertions.
    @Test("A reclamation § 5 gave up on is still reported after its own revocation")
    func aSystemReclamationSurvivesTheRevocation() async throws {
        let (helper, log) = try await Self.holding()

        await Self.cycleToTheTerminalAction(helper)

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

        await Self.cycleToTheTerminalAction(helper)

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
    /// Composed over `InterferingFanStateSensing`, whose `.restoreWrite` moment is the first
    /// restore that lands — the hand-back's, because nothing restored fan 0 before it.
    ///
    /// **Mutation:** move `finalising.insert(index)` and its `defer` in
    /// `ReclamationWatchdog.finaliseRelease(fanAt:because:)` to just above
    /// `leases.revokeEveryLease(because:)`. Run: red on the ledger and the "resolved" assertions.
    @Test("A lease ending during the terminal action's hand-back does not erase its entry")
    func aTeardownDuringTheHandBackKeepsTheEntry() async throws {
        let log = RecordedLog()
        let scripted = ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
        let plane = InterferingFanStateSensing(scripted, during: .restoreWrite)
        let helper = HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            roundTrips: idleRoundTrips(), watchdogTicks: ManualWatchdogTicks(),
            log: HelperRestorerTests.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: SafetyLog(recording: { [log] in log.append($0, $1) }))
        await helper.bindSafetyRegistries()
        let holder = ConnectionID()
        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)
        try await HelperRestorerTests.engage(fan: 0, in: helper)
        let leases = helper.leases
        await plane.interfere { await leases.connectionDidInvalidate(holder) }

        await Self.cycleToTheTerminalAction(helper)

        #expect(await plane.didFire, "the connection never died inside the hand-back")
        #expect(
            log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        #expect(
            await Self.restoresOfFanZero(on: scripted).count == 2,
            "the hand-back, then the teardown's restore through the restorer, and nothing else")
        #expect(
            await helper.ledger.isReclaimed(fanAt: 0),
            """
            a lease ending during § 5's hand-back erased the reclamation § 5 was giving the fan \
            up for: the guard opened too late.
            """)
        #expect(
            log.lines(containing: Self.resolved).isEmpty,
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
    /// **Mutation:** delete `defer { finalising.remove(index) }` from
    /// `ReclamationWatchdog.finaliseRelease(fanAt:because:)`. Run: red on the ledger and the
    /// "resolved" assertions.
    @Test("A later, ordinary lease release still clears the kept entry")
    func anOrdinaryReleaseAfterwardsStillClearsTheEntry() async throws {
        let (helper, log) = try await Self.holding()
        await Self.cycleToTheTerminalAction(helper)
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
}
