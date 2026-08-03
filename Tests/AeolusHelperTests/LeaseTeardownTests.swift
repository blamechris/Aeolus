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
