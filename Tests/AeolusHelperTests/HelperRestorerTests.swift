import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// The production `FanRestoring`, driven through the **composed** helper.
///
/// Every test here builds `HelperComposition` — the same type `AeolusHelperMain` builds —
/// over `ScriptedControlPlane` and a canned provider, binds it the way the daemon's bring-up
/// binds it, and then acquires and tears down a real lease through the real `LeaseAuthority`.
/// Nothing is paraphrased: the restorer under test is the one the daemon runs, reached the
/// way the daemon reaches it.
///
/// That matters more here than usual, because what #163 added is *wiring*. A test that
/// constructed `HelperFanRestorer` directly and called `restoreToAutomatic(fans:because:)`
/// would pass while `LeaseAuthority` was handed a different restorer, or none, which is
/// precisely the class of defect this issue exists to end — `ThermalEmergency`,
/// `ReclamationWatchdog` and `SMCFanControlPlane` were all fully tested and constructed only
/// under `Tests/`.
///
/// **The supervisors are deliberately not started in most of these.**
/// `bindSafetyRegistries()` is what the daemon's `bringUp()` calls first, and it is all the
/// registry tests need; starting three 1 Hz loops over the same scripted firmware would let
/// § 5's own cycle move the registries those tests assert on. `bringUpBindsTheRegistries`
/// covers the daemon's path, which is the one that has to call the binding at all.
@Suite("The helper's fan restorer, composed", .timeLimit(.minutes(1)))
struct HelperRestorerTests {

    static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Composition")
    static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    /// One composed helper over the scripted firmware, with one fan spinning at a plausible
    /// speed under Apple's own thermal management.
    ///
    /// `writes` is the firmware's answer to the keystone mode write, which is the whole of
    /// the difference between a fan that came back and a fan that was abandoned.
    /// `clock` and `snapshotProvider` are defaulted to the production shapes and are
    /// overridden by exactly one caller between them —
    /// `SupervisedFanAuthorityTests.theLeaseIsReadAfterTheMachineNotBefore`, which needs the
    /// TTL to lapse *inside* the snapshot's read. They are parameters here rather than a
    /// second fixture so that every test in both suites composes the identical graph: a
    /// paraphrased composition is the defect #163 exists to end, and it would be a strange
    /// place to reintroduce it.
    ///
    /// **Fan 0 starts automatic, and it used to start `.held(at: 2_400)`.** That fixture
    /// meant "the firmware reports fan 0 in manual", which since #164 is a statement with
    /// consequences: startup reconciliation restores such a fan, and `acquireLease` refuses
    /// one it did not put there as `.foreignManualControl`. Every test here acquires a lease
    /// *after* calling `engage(fan:in:)`, which is the reverse of the real order — E3
    /// acquires first and engages second — so a manual fan in the fixture would be
    /// indistinguishable from another program holding it, and correctly refused. Starting
    /// automatic keeps the fixture's meaning ("Aeolus is about to hold this fan") rather
    /// than accidentally asserting the opposite. The target and actual RPM stay where they
    /// were: `F<n>Tg` carries whatever Apple's thermal manager last asked for.
    static func composed(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured,
        clock: some MonotonicClock = SystemMonotonicClock(),
        snapshotProvider: some SensorProvider = fanProvider(fanCount: 1)
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .automatic(at: 2_400)],
                stages: [
                    .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                ]),
            snapshotProvider: snapshotProvider,
            criticalSensors: .mac16x5,
            clock: clock,
            log: helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog,
            // `bringUpBindsTheRegistries` calls `bringUp()`, which installs E5.4d's signal
            // teardown. The shipping source would `SIG_IGN` this process's `SIGTERM`,
            // `SIGINT` and `SIGHUP` and then `exit(0)` the test runner on the next one.
            teardown: TeardownSeams(sources: RecordingSignalSources()))
    }

    /// Puts fan 0 into both registries, the way E3's control plane will once it exists.
    ///
    /// Both calls take a `CommandableFan`, so this cannot register a fan whose declared
    /// bounds would have failed #37's gate — see `ReclamationWatchdog.manualControlEngaged(_:)`
    /// for why the parameter is the permit rather than an index.
    static func engage<Plane: FanControlPlane>(
        fan index: Int, in helper: HelperComposition<Plane>
    ) async throws {
        let permit = try commandableFan(index, declaring: .held(at: 2_400))
        await helper.reclamationWatchdog.manualControlEngaged(permit)
        await helper.thermalEmergency.manualControlEngaged(permit)
    }

    /// Acquires a lease over fan 0 and releases it, which is the ordinary teardown path.
    private static func acquireAndRelease<Plane: FanControlPlane>(
        in helper: HelperComposition<Plane>
    ) async throws {
        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        try await helper.leases.releaseLease(id: lease.id, from: connection)
    }

    // MARK: - Bring-up

    /// The daemon's bring-up binds the registries, and starts all three loops.
    ///
    /// The binding is first in `bringUp()` because every step after it can cause a restore:
    /// a supervisor cycle can revoke a lease, and an advertised Mach service can be handed
    /// one to release. This asserts the *outcome* of that ordering; the ordering relative to
    /// `listener.resume()` is
    /// `HelperCompositionTests.theServiceIsAdvertisedOnlyAfterBringUp`, which has to be a
    /// source tripwire because `main()` never returns.
    ///
    /// The lease expiry supervisor is in the list although #163's brief named only the two
    /// safety supervisors — see `HelperComposition.leaseExpirySupervisor` for why § 1's own
    /// loop is not a thing to leave for later.
    ///
    /// **Mutation:** delete `await bindSafetyRegistries()` from `HelperComposition.bringUp()`.
    /// Run: red. **Mutation:** delete any one `start()`. Run: red.
    @Test("Bring-up binds the safety registries and starts every supervisor")
    func bringUpBindsTheRegistries() async throws {
        let helper = Self.composed()
        #expect(
            await helper.restorer.isBound == false,
            "the restorer cannot be bound before bring-up: the registries do not exist yet")

        await helper.bringUp()

        #expect(
            await helper.restorer.isBound,
            """
            a restore can now reach the firmware without either safety registry being told, \
            and § 5's next cycle reads the result as a system reclamation.
            """)
        #expect(await helper.thermalSupervisor.isRunning, "§ 3 is not running")
        #expect(await helper.reclamationSupervisor.isRunning, "§ 5 is not running")
        #expect(await helper.leaseExpirySupervisor.isRunning, "§ 1's TTL loop is not running")

        await helper.shutDown()

        #expect(await helper.thermalSupervisor.isRunning == false)
        #expect(await helper.reclamationSupervisor.isRunning == false)
        #expect(await helper.leaseExpirySupervisor.isRunning == false)
    }

    // MARK: - One test per registry

    /// § 5 stops watching a fan whose lease ended.
    ///
    /// Without this, the watchdog's next cycle reads a fan that has just gone back to
    /// automatic, calls it `.modeReclaimed`, restores it again, **revokes every lease on the
    /// machine** and writes a `.fault` line blaming the operating system for a handback
    /// Aeolus asked for.
    ///
    /// **Mutation:** delete the `reclamationWatchdog?.manualControlReleased(fanAt:)` loop in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red.
    @Test("Releasing a lease stops the reclamation watchdog watching its fan")
    func theWatchdogIsToldWhenALeaseEnds() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        try await Self.engage(fan: 0, in: helper)
        #expect(await helper.reclamationWatchdog.fansUnderManualControl == [0])

        try await Self.acquireAndRelease(in: helper)

        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            """
            § 5 is still watching a fan that has gone back to automatic control. Its next \
            cycle reads that as a system reclamation.
            """)
    }

    /// § 3 keeps a fan whose handback the firmware accepted until its **own** cycle reads it
    /// automatic, and then stops listing it (#295).
    ///
    /// Two halves, and each is a different mutation. Straight after the release the fan is
    /// still registered and owed a read-back: accepted is not automatic (#291), so the
    /// restorer only marks it. One sighted § 3 cycle with the latch clear then reads fan 0
    /// automatic — the scripted firmware honoured the restore — and forgets it. The cycle is
    /// driven by hand because the supervisors are not started here (see the suite's note).
    ///
    /// **Mutation:** in `HelperFanRestorer.restoreToAutomatic(fans:because:)`, replace
    /// `thermalEmergency?.handbackAccepted(fanAt: fan)` with a call that drops the entry —
    /// the pre-#295 `manualControlReleased` — and the first expectation goes red.
    /// **Mutation:** delete `forget(fanAt: fan)` from the `.automatic` case of
    /// `ThermalEmergency.readBackAcceptedHandbacks()`, and the post-cycle expectation goes
    /// red: the fan never clears.
    @Test("Releasing a lease leaves its fan owed a read-back, and § 3's cycle clears it")
    func theThermalRegistryIsToldWhenALeaseEnds() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        try await Self.engage(fan: 0, in: helper)
        #expect(await helper.thermalEmergency.fansUnderManualControl == [0])

        try await Self.acquireAndRelease(in: helper)

        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack == [0])
        #expect(
            await helper.thermalEmergency.fansUnderManualControl == [0],
            """
            § 3 forgot fan 0 on the strength of an accepted write, before anything read it \
            back. Accepted is not automatic: a firmware that took the write and left the fan \
            manual now has a fan no emergency will bridge.
            """)

        await helper.thermalEmergency.cycle()

        #expect(
            await helper.thermalEmergency.fansUnderManualControl.isEmpty,
            "§ 3 still lists a fan its own read-back found on Apple's thermal management")
        #expect(await helper.thermalEmergency.fansOwedHandbackReadBack.isEmpty)
    }

    // MARK: - The asymmetry

    /// A fan the firmware refused to hand back **stays** in § 3's registry, and leaves § 5's.
    ///
    /// This is the whole reason the two deregistrations are not one loop. An abandoned fan is
    /// still off automatic control, possibly pinned low, so it is precisely the fan a thermal
    /// emergency must be able to bridge to maximum — while § 5, whose budget is spent and
    /// whose own `finaliseRelease(fanAt:because:)` drops a fan *"regardless"*, has nothing
    /// left to do about it.
    ///
    /// **And it is not even marked owed a read-back** (#295). Since #295 the restorer no longer
    /// removes anything from § 3, so "stays registered" alone could no longer fail: the
    /// discriminating half is the owed set. A refused fan owes no read — nothing was accepted
    /// — and marking it would let a later automatic read forget a fan whose refusal is the
    /// newer fact about it.
    ///
    /// **Mutation:** replace `fans.subtracting(abandoned)` with `fans` in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red on the owed set.
    @Test("A fan whose handback the firmware refused stays in the thermal registry")
    func anAbandonedFanStaysWhereItCanStillBeBridged() async throws {
        let helper = Self.composed(writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bindSafetyRegistries()
        try await Self.engage(fan: 0, in: helper)

        try await Self.acquireAndRelease(in: helper)

        #expect(
            await helper.thermalEmergency.fansUnderManualControl == [0],
            """
            § 3 has forgotten a fan that is still off automatic control, so a machine going \
            over its ceiling would not bridge it to maximum.
            """)
        #expect(
            await helper.thermalEmergency.fansOwedHandbackReadBack.isEmpty,
            "a fan whose handback the firmware refused was marked owed a read-back")
        #expect(
            await helper.reclamationWatchdog.fansUnderManualControl.isEmpty,
            "§ 5 kept a fan whose handback was given up on")
    }

    /// The refusal is durable, which is what makes the abandoned set worth returning.
    ///
    /// `LeaseAuthority.restoreAbandoned` is append-only, so the next `acquireLease` over that
    /// fan is refused `.restoreToAutomaticFailed` rather than being told to retry a window
    /// that has closed. Asserted here rather than in the lease suite because this is the
    /// first composition in `Sources/` that can actually produce an abandoned fan.
    ///
    /// **Mutation:** return `[]` from `HelperFanRestorer.restoreToAutomatic(fans:because:)`.
    /// Run: red.
    @Test("A fan the firmware would not hand back is refused a further lease")
    func anAbandonedFanIsRefusedDurably() async throws {
        let helper = Self.composed(writes: .refused(reason: "the firmware refused the mode write"))
        await helper.bindSafetyRegistries()
        try await Self.acquireAndRelease(in: helper)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(
                reason: .restoreToAutomaticFailed)
        ) {
            _ = try await helper.leases.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
    }

    // MARK: - The order, observed at the write

    /// § 5 is told **before** the keystone write and § 3 **after** it.
    ///
    /// Observed from inside the write itself, because that is the only instant at which the
    /// two orders differ — see `RegistryObservingPlane`. Every other assertion in this file
    /// is about the end state, and the end state is identical whichever way round the two
    /// loops run.
    ///
    /// **The § 3 half is the owed set since #295.** The restorer no longer removes anything
    /// from § 3, so `observed.thermal == [0]` holds whichever side § 3 is told on and pins
    /// nothing about the order; a review confirmed that marking before the write left the
    /// suite green. What differs is the owed set: marked after the write, fan 0 is not yet
    /// owed at it. Marked before, it is owed at the write — and every fan asked for is marked,
    /// refused or not, because the refusal is not yet known.
    ///
    /// **Mutation:** move the `reclamationWatchdog` loop below the `bounded` call in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red — the fan is still in
    /// § 5's registry at the write.
    /// **Mutation:** move the `thermalEmergency?.handbackAccepted(fanAt:)` loop, over `fans`,
    /// above the `bounded` call. Run: red on `observed.thermalOwed.isEmpty`.
    @Test("The watchdog is told before the write and the thermal registry after it")
    func theRegistriesAreToldOnOppositeSidesOfTheWrite() async throws {
        let plane = RegistryObservingPlane(
            ScriptedControlPlane(
                fans: [0: .automatic(at: 2_400)],
                stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)]))
        let helper = HelperComposition(
            plane: plane,
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: Self.helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: Self.safetyLog)
        await plane.observe(
            reclamationWatchdog: helper.reclamationWatchdog,
            thermalEmergency: helper.thermalEmergency)
        await helper.bindSafetyRegistries()
        try await Self.engage(fan: 0, in: helper)

        try await Self.acquireAndRelease(in: helper)

        let observed = try #require(
            await plane.observations.first, "the keystone write never reached the firmware")
        #expect(observed.scope == .fan(0), "the restore is issued per fan, never .everyFan")
        #expect(
            observed.reclamation.isEmpty,
            """
            § 5 was still watching fan 0 when its mode write was issued. A cycle landing in \
            that window reads the fan as reclaimed by the system.
            """)
        #expect(
            observed.thermal == [0],
            """
            § 3 had already forgotten fan 0 when its mode write was issued, so a write the \
            firmware refuses leaves a fan off automatic control that no emergency can bridge.
            """)
        #expect(
            observed.thermalOwed.isEmpty,
            """
            § 3 was told of the handback before its mode write was issued, so it is told of \
            fans whose write the firmware then refuses.
            """)
    }
}
