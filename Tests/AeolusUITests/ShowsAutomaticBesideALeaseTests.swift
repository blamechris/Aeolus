import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

/// `SystemSnapshot.showsAutomatic(_:besideLease:covering:)`, ADR 0015 D5's conditions 1 and 3:
/// the snapshot lists exactly the caller's lease, by identifier, and no emergency, no fan asked
/// about is one the lease covers, and every one is cleared.
///
/// Every refusal here meets every other condition: the caller's own lease listed, no emergency,
/// fan 1 outside the lease and cleared, so only the condition under test can refuse it. The
/// positive control shows the predicate say yes on that screen.
@Suite("SystemSnapshot — Automatic beside the caller's own lease (ADR 0015 D5)")
struct ShowsAutomaticBesideALeaseTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport

    /// Fan 0 held under `lease`, fan 1 cleared.
    static func snapshot(listing lease: Lease?, emergency: Bool = false) -> SystemSnapshot {
        Support.snapshot(
            fans: [Fixtures.heldFan(0), Fixtures.clearedFan(1)], activeLease: lease,
            isThermalEmergencyActive: emergency)
    }

    static func fan(_ index: Int, in snapshot: SystemSnapshot) throws -> FanState {
        try #require(snapshot.fans.first { $0.index == index })
    }

    @Test("The caller's lease listed, no emergency, a fan it does not cover, cleared: Automatic")
    func thePositiveControl() throws {
        let snapshot = Self.snapshot(listing: Fixtures.ours)
        let fan1 = try Self.fan(1, in: snapshot)
        #expect(fan1.isClearedToAutomatic)

        #expect(snapshot.showsAutomatic([fan1], besideLease: Fixtures.ours.id, covering: [0]))
        #expect(
            snapshot.showsAutomatic([], besideLease: Fixtures.ours.id, covering: [0]),
            "with no fans, the lease and the emergency alone")
        #expect(!snapshot.showsAutomatic([fan1]), "D4's predicate still refuses a listed lease")
    }

    /// **Mutation (M4a, "any listed lease"):** replace `controlLoss(leaseID:covering: []) == nil`
    /// with `activeLease != nil && !isThermalEmergencyActive`. Run: red for both leases.
    /// The impostor carries the caller's holder string word for word; only its identifier differs.
    @Test(
        "Another lease listed, whatever its holder says: not Automatic",
        arguments: [Fixtures.theirs, Fixtures.impostor])
    func anotherLeaseIsNotTheCallers(_ listed: Lease) throws {
        #expect(listed.id != Fixtures.ours.id)
        let snapshot = Self.snapshot(listing: listed)

        #expect(
            !snapshot.showsAutomatic(
                [try Self.fan(1, in: snapshot)], besideLease: Fixtures.ours.id, covering: [0]))
    }

    /// No lease listed beside a held one: a read from before the grant, or a loss not yet judged.
    /// Neither is evidence about a fan the lease does not cover.
    ///
    /// **Mutation (M4b, "no lease or the caller's"):** replace the `controlLoss` term with
    /// `(activeLease == nil || activeLease?.id == leaseID) && !isThermalEmergencyActive`. Run: red.
    @Test("No lease listed beside a held one: not Automatic")
    func noLeaseListed() throws {
        let snapshot = Self.snapshot(listing: nil)

        #expect(
            !snapshot.showsAutomatic(
                [try Self.fan(1, in: snapshot)], besideLease: Fixtures.ours.id, covering: [0]))
    }

    /// Between § 3 firing and its revocation the lease is still listed, and § 3 decides what the
    /// fans do.
    ///
    /// **Mutation (M6, "no emergency check"):** replace the `controlLoss` term with
    /// `activeLease?.id == leaseID`. Run: red.
    @Test("The caller's lease listed during a thermal emergency: not Automatic")
    func anEmergency() throws {
        let snapshot = Self.snapshot(listing: Fixtures.ours, emergency: true)

        #expect(
            !snapshot.showsAutomatic(
                [try Self.fan(1, in: snapshot)], besideLease: Fixtures.ours.id, covering: [0]))
    }

    /// A fan under the lease whose first `apply` has not landed reads automatic and offered,
    /// exactly as an uncovered one does. Only `covering` tells them apart.
    ///
    /// **Mutation (M5a, "no covering check"):** delete `!covered.contains($0.index) &&`. Run: red
    /// for both fan lists.
    @Test("A fan the lease covers, however cleared it reads: not Automatic")
    func aCoveredFan() throws {
        let snapshot = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)], activeLease: Fixtures.ours)
        #expect(snapshot.fans.allSatisfy { $0.isClearedToAutomatic })

        #expect(
            !snapshot.showsAutomatic(
                [try Self.fan(0, in: snapshot)], besideLease: Fixtures.ours.id, covering: [0]))
        #expect(
            !snapshot.showsAutomatic(snapshot.fans, besideLease: Fixtures.ours.id, covering: [0]),
            "one covered fan among them refuses them all")
    }

    /// A handback in flight, refused or unconfirmed, or a fan another program holds: the helper
    /// has not cleared it.
    ///
    /// **Mutation (M8, "no clearance check"):** delete `&& $0.isClearedToAutomatic`. Run: red for
    /// every argument.
    @Test(
        "A fan outside the lease the helper has not cleared: not Automatic",
        arguments: FanRowModelTests.notClearing)
    func anUnclearedFan(_ reason: ManualControlAvailability.Reason) throws {
        let snapshot = Support.snapshot(
            fans: [
                Fixtures.heldFan(0),
                Support.fan(1, mode: .automatic, availability: .unavailable(reason)),
            ],
            activeLease: Fixtures.ours)
        let fan1 = try Self.fan(1, in: snapshot)
        #expect(!fan1.isClearedToAutomatic, "\(reason)")

        #expect(
            !snapshot.showsAutomatic([fan1], besideLease: Fixtures.ours.id, covering: [0]),
            "\(reason)")
    }
}
