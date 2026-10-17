import Testing

@testable import AeolusHelper

/// The engagement driver's arbiter level is its own, stored at composition, and never its
/// writer's (ADR 0014's A6 and A6 PR-2 amendments).
///
/// Level 6's driver steps through a `SafetyActorWriter`, whose level is one of the five that bypass
/// § 8; asked about that, the arbiter would judge the control loop as a safety actor. With § 3's
/// latch the only incumbent today, `.reclamationWatchdog` and `.controlLoop` are both pre-empted by
/// it, so the composed levels are pinned by property; the first test is what shows the arbiter
/// reads the stored one, with levels a composition never uses.
@Suite("The engagement driver's level", .timeLimit(.minutes(1)))
struct EngagementDriverLevelTests {

    /// A driver at `level`, stepping through a writer at `writing`, bound to the rig's lease.
    private static func driver(
        at level: SafetyActorLevel, writing: SafetyActorLevel.Ungoverned, on rig: EngagementRig
    ) throws -> EngagementDriver<InterferingFanStateSensing> {
        let lease = try #require(rig.lease)
        return EngagementDriver(
            writer: SafetyActorWriter(plane: rig.writes, level: writing), leases: rig.leases,
            latch: rig.latch, emergency: rig.registry, clock: rig.clock, level: level
        ).under(lease: lease.id)
    }

    /// With § 3 latched, a driver at § 3's own level is admitted, through a writer at § 5's, and a
    /// driver at the control loop's is pre-empted, through a writer at § 3's.
    ///
    /// **Mutation:** in `EngagementDriver.init`, assign `level = writer.level.level` instead of the
    /// parameter. Run: red on both.
    @Test("The arbiter is asked about the driver's own level, never its writer's")
    func theArbiterAsksAboutTheDriversOwnLevel() async throws {
        let rig = try await EngagementRig(unlock: .naive)
        await rig.engageThermalEmergency()

        let admitted = try Self.driver(
            at: .thermalEmergency, writing: .reclamationWatchdog, on: rig)
        try await admitted.requireEntitlement(for: rig.fan(0))

        let preempted = try Self.driver(at: .controlLoop, writing: .thermalEmergency, on: rig)
        await #expect(throws: EngagementRefusal.preempted(fan: 0, by: .thermalEmergency)) {
            try await preempted.requireEntitlement(for: rig.fan(0))
        }
        #expect(admitted.level == .thermalEmergency && preempted.level == .controlLoop)
    }

    /// § 5's composed driver is asked about § 5's level.
    ///
    /// **Mutation:** in `HelperComposition.init`, compose § 5's driver with `level: .controlLoop`.
    /// Run: red.
    @Test("The composition builds § 5's driver at § 5's level")
    func theComposedReclamationDriverIsAtSectionFivesLevel() {
        let helper = HelperRestorerTests.composed()
        #expect(helper.reclamationWatchdog.engagementLevel == .reclamationWatchdog)
    }
}
