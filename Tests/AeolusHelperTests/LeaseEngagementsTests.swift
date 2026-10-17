import Foundation
import Testing

@testable import AeolusHelper

/// `LeaseEngagements`, level 6's account of which fans it engaged under which lease, as a value:
/// the engaged set, the authority for "this lease has engaged the fan" (ADR 0014's A6 PR-2
/// amendment).
@Suite("Level 6's engaged set, as a value", .timeLimit(.minutes(1)))
struct LeaseEngagementsTests {

    let older = UUID()
    let newer = UUID()

    /// A fan engaged under a lease is engaged under that lease and no other.
    @Test("A fan is engaged under the lease it was engaged under, and no other")
    func aFanIsEngagedUnderItsOwnLease() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        #expect(engagements.contains(0, under: older))
        #expect(engagements.contains(0, under: newer) == false)
        #expect(engagements.contains(1, under: older) == false)
    }

    /// The first engagement under a newer lease drops every older lease's fans: one live lease
    /// covers a fan at a time, so a lease that engages has outlived the others.
    ///
    /// **Mutation:** delete the `filter` from `insert(_:under:)`. Run: red on the older lease's
    /// entry, which stays for the life of the process.
    @Test("The first engagement under a newer lease drops every older lease's fans")
    func aNewerLeasesEngagementDropsTheOlders() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.insert(1, under: older)
        engagements.insert(0, under: newer)
        #expect(engagements.contains(0, under: older) == false)
        #expect(engagements.contains(1, under: older) == false)
        #expect(engagements.contains(0, under: newer))
        #expect(engagements.leases == [newer])
    }

    /// What an `apply` under an ended lease can do to the account, which is ask, and hand back
    /// what it engaged: neither touches the newer lease's fans. Its engagement cannot land,
    /// because its driver's entitlement refuses it, so it cannot drop them either.
    ///
    /// **Mutation:** make `remove(_:under:)` remove the fan under every lease. Run: red.
    @Test("A hand-back under an ended lease leaves a newer lease's account alone")
    func anEndedLeasesHandBackLeavesTheNewer() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: newer)
        engagements.remove(0, under: older)
        #expect(engagements.contains(0, under: newer), "an ended lease's undo erased a newer one's")
        #expect(engagements.contains(0, under: older) == false)
    }

    /// A hand-back removes the fan, and a lease left with none is forgotten.
    ///
    /// **Mutation:** delete the empty-set clean-up from `remove(_:under:)`. Run: red.
    @Test("A hand-back removes the fan, and an emptied lease is forgotten")
    func aHandBackRemovesTheFan() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.insert(1, under: older)
        engagements.remove(0, under: older)
        #expect(engagements.contains(0, under: older) == false)
        #expect(engagements.contains(1, under: older))
        engagements.remove(1, under: older)
        #expect(engagements.leases.isEmpty)
    }
}
