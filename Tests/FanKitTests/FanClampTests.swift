import Foundation
import Testing

@testable import FanKit

/// `docs/SAFETY.md` § 2, and the defect that made § 2 as written insufficient.
///
/// Clamping into `[F0Mn, F0Mx]` alone does not deliver `CLAUDE.md` rule 3. Firmware may
/// legitimately declare a minimum of zero — `docs/RECOVERY.md` records that a fan reading
/// zero at idle is normal on many Macs — and a clamp whose floor is that declaration then
/// permits commanding a stop. The floor is `max(F0Mn, minimumManualRPM)`, and
/// `zeroDeclaredMinimumStillFloorsAboveZero` is the test that says so.
@Suite("Hardware clamping")
struct FanClampTests {

    private func envelope(
        minimum: Double,
        maximum: Double
    ) throws -> FanControlEnvelope {
        try FanControlEnvelope.validating(
            declaredMinimumRPM: minimum,
            declaredMaximumRPM: maximum
        ).get()
    }

    @Test("A request below the firmware minimum is raised to it")
    func clampsBelowMinimum() throws {
        #expect(try envelope(minimum: 1200, maximum: 5400).target(for: 400).rpm == 1200)
    }

    @Test("A request above the firmware maximum is lowered to it")
    func clampsAboveMaximum() throws {
        #expect(try envelope(minimum: 1200, maximum: 5400).target(for: 9000).rpm == 5400)
    }

    /// Stopping a fan outright must not be reachable, whatever the caller asks for.
    @Test("Zero and negative requests never reach the hardware")
    func neverAllowsZero() throws {
        let fan = try envelope(minimum: 1200, maximum: 5400)
        #expect(fan.target(for: 0).rpm == 1200)
        #expect(fan.target(for: -500).rpm == 1200)
    }

    /// The defect this whole file exists for.
    ///
    /// Firmware declaring a minimum of zero is not a fault to refuse — it is a machine
    /// whose fans stop when idle, which `docs/RECOVERY.md` says is normal. It is the
    /// *clamp* that must not inherit that zero. Delete the `max` in
    /// `lowestCommandableRPM` and this test reports 0 RPM as a permitted target.
    @Test("A firmware minimum of zero does not make a stop commandable")
    func zeroDeclaredMinimumStillFloorsAboveZero() throws {
        let fan = try envelope(minimum: 0, maximum: 5777)

        #expect(fan.declaredMinimumRPM == 0)
        #expect(fan.lowestCommandableRPM == FanSafetyLimits.minimumManualRPM)
        #expect(fan.target(for: 0).rpm == FanSafetyLimits.minimumManualRPM)
        #expect(fan.target(for: -500).rpm == FanSafetyLimits.minimumManualRPM)
        #expect(fan.target(for: 0).rpm > 0)
    }

    /// The floor is compiled in, and being greater than zero is the whole of its job.
    @Test("The commandable floor is a positive compiled-in constant")
    func theFloorIsAboveZero() {
        #expect(FanSafetyLimits.minimumManualRPM > 0)
    }

    /// `min(max(_:_:)_:)` passes NaN straight through — every comparison with NaN is
    /// false, so neither half of the clamp fires. Delete the `isNaN` guard and this
    /// reports NaN as a speed to write.
    @Test("A NaN request resolves to the floor rather than passing through")
    func nanRequestResolvesToTheFloor() throws {
        let fan = try envelope(minimum: 1200, maximum: 5400)
        let target = fan.target(for: .nan)

        #expect(target.rpm.isNaN == false)
        #expect(target.rpm == 1200)
    }

    /// Unlike NaN, the infinities have an unambiguous answer and the arithmetic already
    /// gives it. Asserted rather than assumed, because "the guard covers NaN only" is a
    /// deliberate narrowing and this is what it buys.
    @Test("An infinite request resolves to the nearer end of the envelope")
    func infiniteRequestsResolveToTheEnds() throws {
        let fan = try envelope(minimum: 1200, maximum: 5400)
        #expect(fan.target(for: .infinity).rpm == 5400)
        #expect(fan.target(for: -.infinity).rpm == 1200)
    }

    /// The property every caller downstream relies on, over the whole space of requests
    /// this project can imagine reaching it.
    @Test(
        "Every target is finite and inside the envelope",
        arguments: [
            0, -0.0, -1, -500, 1, 99.9, 1200, 3000, 5400, 9000, 1e18, -1e18,
            Double.leastNonzeroMagnitude, .nan, .infinity, -.infinity,
        ] as [Double])
    func everyTargetLandsInsideTheEnvelope(request: Double) throws {
        for (minimum, maximum) in [(0.0, 5777.0), (1200.0, 5400.0), (1350.0, 5777.0)] {
            let fan = try envelope(minimum: minimum, maximum: maximum)
            let target = fan.target(for: request).rpm

            #expect(target.isFinite)
            #expect(target >= fan.lowestCommandableRPM)
            #expect(target <= fan.highestCommandableRPM)
            #expect(target > 0)
        }
    }

    /// The asymmetry the whole subsystem rests on, in one test: the same number is
    /// clamped as a target and untouched as an observation.
    ///
    /// `F0Ac` was measured at 1343.07 against a declared `F0Mn` of 1350 on this project's
    /// development machine. A reading below the declared minimum is a real observation,
    /// and no test here may assume otherwise.
    @Test("An observation below the firmware minimum is never clamped")
    func observationsAreNeverClamped() throws {
        let state = FanState(
            index: 0,
            actualRPM: .measured(1343.07),
            minimumRPM: .measured(1350),
            maximumRPM: .measured(5777),
            targetRPM: nil,
            mode: .automatic,
            isReclaimedBySystem: false,
            manualControlAvailability: .unavailable(.writePathNotBuilt)
        )

        // Observed: carried exactly, below the declared minimum and staying there.
        #expect(state.actualRPM.value == 1343.07)
        let decoded = try JSONDecoder().decode(
            FanState.self, from: try JSONEncoder().encode(state))
        #expect(decoded.actualRPM.value == 1343.07)

        // Requested: the identical number, raised to the firmware minimum.
        let fan = try envelope(minimum: 1350, maximum: 5777)
        #expect(fan.target(for: 1343.07).rpm == 1350)
    }
}

@Suite("Lease expiry")
struct LeaseTests {

    /// `expiresAt` is carried and rendered; it is not judged.
    ///
    /// This suite used to assert `Lease.isExpired(at: Date)` against a wall clock, which
    /// made the DTO look like the place expiry is decided. It is not, and the method is
    /// gone: [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) puts enforcement on
    /// `ContinuousClock` inside the helper, where `LeaseAuthority` and
    /// `LeaseExpirySupervisor` now hold it and where the tests that matter live. What is
    /// left to check here is that the display value survives the wire intact.
    @Test("The display expiry survives a round trip unchanged")
    func expiryRoundTrips() throws {
        let lease = Lease(
            holderDescription: "test",
            expiresAt: Date(timeIntervalSince1970: 1_000_030)
        )

        let decoded = try JSONDecoder().decode(
            Lease.self, from: try JSONEncoder().encode(lease))

        #expect(decoded == lease)
        #expect(decoded.expiresAt == Date(timeIntervalSince1970: 1_000_030))
        #expect(decoded.isSelfRenewing == false)
    }

    /// Two missed heartbeats must still leave room for a third attempt before control is
    /// surrendered, otherwise a single scheduling hiccup drops the fans to automatic.
    @Test("The default heartbeat allows for missed beats within the TTL")
    func heartbeatFitsWithinTTL() {
        #expect(Lease.defaultHeartbeatInterval * 3 <= Lease.defaultTimeToLive)
    }
}
