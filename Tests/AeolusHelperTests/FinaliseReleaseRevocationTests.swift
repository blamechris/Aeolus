import Testing

@testable import AeolusHelper

/// #353: the terminal action revokes the lease it was holding the fan for, in the composed helper.
/// Kept out of `FinaliseReleaseLedgerTests.swift`, which is at SwiftLint's `file_length` and its
/// suite at `type_body_length`, as an extension of the same suite: it drives the same composed
/// interference fixture, whose helpers are internal for the purpose rather than copied.
extension FinaliseReleaseLedgerTests {

    /// The terminal action revokes the lease it was holding the fan for, and no other (#353).
    ///
    /// Inside § 5's hand-back the holder releases its lease — the lease core restores through
    /// the bound `HelperFanRestorer`, which tells § 5 — and a new client is granted fan 0. The
    /// terminal action used to revoke every lease, so the new client lost a lease it had just
    /// been granted, told the system had taken a fan it never held. Composed, because the
    /// release notice and its ordering are the shipping restorer's.
    ///
    /// `LeaseLog` has no recording sink, so the revocation that must not happen is observed
    /// where it would land: the table, and a third restore of fan 0 through the restorer.
    ///
    /// **Mutation:** replace the `revokeLease(id:because:)` guard in
    /// `ReclamationWatchdog.finaliseRelease(fanAt:heldUnder:because:)` with
    /// `await leases.revokeEveryLease(because: cause)`. Run: red on the new lease, the count,
    /// the restores and the notice.
    @Test("The terminal action revokes only the lease it held the fan for")
    func theTerminalActionRevokesOnlyTheLeaseItHeldTheFanFor() async throws {
        let held = try await Self.holdingThroughInterference()
        let leases = held.helper.leases
        let holder = held.holder
        let lease = held.lease
        let granted = GrantedLeases()
        await held.plane.interfere {
            do {
                try await leases.releaseLease(id: lease, from: holder)
                let next = try await leases.acquireLease(
                    LeaseFixture.request(fans: [0]), from: ConnectionID())
                await granted.record(next.id)
            } catch {
                Issue.record("the release and re-grant inside the hand-back failed: \(error)")
            }
        }

        await Self.cycleToTheTerminalAction(held.helper)

        #expect(await held.plane.didFire, "nothing was released inside the hand-back")
        #expect(
            held.log.lines(containing: "no speed to re-assert").count == 1,
            "§ 5 never reached its terminal action, so nothing here was tested")
        let next = try #require(await granted.ids.first, "the re-grant never happened")
        #expect(
            await leases.activeLease()?.id == next,
            "the terminal action revoked a lease granted after the one it held the fan for")
        #expect(await leases.leaseCount == 1)
        #expect(
            await Self.restoresOfFanZero(on: held.scripted).count == 2,
            "the hand-back and the release's restore, and no revocation's restore after them")
        #expect(held.log.lines(containing: "had already ended").count == 1)
    }
}
