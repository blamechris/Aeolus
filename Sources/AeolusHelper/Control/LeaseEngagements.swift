import Foundation

/// Which fans level 6 has engaged under which lease, and not handed back since: the engaged set,
/// the authority for "this lease has engaged the fan", as a value (ADR 0014's A6 PR-2 amendment).
///
/// Keyed by lease. A fan joins when the driver's engagement returns under that lease, and leaves
/// when the undo's hand-back returns or § 5 answers its report `.notHeld`; one whose hand-back was
/// refused stays. The first engagement under a lease drops every other lease's fans: one live lease
/// covers a fan at a time, so a lease that engages has outlived every other. Dropped when `apply`
/// is authorised instead, a call whose lease ended between `heldLease` answering and its
/// resumption would erase the account of the lease granted since, whose next re-apply would then
/// re-engage its own fans and be refused `.notAutomatic`; a call under an ended lease cannot
/// engage, because its driver's entitlement refuses it. A fan a teardown, § 3 or § 5 handed back
/// under a lease that is still live stays here: #381's one-cycle residual.
struct LeaseEngagements: Sendable {

    private var fans: [UUID: Set<Int>] = [:]

    /// Whether `index` was engaged under `lease` and not handed back since.
    func contains(_ index: Int, under lease: UUID) -> Bool {
        fans[lease]?.contains(index) == true
    }

    /// The leases with a fan engaged, for tests.
    var leases: Set<UUID> { Set(fans.keys) }

    /// An engagement of `index` under `lease` returned.
    mutating func insert(_ index: Int, under lease: UUID) {
        fans = fans.filter { $0.key == lease }
        fans[lease, default: []].insert(index)
    }

    /// `index` was handed back under `lease`.
    mutating func remove(_ index: Int, under lease: UUID) {
        fans[lease]?.remove(index)
        if fans[lease]?.isEmpty == true { fans[lease] = nil }
    }
}
