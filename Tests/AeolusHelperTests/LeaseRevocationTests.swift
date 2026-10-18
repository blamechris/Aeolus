import AeolusXPC
import FanKit
import Foundation
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

    // MARK: - One named lease (#353)

    /// § 5's terminal revocation names the lease it was holding the fan for, and revokes that
    /// lease and no other: a different ID revokes nothing, and the named one goes whole, in one
    /// restore carrying the cause.
    ///
    /// **Mutation:** make `revokeLease(id:forFan:because:)` select the table's lease rather than
    /// the named one — `table.all.first` in place of `table.entry(id: id)`. Run: red on the
    /// unnamed ID's refusal and the restores it made.
    @Test("Revoking a lease by ID revokes only that lease, whole")
    func revokeLeaseRevokesOnlyTheNamedLiveLeaseWhole() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())

        let unnamed = observing {
            await authority.revokeLease(id: UUID(), forFan: 0, because: .systemReclaimed)
        }
        #expect(
            try await finishedBeforeCeiling("the unnamed revocation", unnamed) == .gone,
            "a lease was revoked under an ID it was never granted")
        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty, "an unnamed lease's fans were handed back")

        #expect(
            await authority.revokeLease(id: lease.id, forFan: 0, because: .systemReclaimed)
                == .revoked)
        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restoredFans == [Set([0, 1])], "the lease was not revoked whole")
        #expect(await restorer.causes == [.systemReclaimed])
    }

    /// A lease past its deadline and not yet swept is **ended now, as expired**, not revoked
    /// (#361's panel). It ended on its own, so revoking it would tell the client the system took
    /// control it had already lost; and leaving it to the TTL sweep let the sweep's release
    /// notice arrive after § 5's terminal action returned and erase the mark it keeps
    /// (`FinaliseReleaseLedgerTests.aLeaseLapsingDuringTheHandBackKeepsTheMarkThroughItsExpiry`).
    ///
    /// **Mutation:** decline a lapsed lease again — `guard let entry = table.entry(id: id),
    /// !entry.hasLapsed(asOf: clock.now) else { return .gone }`. Run: red on the outcome, the
    /// count and the cause. **Mutation:** restore it under `cause` whatever its deadline —
    /// `because: cause`. Run: red on the cause alone (`:123`). **Mutation:** treat it as revoked —
    /// `let outcome: LeaseRevocation = .revoked`. Run: red on the outcome and the cause (`:121`,
    /// `:123`) and on `FinaliseReleaseRevocationTests`' "had already ended" notice (`:133`).
    @Test("Revoking a lapsed lease by ID ends it as expired")
    func revokeLeaseEndsALapsedLeaseAsExpired() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        clock.advance(by: .seconds(Lease.defaultTimeToLive))

        #expect(
            await authority.revokeLease(id: lease.id, forFan: 0, because: .systemReclaimed)
                == .expired)
        #expect(await authority.leaseCount == 0, "the lapsed lease was left for the sweep")
        #expect(
            await restorer.causes == [.leaseExpired], "a lapsed lease was blamed on § 5's cause")
    }

    /// The entry leaves the table **before** the revocation's restore is awaited, as every
    /// teardown here does (#188): while the restore is in flight the lease is not live, and a
    /// grant over its fans is refused as `.releaseInProgress` rather than racing the restore.
    /// The restore is held open by `RecordingFanRestorer`, which suspends on a continuation.
    ///
    /// **Mutation:** move `table.remove(id: id)` below `await restore(…)` in
    /// `revokeLease(id:forFan:because:)`. Run: red on liveness, the count and the grant's refusal.
    @Test("A revoked lease is gone before its restore is awaited")
    func revokeLeaseRemovesTheEntryBeforeItsRestore() async throws {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: entered, release: release)
        let authority = LeaseFixture.authority(restorer: restorer)
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())
        let revocation = observing {
            await authority.revokeLease(id: lease.id, forFan: 0, because: .systemReclaimed)
        }
        try await entered.wait()

        #expect(
            await authority.hasLiveLease(id: lease.id, coveringFan: 0) == false,
            "the lease answered live while its revocation's restore was on the wire")
        #expect(await authority.leaseCount == 0)
        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        await release.signal()
        #expect(try await finished("the revocation", revocation) == .revoked)
    }

    // MARK: - The refusal, and where it sits in the order

    @Test("A latched thermal emergency refuses a grant")
    func aLatchedEmergencyRefusesAGrant() async throws {
        let latch = ThermalEmergencyLatch()
        let authority = LeaseFixture.authority(thermalEmergency: latch)
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
            answering: [smcKey("Tp01")])

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
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
            answering: [smcKey("Tp01")])

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
        await latch.engage(
            by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
            answering: [smcKey("Tp01")])

        await #expect(throws: AeolusXPCFault.thermalEmergencyActive) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await restorer.causes == [.leaseExpired])
        #expect(await authority.leaseCount == 0)
    }
}
