import Foundation
import Testing

@testable import AeolusHelper

/// `LeaseEngagements`, level 6's account of which fans it holds under which lease, as a value: the
/// authority for "this lease has engaged the fan" (ADR 0014's A6 PR-2 amendment), with the two
/// accounts the #410 refused-hand-back amendment gives it, `.engaged` and `.handBackRefused`.
@Suite("Level 6's accounts, as a value", .timeLimit(.minutes(1)))
struct LeaseEngagementsTests {

    let older = UUID()
    let newer = UUID()

    /// A fan engaged under a lease is engaged under that lease and no other.
    @Test("A fan is engaged under the lease it was engaged under, and no other")
    func aFanIsEngagedUnderItsOwnLease() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        #expect(engagements.account(of: 0, under: older) == .engaged)
        #expect(engagements.account(of: 0, under: newer) == nil)
        #expect(engagements.account(of: 1, under: older) == nil)
    }

    /// **The two accounts.** `insert` opens `.engaged` and `keep` `.handBackRefused`, each over
    /// whatever the fan held before, and `remove` closes either: an engagement that returns, a
    /// hand-back refused after it, a re-adoption of the kept fan, and a hand-back that returns.
    ///
    /// **Mutation:** make `keep(_:under:)` open `.engaged`. Run: red on the kept account.
    /// **Mutation:** make `remove(_:under:)` close only an `.engaged` fan. Run: red on the last.
    @Test("insert opens .engaged, keep opens .handBackRefused, and remove closes either")
    func theTwoAccounts() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.keep(0, under: older)
        #expect(engagements.account(of: 0, under: older) == .handBackRefused)
        engagements.insert(0, under: older)
        #expect(engagements.account(of: 0, under: older) == .engaged)
        engagements.keep(0, under: older)
        engagements.remove(0, under: older)
        #expect(engagements.account(of: 0, under: older) == nil)
        #expect(engagements.leases.isEmpty)
    }

    /// The first engagement under a newer lease drops every older lease's fans, the kept ones
    /// included: one live lease covers a fan at a time, so a lease that engages has outlived the
    /// others, and a fan kept under an ended lease is that lease's teardown's to restore.
    ///
    /// **Mutation:** delete the `filter` from `open(_:for:under:)`. Run: red on the older lease's
    /// entries, which stay for the life of the process.
    @Test("The first engagement under a newer lease drops every older lease's fans, kept or not")
    func aNewerLeasesEngagementDropsTheOlders() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.keep(1, under: older)
        engagements.insert(0, under: newer)
        #expect(engagements.account(of: 0, under: older) == nil)
        #expect(engagements.account(of: 1, under: older) == nil, "a kept fan outlived its lease")
        #expect(engagements.account(of: 0, under: newer) == .engaged)
        #expect(engagements.leases == [newer])
    }

    /// A fan kept under a newer lease drops every older lease's fans too, as an engagement does.
    ///
    /// **Mutation:** in `keep(_:under:)`, set the account without `open(_:for:under:)`'s filter, so
    /// it spares other leases. Run: red here.
    @Test("A fan kept under a newer lease drops every older lease's fans")
    func aNewerLeasesKeepDropsTheOlders() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.keep(1, under: older)
        engagements.keep(0, under: newer)
        #expect(engagements.account(of: 0, under: older) == nil)
        #expect(engagements.account(of: 1, under: older) == nil)
        #expect(engagements.account(of: 0, under: newer) == .handBackRefused)
        #expect(engagements.leases == [newer], "keep spared another lease's account")
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
        #expect(
            engagements.account(of: 0, under: newer) == .engaged,
            "an ended lease's undo erased a newer one's")
        #expect(engagements.account(of: 0, under: older) == nil)
    }

    /// A hand-back removes the fan, and a lease left with none is forgotten.
    ///
    /// **Mutation:** delete the empty-set clean-up from `remove(_:under:)`. Run: red.
    @Test("A hand-back removes the fan, and an emptied lease is forgotten")
    func aHandBackRemovesTheFan() {
        var engagements = LeaseEngagements()
        engagements.insert(0, under: older)
        engagements.keep(1, under: older)
        engagements.remove(0, under: older)
        #expect(engagements.account(of: 0, under: older) == nil)
        #expect(engagements.account(of: 1, under: older) == .handBackRefused)
        engagements.remove(1, under: older)
        #expect(engagements.leases.isEmpty)
    }
}
