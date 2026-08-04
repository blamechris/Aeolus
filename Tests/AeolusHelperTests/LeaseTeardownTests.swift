import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The lease has two teardown paths and
/// [ADR 0005](../../docs/ADR/0005-xpc-authorisation.md) requires them to be independent:
/// *"Either mechanism alone suffices; both must fail for the fans to stay pinned; **they
/// share no code path.**"* `AeolusXPCProtocol` states the failure mode it is guarding
/// against — *"An implementation that expires leases from the invalidation handler has one
/// mechanism wearing two names."*
///
/// ## How independence is proved here, rather than asserted
///
/// Each mechanism is exercised with the other made **structurally incapable of acting**:
///
/// - The TTL tests never call `connectionDidInvalidate`, so nothing but the clock can have
///   restored the fans.
/// - The connection-death tests **never advance the clock**, so no lease in them can ever
///   have lapsed — and each one checks that first, by sweeping and finding nothing, before
///   the connection dies.
///
/// The recorded `FanRestoreCause` then says which mechanism acted. That is corroboration,
/// not the proof: an implementation that routed invalidation through the expiry sweep would
/// fail the frozen-clock tests outright, because a sweep at a frozen instant has nothing to
/// sweep.
@Suite("The lease's two teardown paths are independent")
struct LeaseTeardownIndependenceTests {

    /// The TTL alone, with no connection event of any kind.
    @Test("The TTL restores the fans with no invalidation ever delivered")
    func timeToLiveActsAlone() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1], timeToLive: 30), from: ConnectionID())

        clock.advance(by: .seconds(30))
        await authority.expireLapsedLeases()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0, 1], cause: .leaseExpired)])
        // No connection ever died in this test, so no tombstone can exist. If one did, the
        // invalidation path had been reached by some route this test did not take.
        #expect(await authority.tombstoneCount == 0)
    }

    /// Connection death alone, with the clock frozen so the TTL cannot have contributed.
    @Test("Connection death restores the fans with the clock frozen")
    func connectionDeathActsAlone() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)
        let connection = ConnectionID()

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: connection)

        // The premise, checked rather than assumed: at this instant the TTL has nothing to
        // do, so anything that happens below is not the TTL happening.
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)

        await authority.connectionDidInvalidate(connection)

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0], cause: .connectionInvalidated)])
    }

    /// Neither path fires twice, and neither fires for the other's lease. A second
    /// invalidation for the same connection restores nothing, because there is nothing left
    /// to restore.
    @Test("A repeated invalidation restores nothing the second time")
    func repeatedInvalidationIsIdempotent() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let connection = ConnectionID()

        _ = try await authority.acquireLease(LeaseFixture.request(), from: connection)
        await authority.connectionDidInvalidate(connection)
        await authority.connectionDidInvalidate(connection)

        #expect(await restorer.causes == [.connectionInvalidated])
        #expect(await authority.tombstoneCount == 1)
    }

    /// A connection dying takes its own lease and nobody else's. With one lease at a time
    /// this is a small claim today; it is the claim that stops the invalidation path from
    /// being written as "drop everything", which would make it indistinguishable from the
    /// panic path.
    @Test("Invalidating a connection that holds nothing restores nothing")
    func invalidatingABystanderRestoresNothing() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let holder = ConnectionID()

        _ = try await authority.acquireLease(LeaseFixture.request(), from: holder)
        await authority.connectionDidInvalidate(ConnectionID())

        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)
    }
}

/// The client-driven and global teardowns: an explicit release, and the panic path.
@Suite("Lease release")
struct LeaseReleaseTests {

    @Test("Releasing a held lease drops it and restores its fans")
    func releaseDropsAndRestores() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let connection = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: connection)
        try await authority.releaseLease(id: lease.id, from: connection)

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0, 1], cause: .leaseReleased)])
    }

    /// The panic path's half of the job. `restoreAllToAutomatic` additionally restores every
    /// enumerated fan in the control plane; what the lease core owes it is that no lease
    /// survives it.
    @Test("Dropping every lease restores every fan they covered")
    func everyLeaseIsDropped() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1]), from: ConnectionID())
        await authority.releaseEveryLease()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.restores == [.init(fans: [0, 1], cause: .allLeasesDropped)])
    }

    /// The panic path consults no per-`ConnectionID` state, which is the precondition
    /// `HelperConnectionSession` documents for exempting it from the teardown gate. Running
    /// it for a connection that has already been invalidated must therefore behave exactly
    /// as running it for a live one — both orderings converge on the safe state.
    @Test("Dropping every lease works identically after the connection has been invalidated")
    func panicPathIgnoresConnectionState() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let holder = ConnectionID()
        let panicker = ConnectionID()

        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)
        await authority.connectionDidInvalidate(panicker)
        await authority.releaseEveryLease()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.causes == [.allLeasesDropped])
    }
}

/// The handback window: a lease's entry leaves the table synchronously, but its restore
/// completes an `await` later, and the actor is reentrant across that gap.
///
/// Reported independently by two reviewers of #107, which is why it is closed here rather
/// than deferred to E5.3 — the interlock needs nothing from the control plane, and a core
/// that ships with a known rule-6 window is a worse foundation than one that does not.
@Suite("The handback window")
struct LeaseHandbackWindowTests {

    /// The interleaving stated as the failure it produces, not as the mechanism: while fan
    /// 0's restore is still on the wire, a lease over fan 0 must not be granted. If it were,
    /// the new holder would write a target and the in-flight restore would land on top of
    /// it, leaving a live lease over a fan nothing is honouring.
    @Test("A lease is refused over a fan whose handback is still in flight")
    func leaseRefusedWhileRestoreInFlight() async throws {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: entered, release: release)
        let authority = LeaseFixture.authority(restorer: restorer)

        let holder = ConnectionID()
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)

        // Park the teardown inside the restore, which is exactly where the window is.
        let dying = Task { await authority.connectionDidInvalidate(holder) }
        await entered.wait()

        // The table is already empty here — that is the condition `acquireLease` checks, and
        // why an emptied table alone cannot close this.
        #expect(await authority.leaseCount == 0)

        let refusal = await #expect(throws: AeolusXPCFault.self) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0]), from: ConnectionID())
        }
        #expect(refusal == .manualControlUnavailable(reason: .releaseInProgress))
        // Asserted as well as the fault: a guard that refuses *and* registers returns an
        // identical error.
        #expect(await authority.leaseCount == 0)

        await release.signal()
        await dying.value
    }

    /// The window closes. A refusal that never lifted would be a fan permanently
    /// unleasable — the interlock failing safe in the direction that still breaks the app.
    @Test("Once the handback completes the fan is leasable again")
    func fanIsLeasableOnceRestoreCompletes() async throws {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: entered, release: release)
        let authority = LeaseFixture.authority(restorer: restorer)

        let holder = ConnectionID()
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)
        let dying = Task { await authority.connectionDidInvalidate(holder) }
        await entered.wait()
        await release.signal()
        await dying.value

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        #expect(lease.isSelfRenewing == false)
        #expect(await authority.leaseCount == 1)
    }

    /// A fan not being handed back is not blocked by one that is: the interlock is per-fan
    /// and must not become a whole-machine lock by accident.
    ///
    /// This test was first written asserting a *refusal*, on the assumption that the
    /// one-lease-at-a-time guard would catch it — and it failed, correctly. At this instant
    /// there is no lease to conflict with: the dying holder's entry is removed synchronously
    /// before the restore suspends, which is the whole reason the handback window exists.
    /// Granting fan 1 here is right, and the interlock's job is to be narrower than the
    /// window, not wider.
    @Test("A different fan is grantable while another fan's handback is in flight")
    func unrelatedFanIsNotBlockedByTheHandback() async throws {
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: entered, release: release)
        let authority = LeaseFixture.authority(restorer: restorer)

        let holder = ConnectionID()
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)
        let dying = Task { await authority.connectionDidInvalidate(holder) }
        await entered.wait()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [1]), from: ConnectionID())
        #expect(lease.holderDescription.isEmpty == false)
        #expect(await authority.leaseCount == 1)

        await release.signal()
        await dying.value
    }
}

/// The property that makes the handback interlock work is *where* its guard sits, not that
/// it exists — and `LeaseHandbackWindowTests` above cannot tell the two apart, because all
/// three of its cases open the window before calling `acquireLease`.
///
/// Hoisting the guard above `enumeratedFanIndices()` leaves every one of them green while
/// the window reopens. `LeaseAuthority`'s own documentation warns about exactly this shape
/// for the #95 liveness check — "a test could stay green on the early refusal while the
/// guarded region below was unprotected, which is exactly how a guard survives being
/// deleted" — so the new guard gets the same treatment the old one has.
@Suite("The handback guard sits after the last suspension point")
struct LeaseHandbackGuardPlacementTests {

    /// The interleaving a hoisted guard admits: the acquirer suspends in the hardware round
    /// trip *before* the fan is being released, so an early check sees a clear fan and waves
    /// it through. The teardown then starts while the acquirer is parked, and the acquirer
    /// resumes into a `table.isEmpty` that is true precisely because the lease it would have
    /// conflicted with has just been torn down.
    @Test("A handback that begins while the acquirer is suspended still refuses it")
    func handbackStartingDuringEnumerationStillRefuses() async throws {
        let gate = ScriptedFanEnumeration.Gate()
        // First call ungated so the holder can take its lease; the second parks the
        // acquirer inside the enumeration, which is the suspension the guard must follow.
        let enumeration = ScriptedFanEnumeration(indices: [0, 1], gates: [nil, gate])
        let restoreEntered = AsyncSignal()
        let restoreRelease = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: restoreEntered, release: restoreRelease)
        let authority = LeaseFixture.authority(enumeration: enumeration, restorer: restorer)

        let holder = ConnectionID()
        _ = try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: holder)

        // The acquirer starts and parks inside the enumeration, before any handback exists.
        let newcomer = ConnectionID()
        let acquiring = Task {
            try await authority.acquireLease(LeaseFixture.request(fans: [0]), from: newcomer)
        }
        await gate.entered.wait()

        // Only now does fan 0 start being handed back.
        let dying = Task { await authority.connectionDidInvalidate(holder) }
        await restoreEntered.wait()

        // Let the acquirer resume into an empty table and a fan mid-handback.
        await gate.release.signal()

        let refusal = await #expect(throws: AeolusXPCFault.self) { try await acquiring.value }
        #expect(refusal == .manualControlUnavailable(reason: .releaseInProgress))
        // The assertion that distinguishes "refused" from "refused and registered anyway".
        #expect(await authority.leaseCount == 0)

        await restoreRelease.signal()
        await dying.value
    }

}
