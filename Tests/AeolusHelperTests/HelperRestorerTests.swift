import AeolusXPC
import FanKit
import Foundation
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

    private static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Composition")
    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    /// One composed helper over the scripted firmware, with one fan already under manual
    /// control at a plausible speed.
    ///
    /// `writes` is the firmware's answer to the keystone mode write, which is the whole of
    /// the difference between a fan that came back and a fan that was abandoned.
    static func composed(
        writes: ScriptedControlPlane.WriteBehaviour = .honoured
    ) -> HelperComposition<ScriptedControlPlane> {
        HelperComposition(
            plane: ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
                stages: [
                    .nominal(temperatures: LeaseFixture.nominalDieTemperatures, writes: writes)
                ]),
            snapshotProvider: fanProvider(fanCount: 1),
            criticalSensors: .mac16x5,
            log: helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog)
    }

    /// Puts fan 0 into both registries, the way E3's control plane will once it exists.
    ///
    /// Both calls take a `CommandableFan`, so this cannot register a fan whose declared
    /// bounds would have failed #37's gate — see `ReclamationWatchdog.manualControlEngaged(_:)`
    /// for why the parameter is the permit rather than an index.
    private static func engage<Plane: FanControlPlane>(
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

    /// § 3 stops listing a fan whose lease ended and whose handback the firmware took.
    ///
    /// A stale entry here is bounded and in the safe direction — a redundant bridge and a
    /// redundant restore of a fan already on Apple's management — but the registry is what
    /// `fire(_:from:)` reads as *"every fan under manual control"*, and a registry that says
    /// more than it can deliver is the shape `ThermalEmergency.manualControlReleased(fanAt:)`
    /// was written against.
    ///
    /// **Mutation:** delete the `thermalEmergency?.manualControlReleased(fanAt:)` loop in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red.
    @Test("Releasing a lease stops the thermal emergency listing its fan")
    func theThermalRegistryIsToldWhenALeaseEnds() async throws {
        let helper = Self.composed()
        await helper.bindSafetyRegistries()
        try await Self.engage(fan: 0, in: helper)
        #expect(await helper.thermalEmergency.fansUnderManualControl == [0])

        try await Self.acquireAndRelease(in: helper)

        #expect(
            await helper.thermalEmergency.fansUnderManualControl.isEmpty,
            "§ 3 still lists a fan that is back on Apple's thermal management")
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
    /// **Mutation:** replace `fans.subtracting(abandoned)` with `fans` in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red.
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
    /// **Mutation:** move the `reclamationWatchdog` loop below the `bounded` call in
    /// `HelperFanRestorer.restoreToAutomatic(fans:because:)`. Run: red — the fan is still in
    /// § 5's registry at the write.
    @Test("The watchdog is told before the write and the thermal registry after it")
    func theRegistriesAreToldOnOppositeSidesOfTheWrite() async throws {
        let plane = RegistryObservingPlane(
            ScriptedControlPlane(
                fans: [0: .held(at: 2_400)],
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
    }
}
