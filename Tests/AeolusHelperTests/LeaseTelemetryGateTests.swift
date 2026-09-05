import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// `docs/SAFETY.md` § 3 as a **precondition** of § 1.
///
/// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s second hole is that nothing
/// covered "the helper cannot read". A lease granted to a blind helper pins fans while the
/// thermal override cannot fire, the reclamation watchdog cannot tell divergence from
/// silence, and only the TTL is left. This suite is the half of the answer that runs before
/// any fan comes off automatic control.
@Suite("The grant-time thermal telemetry gate")
struct LeaseTelemetryGateTests {

    /// The gate itself. Delete `refuseIfBlind(_:)`'s call site in `acquireLease` and this
    /// is the test that goes red.
    @Test("A lease is refused while the helper cannot read a temperature")
    func aBlindHelperGrantsNoLease() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(
            restorer: restorer, telemetry: LeaseFixture.blindTelemetry())

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    /// The control that makes the test above mean something. Same fixture, same request,
    /// one difference: this machine can see. Without this, "refused" would be consistent
    /// with the fixture being broken in some unrelated way.
    @Test("The same request succeeds on a machine that can see")
    func aSightedHelperGrantsTheLease() async throws {
        let authority = LeaseFixture.authority()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(), from: ConnectionID())

        #expect(lease.holderDescription == "test client")
        #expect(await authority.leaseCount == 1)
    }

    /// The blindness refusal sits above the straight-line region, so it necessarily runs
    /// ahead of the concurrent-lease and mid-handback refusals. This drives a machine that
    /// goes blind **while a lease is held** — the state a Mac enters when its SMC stops
    /// answering mid-lease — so both refusals genuinely apply at once and the test asserts
    /// which one the client is told.
    ///
    /// `leaseHeldByAnotherClient` invites "wait for them to finish", which is wrong advice
    /// on a machine where nobody can be granted anything.
    ///
    /// ## The clock advance is part of the assertion, not scaffolding
    ///
    /// Since [#134](https://github.com/blamechris/Aeolus/issues/134) the grant path proves
    /// sightedness from § 3's most recent reading, so the *first* grant's own reading is
    /// still unexpired when the second arrives and a machine that goes blind in between is
    /// answered from it. That is the staleness
    /// [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md) accepts and bounds:
    /// **one cycle period, which is the granularity at which blindness is detected at all.**
    /// Advancing past `CriticalTemperatureCache.defaultMaxAge` is what makes this a test of
    /// the ordering rather than of the bound — `aStaleSightingIsNotServed` in
    /// `CriticalTemperatureCacheTests` owns the bound itself.
    @Test("Blindness is reported ahead of another client's lease")
    func blindnessOutranksTheConcurrentLeaseRefusal() async throws {
        let plane = ScriptedControlPlane(
            fans: [:],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
                .blind(),
            ])
        let clock = TestClock()
        let authority = LeaseFixture.authority(
            telemetry: LeaseFixture.cache(over: plane, clock: clock), clock: clock)

        _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        #expect(await authority.leaseCount == 1)

        await plane.advance()
        // A § 3 cycle period, named from the supervisor rather than from the cache's own
        // bound: advancing by the constant under test is how a staleness test stops being
        // able to fail. See `CriticalTemperatureCacheTests.aStaleSightingIsNotServed`.
        clock.advance(
            by: ThermalSupervisor<ScriptedControlPlane>.defaultInterval + .milliseconds(1))

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
    }

    /// The sweep runs before the proof, deliberately: a lapsed lease's fans go back to
    /// automatic whether or not the machine is blind, and a blind machine is the last one
    /// on which to skip a restore.
    ///
    /// Move `refuseIfBlind(_:)` above `expireLapsedLeases()` and this goes red — the
    /// refusal still fires, but nothing is ever handed back.
    @Test("A lapsed lease is still restored when the acquire is refused for blindness")
    func theLapsedSweepStillRunsWhenBlind() async throws {
        let restorer = RecordingFanRestorer()
        let clock = TestClock()
        let plane = ScriptedControlPlane(
            fans: [:],
            stages: [
                .nominal(temperatures: LeaseFixture.nominalDieTemperatures),
                .blind(),
            ])
        // One clock for the TTL and for the sighting's age bound, as the daemon has: the
        // advance below is past both, so the lapsed sweep and a real re-read both happen.
        let authority = LeaseFixture.authority(
            restorer: restorer,
            telemetry: LeaseFixture.cache(over: plane, clock: clock),
            clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        clock.advance(by: .seconds(Lease.defaultTimeToLive + 1))
        await plane.advance()

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }

        // The refusal happened, and the lapsed holder's fan went back to automatic anyway.
        #expect(await restorer.restoredFans == [[0]])
        #expect(await authority.leaseCount == 0)
    }

    /// A cancelled request is not a blind machine.
    ///
    /// Raised in review on #129. Folding `CancellationError` into the refusal would tell a
    /// client "no thermal telemetry" when telemetry was never the problem, and write a
    /// `.fault` line claiming the sensors went silent on a machine whose sensors are fine.
    /// Both outcomes refuse the lease, so this is about honesty rather than safety — which
    /// is `CLAUDE.md` rule 6's whole subject.
    ///
    /// Delete the `catch let cancellation as CancellationError` clause and this goes red.
    @Test("A cancelled telemetry read propagates rather than becoming a blindness refusal")
    func cancellationIsNotBlindness() async throws {
        let authority = LeaseFixture.authority(
            telemetry: CriticalTemperatureCache(source: ThrowingTelemetry(CancellationError())))

        await #expect(throws: CancellationError.self) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    /// The control: every other failure still becomes the refusal, so the clause above is a
    /// carve-out for one error rather than a hole in the default.
    @Test("Any other telemetry failure is still a blindness refusal")
    func otherFailuresAreStillBlindness() async throws {
        let authority = LeaseFixture.authority(
            telemetry: CriticalTemperatureCache(
                source: ThrowingTelemetry(
                    FanControlPlaneError.readFailed(detail: "stale port"))))

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        ) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    /// Additive vocabulary, not a protocol change — the property that lets this refusal
    /// ship inside v1.
    @Test("The blindness refusal needs no protocol bump")
    func theRefusalIsForwardTolerant() {
        #expect(AeolusXPCVersion.current == 1)

        let reason = ManualControlAvailability.Reason(wireValue: "noThermalTelemetry")
        #expect(reason == .noThermalTelemetry)
        #expect(
            ManualControlAvailability.Reason.noThermalTelemetry.wireValue
                == "noThermalTelemetry")

        // An older peer, which has never heard of it, renders it generically rather than
        // failing to decode.
        #expect(
            ManualControlAvailability.Reason(wireValue: "somethingFromAFutureHelper")
                == .unknown("somethingFromAFutureHelper"))
    }
}

/// Telemetry that fails a given way, for asserting how `refuseIfBlind` classifies an error.
///
/// Not `CuratedCriticalTemperatures` over a scripted plane, deliberately: the scripted plane
/// can be blind but cannot be cancelled, and this suite is about the classification rather
/// than about the curated conformer.
struct ThrowingTelemetry: CriticalTemperatureSensing {
    private let failure: any Error

    init(_ failure: any Error) { self.failure = failure }

    func readCriticalTemperatures() async throws -> CriticalTemperatureReport {
        throw failure
    }
}
