import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// The lease semantics `AeolusXPCProtocol` wrote down so that an implementation could not
/// get them wrong without visibly contradicting the boundary it implements.
@Suite("The lease contract")
struct LeaseContractTests {

    // MARK: - Self-renewal

    /// A self-renewing lease survives connection death, so its only teardowns are an
    /// explicit release, the safety supervisor, and a helper-side liveness policy. **The TTL
    /// does not backstop it**, because the helper is the one renewing it. Its entire safety
    /// story is helper restart plus startup reconciliation
    /// ([#103](https://github.com/blamechris/Aeolus/issues/103)), which is not
    /// hardware-verified — so it is refused rather than granted on an assumed mechanism.
    ///
    /// Refused with an additive `ManualControlAvailability.Reason`, which
    /// `AeolusXPCVersion`'s bump policy permits within v1 because `Reason(wireValue:)` is
    /// forward-tolerant by construction. `AeolusXPCVersion.current` stays 1.
    @Test("A self-renewing lease is refused")
    func selfRenewalIsRefused() async throws {
        let enumeration = ScriptedFanEnumeration()
        let authority = LeaseFixture.authority(enumeration: enumeration)

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .selfRenewalNotBuilt)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(isSelfRenewing: true), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
        // Refused before the machine is asked anything: the request cannot be granted
        // whatever the hardware says, so nothing should have been read to find that out.
        #expect(await enumeration.callCount == 0)
    }

    /// The refusal is additive vocabulary, not a protocol change.
    @Test("Refusing self-renewal needs no protocol bump")
    func selfRenewalRefusalIsForwardTolerant() {
        #expect(AeolusXPCVersion.current == 1)
        let reason = ManualControlAvailability.Reason(wireValue: "selfRenewalNotBuilt")
        #expect(reason == .selfRenewalNotBuilt)
        // An older peer, which has never heard of it, renders it generically rather than
        // failing to decode — the property the refusal relies on.
        #expect(
            ManualControlAvailability.Reason(wireValue: "somethingFromAFutureHelper")
                == .unknown("somethingFromAFutureHelper"))
    }

    /// A lease this helper issues can never claim to be self-renewing, because there is no
    /// path that grants one.
    @Test("A granted lease never reports itself as self-renewing")
    func grantedLeaseIsNeverSelfRenewing() async throws {
        let authority = LeaseFixture.authority()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(), from: ConnectionID())

        #expect(lease.isSelfRenewing == false)
    }

    // MARK: - A lease is bound to its connection

    /// *"A lease is bound to the connection that acquired it. A valid lease ID presented on
    /// a different connection is refused with
    /// `AeolusXPCFault.leaseNotHeldByThisConnection`, not honoured."*
    @Test("A valid lease ID on another connection is refused, for every operation")
    func leaseIsBoundToItsConnection() async throws {
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer)
        let holder = ConnectionID()
        let stranger = ConnectionID()

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: holder)

        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            _ = try await authority.renewLease(id: lease.id, from: stranger)
        }
        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            try await authority.releaseLease(id: lease.id, from: stranger)
        }
        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            _ = try await authority.heldLease(id: lease.id, from: stranger)
        }

        // The lease is untouched: still held, still ending when it always was.
        #expect(await authority.leaseCount == 1)
        #expect(await restorer.restores.isEmpty)
    }

    /// The refusal must not quietly renew the lease on the way past. A stranger extending
    /// somebody else's lease would be the "refused but acted on anyway" shape, which a
    /// thrown error alone cannot rule out.
    @Test("A refused renewal from another connection does not extend the lease")
    func refusedRenewalDoesNotExtend() async throws {
        let clock = TestClock()
        let authority = LeaseFixture.authority(clock: clock)
        let holder = ConnectionID()
        let lease = try await authority.acquireLease(
            LeaseFixture.request(timeToLive: 30), from: holder)

        clock.advance(by: .seconds(20))
        await #expect(throws: AeolusXPCFault.leaseNotHeldByThisConnection) {
            _ = try await authority.renewLease(id: lease.id, from: ConnectionID())
        }

        clock.advance(by: .seconds(10))
        await authority.expireLapsedLeases()
        #expect(await authority.leaseCount == 0, "the stranger's attempt bought the lease time")
    }

    // MARK: - One lease at a time

    /// `FanAuthority.snapshot()` takes no `ConnectionID` and `SystemSnapshot.activeLease` is
    /// a single optional `Lease`, so the lease a snapshot reports is one global fact with
    /// one slot. A second concurrent lease would be invisible to every client including its
    /// own holder, so it is refused rather than misreported.
    @Test("A second connection cannot take control while one holds it")
    func onlyOneLeaseAtATime() async throws {
        let authority = LeaseFixture.authority()
        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0]), from: ConnectionID())

        await #expect(
            throws: AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient)
        ) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [1]), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 1)
    }

    /// And the slot frees up the moment the first lease lapses, without anyone asking. A
    /// lapsed lease that kept blocking new ones would turn a crashed client into a machine
    /// nobody can control until the helper restarts.
    @Test("An expired lease does not keep blocking the next one")
    func expiredLeaseStopsBlocking() async throws {
        let clock = TestClock()
        let restorer = RecordingFanRestorer()
        let authority = LeaseFixture.authority(restorer: restorer, clock: clock)
        _ = try await authority.acquireLease(
            LeaseFixture.request(fans: [0], timeToLive: 30), from: ConnectionID())

        clock.advance(by: .seconds(30))
        let second = try await authority.acquireLease(
            LeaseFixture.request(fans: [1], timeToLive: 30), from: ConnectionID())

        #expect(await authority.leaseCount == 1)
        #expect(await authority.activeLease()?.id == second.id)
        // The first lease's fans went back before the second took any: acquiring sweeps
        // before it registers, so the two never overlap.
        #expect(await restorer.restores == [.init(fans: [0], cause: .leaseExpired)])
    }

    // MARK: - Helper-side validation

    /// Client-side validation is a courtesy; helper-side validation is the control
    /// (`CLAUDE.md` rule 7). The listener checks the TTL, and so does this — because this is
    /// also reachable from the control plane, which is not the listener.
    @Test("A TTL outside the grantable range is refused here too, not only at the listener")
    func timeToLiveIsRevalidated() async throws {
        let enumeration = ScriptedFanEnumeration()
        let authority = LeaseFixture.authority(enumeration: enumeration)

        await #expect(throws: (any Error).self) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(timeToLive: 600), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
        #expect(await enumeration.callCount == 0)
    }

    /// The fan set is checked against what this machine enumerated, which `FanAuthority`
    /// puts on the authority side deliberately: shipping the set up to the listener on every
    /// message would be a time-of-check/time-of-use gap on the one input that decides which
    /// fans a lease may cover.
    @Test("A lease naming a fan this machine does not have is refused")
    func fanIndicesAreCheckedAgainstTheMachine() async throws {
        let authority = LeaseFixture.authority(
            enumeration: ScriptedFanEnumeration(indices: [0, 1]))

        await #expect(throws: (any Error).self) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(fans: [0, 7]), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    /// A machine that cannot say which fans it has cannot have a lease taken over them.
    /// Refused, never guessed at.
    @Test("A lease is refused when the fans cannot be enumerated at all")
    func enumerationFailureRefusesTheLease() async throws {
        let authority = LeaseFixture.authority(
            enumeration: ScriptedFanEnumeration(
                failure: FakeProviderError(description: "no SMC")))

        await #expect(throws: FakeProviderError(description: "no SMC")) {
            _ = try await authority.acquireLease(
                LeaseFixture.request(), from: ConnectionID())
        }
        #expect(await authority.leaseCount == 0)
    }

    // MARK: - What a granted lease says

    @Test("A granted lease reports the holder, the TTL, and a display expiry")
    func grantedLeaseDescribesItself() async throws {
        let wallClock = TestWallClock()
        let authority = LeaseFixture.authority(wallClock: wallClock)

        let lease = try await authority.acquireLease(
            LeaseFixture.request(fans: [0, 1], timeToLive: 45, holder: "fanctl"),
            from: ConnectionID()
        )

        #expect(lease.holderDescription == "fanctl")
        #expect(lease.timeToLive == 45)
        #expect(lease.expiresAt == wallClock.current.addingTimeInterval(45))
        #expect(await authority.activeLease() == lease)
    }
}
