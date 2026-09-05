import AeolusXPC
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// ADR 0010's age bound, exercised through the **composed** helper rather than a cache built
/// by hand.
///
/// `CriticalTemperatureCacheTests.aStaleSightingIsNotServed` proves the cache expires a
/// reading. It says nothing about the daemon, because it constructs its own cache over its own
/// clock — and until this suite existed the graph `AeolusHelperMain` builds had **no** test of
/// the bound at all: `HelperComposition` let the cache default to `SystemMonotonicClock()`, so
/// the one timeline a composed test can advance did not reach it. A staleness bound that no
/// composed test can move is a bound whose wiring is unasserted, which is the shape
/// `HelperRestorerTests`' own preamble calls the defect #163 exists to end.
///
/// One clock, injected once, is what closes it: `HelperComposition(clock:)` now reaches the
/// lease core's TTL *and* the sighting cache, so "a cycle read, then a second passed" is a
/// scenario the composed graph can be put through.
///
/// The composition is `HelperRestorerTests.composed(clock:)` deliberately — the same builder
/// every other composed-graph suite uses, so nothing here is a paraphrase of the daemon's
/// wiring.
@Suite("Sightedness through the composed helper", .timeLimit(.minutes(1)))
struct HelperSightednessTests {

    /// § 3's cadence, named from the supervisor that runs it rather than from the bound under
    /// test — `CriticalTemperatureCacheTests.oneCyclePeriod`'s argument, which was found by
    /// running the mutation.
    private static var oneCyclePeriod: Duration {
        ThermalSupervisor<ScriptedControlPlane>.defaultInterval
    }

    /// A grant is served from § 3's reading, and reads for itself once that reading ages out.
    ///
    /// Both halves in one test, because each is the other's control: the first assertion could
    /// pass on a cache that never expires anything, and the second on a cache that never
    /// serves anything. Together they say the reading was served *and* that it stopped being
    /// served, on the one timeline the daemon measures both against.
    ///
    /// The lease is released before the clock moves so the second grant is refused by nothing
    /// — `refuseIfBlind` runs above the concurrent-lease check, so a refused grant would still
    /// prove sightedness and the read count would be right for the wrong reason.
    ///
    /// **Mutation (M9):** drop `clock: clock` from `HelperComposition`'s
    /// `CriticalTemperatureCache(source: telemetry, clock: clock)`. Run: red — the cache keeps
    /// its own `SystemMonotonicClock`, the advance below reaches nothing, and the second grant
    /// is served a reading the test has aged past one cycle period.
    @Test("A composed grant is served § 3's reading until one cycle period has passed")
    func aComposedGrantIsServedTheCyclesReadingUntilItAgesOut() async throws {
        let clock = TestClock()
        let helper = HelperRestorerTests.composed(clock: clock)

        await helper.thermalEmergency.cycle()

        let connection = ConnectionID()
        let lease = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)
        #expect(
            await helper.sightings.readsIssued == 0,
            "the grant read the SMC for itself on a machine § 3 had just seen")
        #expect(await helper.sightings.coalescedSightings == 1)
        try await helper.leases.releaseLease(id: lease.id, from: connection)

        clock.advance(by: Self.oneCyclePeriod + .milliseconds(1))

        _ = try await helper.leases.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        #expect(
            await helper.sightings.readsIssued == 1,
            """
            a reading older than one § 3 cycle period was served to a grant. The age bound is \
            what makes sharing the cycle's reading defensible at all.
            """)
        #expect(await helper.sightings.coalescedSightings == 1)
    }
}
