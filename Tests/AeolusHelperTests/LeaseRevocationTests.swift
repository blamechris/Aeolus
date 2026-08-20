import AeolusXPC
import FanKit
import Testing

@testable import AeolusHelper

/// The lease core's third teardown path, and the grant-time refusal that goes with it.
///
/// The TTL, connection death and a voluntary release are all a holder running out of claim.
/// Revocation is a claim being **taken** from a client that did nothing wrong, and
/// `docs/SAFETY.md` § 3 is the only thing that does it.
@Suite("Lease revocation and the thermal-emergency refusal")
struct LeaseRevocationTests {

    // MARK: - Revocation

    /// Whole, not trimmed. `LeaseRecord.fanIndices` is a `let` so the trimming shape is not
    /// expressible, and this asserts the behaviour that property exists to protect.
    @Test("Revoking one fan drops the whole lease and restores every fan it covered")
    func revocationTakesTheWholeLease() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())

        await authority.revokeLeases(coveringFan: 0, because: .thermalEmergency)

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restoredFans == [Set([0, 1])])
        #expect(await restorer.causes == [.thermalEmergency])
    }

    /// The selector is a selector. A lease that does not cover the fan is untouched —
    /// otherwise § 3 firing on one machine's fan would drop control of everything.
    @Test("A lease that does not cover the fan is left alone")
    func revocationIsSelective() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())

        await authority.revokeLeases(coveringFan: 0, because: .thermalEmergency)

        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)
    }

    @Test("Revoking when nothing is held restores nothing")
    func revocationOnAnIdleMachineIsANoOp() async {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)

        await authority.revokeLeases(coveringFan: 0, because: .thermalEmergency)

        #expect(await restorer.restores.isEmpty)
    }

    /// The cause reaches the restore, which is what makes the two mechanisms auditable
    /// apart in `log show`. ADR 0005 requires the lease's paths to be independent, and
    /// "independent" is only checkable if an observer can tell which one acted.
    @Test("The revocation cause is carried to the restore, not flattened")
    func theCauseSurvives() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())

        await authority.revokeLeases(coveringFan: 0, because: .thermalEmergency)

        #expect(await restorer.causes == [.thermalEmergency])
        #expect(await restorer.causes != [.leaseExpired])
    }

    // MARK: - The refusal, and where it sits in the order

    @Test("A latched thermal emergency refuses a grant")
    func aLatchedEmergencyRefusesAGrant() async throws {
        let latch = ThermalEmergencyLatch()
        let authority = LeaseFixture.authority(thermalEmergency: latch)
        await latch.engage(by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99))

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    /// Both refusals apply at once on a machine that is hot **and** blind. This asserts
    /// which fact the client is told, and it is a judgement rather than an accident: a
    /// machine above its ceiling is the worse thing to grant a lease on, and the check costs
    /// no hardware round trip.
    @Test("The emergency is reported ahead of blindness")
    func theEmergencyOutranksBlindness() async throws {
        let latch = ThermalEmergencyLatch()
        let authority = LeaseFixture.authority(
            telemetry: LeaseFixture.blindTelemetry(), thermalEmergency: latch)
        await latch.engage(by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99))

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
    }

    /// The refusal sits **below** the lapsed-lease sweep, deliberately: a lapsed lease's
    /// fans go back to automatic whether or not the machine is too hot, and a machine above
    /// its ceiling is the last one on which to skip a restore.
    ///
    /// Move `refuseIfThermalEmergencyActive(_:)` above `expireLapsedLeases()` and this goes
    /// red — the restore never happens.
    @Test("A lapsed lease is still swept when the latch is engaged")
    func theSweepStillRunsWhileLatched() async throws {
        let latch = ThermalEmergencyLatch()
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(
            restorer: restorer, thermalEmergency: latch, clock: clock)
        _ = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 5), from: ConnectionID())

        clock.advance(by: .seconds(10))
        await latch.engage(by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99))

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await restorer.causes == [.leaseExpired])
        #expect(await authority.leaseCount == 0)
    }
}
