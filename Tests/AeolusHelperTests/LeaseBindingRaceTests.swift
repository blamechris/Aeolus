import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// [#95](https://github.com/blamechris/Aeolus/issues/95): the authority must refuse to bind
/// a lease to an invalidated `ConnectionID`.
///
/// ## The interleaving, and why the session gate cannot close it
///
/// `HelperConnectionSession.invalidationRefusal(message:)` refuses every gated message once
/// `invalidate()` has run, which closes exactly one of two orderings — invalidation arriving
/// **before** the message starts. The other is invalidation landing while a message is
/// **in flight**: the session is an `actor`, so it reads `hasInvalidated` synchronously and
/// then suspends at `await authority.acquireLease(...)`, and `invalidate()` can run on the
/// same actor during that suspension. The message resumes and registers its lease anyway.
///
/// `ReadOnlyFanAuthority` never suspends inside `acquireLease` — it refuses immediately — so
/// nothing in E2 could exercise this. `LeaseAuthority` awaits `FanEnumerating`, which is
/// exactly the suspension #95 predicted, and these tests drive that suspension deliberately.
///
/// ## What is asserted, and what would otherwise be asserted by accident
///
/// The refusal alone proves nothing: a guard that refused the client *and* registered the
/// lease anyway would return an identical fault. So every test below checks
/// `authority.leaseCount`, which is the actual defect.
///
/// The refusal's **wording** is checked too, and that is load-bearing rather than
/// fastidious. The session's own teardown gate refuses with
/// `helperFailed("the connection has been invalidated")`; the authority's in-flight guard
/// refuses with different text. Asserting the authority's text is what distinguishes "the
/// new guard fired" from "the old gate happened to catch it", and without it these tests
/// would pass against an implementation with no authority-side guard at all.
@Suite("Binding a lease to a dead connection")
struct LeaseBindingRaceTests {

    /// What the authority says when a request's own connection died mid-flight.
    private static let inFlight = AeolusXPCFault.helperFailed(
        detail: "the connection was invalidated while this request was in flight")

    /// What `HelperConnectionSession`'s arrival gate says. Named here so a test can assert
    /// the refusal is *not* this one.
    private static let arrivedAfterTeardown = AeolusXPCFault.helperFailed(
        detail: "the connection has been invalidated")

    private func session(authority: some FanAuthority) -> HelperConnectionSession {
        HelperConnectionSession(
            id: ConnectionID(),
            authority: authority,
            helperBuild: "test",
            log: HelperLog(subsystem: "dev.aeolus.AeolusHelperTests", category: "LeaseRace")
        )
    }

    /// **The scenario #95 describes, through the shipped listener half.**
    ///
    /// The probe order this forces is the one recorded on the issue:
    /// `acquireLease ENTERED`, `connectionDidInvalidate`, then `acquireLease` resuming — and
    /// the resumption must refuse instead of registering.
    @Test("A lease is not bound to a connection invalidated while acquireLease was in flight")
    func inFlightInvalidationRefusesTheBinding() async throws {
        let gate = ScriptedFanEnumeration.Gate()
        let enumeration = ScriptedFanEnumeration(indices: [0, 1], gates: [gate])
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(enumeration: enumeration, restorer: restorer)
        let session = session(authority: LeaseFanAuthority(lease: authority))
        _ = await session.hello(payload: try helloPayload())

        let payload = try leasePayload(fanIndices: [0])
        let acquiring = Task { await session.acquireLease(payload: payload) }

        // The acquisition is now suspended inside the enumeration, which is what makes this
        // the in-flight ordering rather than the arrival one.
        await gate.entered.wait()
        await session.invalidate()
        await gate.release.signal()

        let reply = await acquiring.value

        #expect(await authority.leaseCount == 0, "a lease was bound to a dead connection")
        #expect(reply.fault == Self.inFlight)
        #expect(
            reply.fault != Self.arrivedAfterTeardown,
            "the session's arrival gate is not what refused this, and cannot be")
        #expect(await authority.holdsTombstone(for: session.id))
        #expect(await restorer.restores.isEmpty, "nothing was ever held, so nothing was put back")
    }

    /// The same guard, driven straight at the authority with no session in the picture.
    ///
    /// It is the authority's job because binding is the authority's act — #95's first
    /// bullet. A control plane that called `acquireLease` directly would get the same answer.
    @Test("The authority refuses the binding on its own, with no session involved")
    func authorityRefusesWithoutASession() async throws {
        let authority = LeaseFixture.authority()
        let connection = ConnectionID()

        await authority.connectionDidInvalidate(connection)

        await #expect(throws: Self.inFlight) {
            _ = try await authority.acquireLease(LeaseFixture.request(), from: connection)
        }
        #expect(await authority.leaseCount == 0)
    }

    /// **Statement order inside `connectionDidInvalidate` is the guard here, not a check.**
    ///
    /// The handler records the tombstone and empties the table synchronously, and only then
    /// awaits the restore. This pins that: an `acquireLease` is released from its suspension
    /// *while the invalidation is parked inside `FanRestoring`*, and must still be refused.
    ///
    /// Move `tombstones.record` below the restore loop and this goes red while every other
    /// test in the file stays green — which is precisely why it exists. The primary test
    /// above runs `invalidate()` to completion before releasing the acquisition, so it
    /// cannot see the ordering at all.
    @Test("The tombstone is recorded before the release suspends")
    func tombstoneIsRecordedBeforeTheReleaseSuspends() async throws {
        let gate = ScriptedFanEnumeration.Gate()
        // The first acquisition passes straight through; the second is held.
        let enumeration = ScriptedFanEnumeration(indices: [0, 1], gates: [nil, gate])
        let restoring = AsyncSignal()
        let finishRestore = AsyncSignal()
        let restorer = RecordingFanRestorer(entered: restoring, release: finishRestore)
        let authority = LeaseFixture.authority(enumeration: enumeration, restorer: restorer)
        let connection = ConnectionID()

        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: connection)

        let second = Task { () -> (any Error)? in
            do {
                _ = try await authority.acquireLease(
                    LeaseFixture.request(fans: [1]), from: connection)
                return nil
            } catch {
                return error
            }
        }
        await gate.entered.wait()

        let invalidating = Task { await authority.connectionDidInvalidate(connection) }
        // The invalidation is now suspended inside the restore, having already recorded its
        // tombstone and emptied the table — or, if the ordering were wrong, having recorded
        // nothing yet.
        await restoring.wait()

        await gate.release.signal()
        let refusal = await second.value

        await finishRestore.signal()
        await invalidating.value

        #expect(refusal as? AeolusXPCFault == Self.inFlight)
        #expect(await authority.leaseCount == 0, "a lease was bound during the teardown")
        #expect(await restorer.causes == [.connectionInvalidated])
    }

    /// The gate `HelperConnectionSession` already had is unchanged and still fires, so the
    /// arrival ordering is refused before the authority is reached at all. Defence in depth,
    /// per #95: *"Do not remove it as redundant once the authority-side check exists."*
    @Test("The session still refuses a lease request that arrives after teardown")
    func sessionGateStillCoversTheArrivalOrdering() async throws {
        let enumeration = ScriptedFanEnumeration(indices: [0, 1])
        let authority = LeaseFixture.authority(enumeration: enumeration)
        let session = session(authority: LeaseFanAuthority(lease: authority))
        _ = await session.hello(payload: try helloPayload())
        await session.invalidate()

        let reply = await session.acquireLease(payload: try leasePayload(fanIndices: [0]))

        #expect(reply.fault == Self.arrivedAfterTeardown)
        #expect(await authority.leaseCount == 0)
        // The authority was never asked, which is the property the session gate exists for
        // and the one a refusal alone cannot demonstrate.
        #expect(await enumeration.callCount == 0)
    }
}

/// The bounded ledger of dead connections.
@Suite("Connection tombstones")
struct ConnectionTombstoneTests {

    /// A duplicate must not take a second place in the eviction order either. A set that
    /// merely de-duplicated its membership would still shed one live tombstone early for
    /// every duplicate it had ever been handed, and shedding a tombstone is what reopens
    /// #95's race — so this checks the ordering, not only the count.
    @Test("Recording the same connection twice grows neither the set nor the eviction order")
    func recordingIsIdempotent() {
        var tombstones = ConnectionTombstones(capacity: 3)
        let first = ConnectionID()
        let others = (0..<3).map { _ in ConnectionID() }

        #expect(tombstones.record(first) == nil)
        #expect(tombstones.record(first) == nil)
        #expect(tombstones.count == 1)
        #expect(tombstones.contains(first))

        #expect(tombstones.record(others[0]) == nil)
        #expect(tombstones.record(others[1]) == nil)
        #expect(tombstones.count == 3)

        // The fourth distinct connection evicts the first, once.
        #expect(tombstones.record(others[2]) == first)
        #expect(tombstones.count == 3)
        #expect(tombstones.contains(first) == false)
        for other in others {
            #expect(tombstones.contains(other))
        }

        // And the eviction after that takes the next-oldest *live* tombstone. This step is
        // what actually catches a duplicated eviction slot: without it, a set that appended
        // the duplicate still passes everything above, and only reveals itself one eviction
        // later by shedding a stale entry, keeping a live one, and growing past its cap.
        let fifth = ConnectionID()
        #expect(tombstones.record(fifth) == others[0])
        #expect(tombstones.count == 3)
        #expect(tombstones.contains(others[0]) == false)
        #expect(tombstones.contains(others[1]))
        #expect(tombstones.contains(others[2]))
        #expect(tombstones.contains(fifth))
    }

    /// The bound is the whole point: unbounded, a scripted client reconnecting once a second
    /// grows a root daemon's memory for as long as the machine is up.
    @Test("The set is bounded, and evicts oldest first")
    func evictsOldestFirst() {
        var tombstones = ConnectionTombstones(capacity: 3)
        let connections = (0..<4).map { _ in ConnectionID() }

        for connection in connections.prefix(3) {
            #expect(tombstones.record(connection) == nil)
        }
        #expect(tombstones.count == 3)

        #expect(tombstones.record(connections[3]) == connections[0])
        #expect(tombstones.count == 3, "the set grew past its capacity")
        #expect(tombstones.contains(connections[0]) == false)
        for connection in connections.dropFirst() {
            #expect(tombstones.contains(connection))
        }
    }

    /// **The consequence of eviction, written down as a test rather than only as a comment.**
    ///
    /// An evicted tombstone reopens #95's race for that one `ConnectionID`. This asserts the
    /// reopening, because the alternative — leaving it implicit — is how a documented,
    /// accepted risk quietly becomes an undocumented one.
    ///
    /// It is bounded by the TTL: the lease below has no live client and can never be
    /// renewed, so the supervisor restores its fans within its remaining lifetime. That
    /// bound holds **only while self-renewal is refused**, which is why
    /// `LeaseAuthority.acquireLease` refuses it and why enabling it must revisit this
    /// eviction in the same change.
    @Test("An evicted tombstone reopens the race, and the TTL is what bounds it")
    func evictionReopensTheRaceAndTheTimeToLiveBoundsIt() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(
            restorer: restorer, clock: clock, tombstoneCapacity: 1)
        let dead = ConnectionID()

        await authority.connectionDidInvalidate(dead)
        #expect(await authority.holdsTombstone(for: dead))

        // One more dead connection is enough to forget the first.
        await authority.connectionDidInvalidate(ConnectionID())
        #expect(await authority.holdsTombstone(for: dead) == false)

        // So the refusal no longer happens, and a lease binds to a connection that is gone.
        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: dead)
        #expect(await authority.leaseCount == 1)
        #expect(lease.isSelfRenewing == false, "the TTL backstop below depends on this")

        // And the TTL is what recovers it, within the lease's remaining lifetime.
        clock.advance(by: .seconds(30))
        await authority.expireLapsedLeases()

        #expect(await authority.leaseCount == 0)
        #expect(await restorer.causes == [.leaseExpired])
    }

    @Test("The shipped capacity is the one the design was argued for")
    func defaultCapacityIsFourThousandAndNinetySix() {
        #expect(ConnectionTombstones.defaultCapacity == 4_096)
    }

    /// A capacity below one would evict what it just inserted and refuse nothing, which is a
    /// safety mechanism that silently does not run. Clamped rather than trapped: a root
    /// daemon does not abort over a configuration value.
    @Test("A nonsensical capacity still remembers something", arguments: [0, -1])
    func capacityIsClampedToAtLeastOne(_ capacity: Int) {
        var tombstones = ConnectionTombstones(capacity: capacity)
        let connection = ConnectionID()

        tombstones.record(connection)

        #expect(tombstones.contains(connection))
    }
}
