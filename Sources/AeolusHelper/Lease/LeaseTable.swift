import AeolusXPC
import FanKit
import Foundation

/// One lease, as the helper holds it.
///
/// The two time fields are not redundant and are not interchangeable.
///
/// - `deadline` is on the monotonic timeline and is **the only value expiry is ever judged
///   against**.
/// - `expiresAt` is a wall-clock `Date` that exists solely to be rendered in the `Lease`
///   DTO. Nothing in this file compares it to anything.
///
/// Keeping both on one type, adjacent, with this comment between them, is deliberate: the
/// mistake ADR 0005 legislates against is not "somebody could not find the monotonic
/// instant", it is "somebody reached for the obvious `Date` because it was right there".
struct LeaseRecord: Sendable, Hashable {

    let id: UUID
    /// The connection this lease is bound to. A valid lease ID presented on any other
    /// connection is refused — `AeolusXPCProtocol`'s lease contract, verbatim.
    let connection: ConnectionID
    /// The client's own account of itself. Validated by
    /// `AeolusXPCValidation.validateHolderDescription(_:)` before it ever reaches here, so
    /// it is safe for a log line — validated is still not verified.
    let holderDescription: String
    let fanIndices: Set<Int>
    let timeToLive: TimeInterval

    /// Monotonic. Enforcement reads this and nothing else.
    var deadline: ContinuousClock.Instant
    /// Wall clock. Display-grade, carried to the client, never compared here.
    var expiresAt: Date

    /// The DTO for this entry.
    func asLease() -> Lease {
        Lease(
            id: id,
            holderDescription: holderDescription,
            expiresAt: expiresAt,
            timeToLive: timeToLive,
            // v1 refuses self-renewal at acquisition, so no entry can carry `true` and a
            // lease this helper hands back can never claim otherwise.
            isSelfRenewing: false
        )
    }

    /// Whether this lease has lapsed as of `instant` on the monotonic timeline.
    ///
    /// `>=` rather than `>`: a lease whose deadline is exactly now has had its full TTL.
    func hasLapsed(asOf instant: ContinuousClock.Instant) -> Bool {
        instant >= deadline
    }
}

/// The lease table.
///
/// ## In-memory only, deliberately — do not add persistence
///
/// There is no file, no `UserDefaults` key, no cache, and no restart hand-off here, and
/// none may be added as a convenience.
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) rejected persisted lease state
/// outright: *"a lease that survives its enforcer's death is a setting wearing a lease's
/// name"*, and `docs/SAFETY.md` §1 already says what keeps the fans under control is *"a
/// live supervised process, not a value written to disk"*. Persisting this table would
/// invert the central claim of the project's most important safety mechanism.
///
/// The thing persistence looks like it would buy — a helper that crashed while a fan was
/// manual putting it back — is bought instead by **unconditional startup reconciliation**
/// (E5.4, [#103](https://github.com/blamechris/Aeolus/issues/103)): on every start, before
/// serving anything, the helper reads fan mode state and restores any fan found in manual
/// with no live lease. That covers helper crash, `SIGKILL`, kernel panic, power loss and
/// reboot uniformly, and it needs no stored lease to do it.
///
/// ## A value type, not an actor
///
/// The table holds no reference to anything and performs no I/O, so it is a `struct` and
/// the concurrency question is answered one level up: `LeaseAuthority` owns the only
/// instance and is an actor. That split keeps every mutation here synchronous, which is
/// what lets the authority remove entries and register new ones without a suspension point
/// in between — the property [#95](https://github.com/blamechris/Aeolus/issues/95)'s fix
/// rests on.
struct LeaseTable: Sendable {

    private var entries: [UUID: LeaseRecord] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// The entries this table holds, ordered by deadline, for diagnostics and tests.
    var all: [LeaseRecord] {
        entries.values.sorted { $0.deadline < $1.deadline }
    }

    /// The earliest deadline in the table, or `nil` when it is empty. What the TTL
    /// supervisor sleeps until.
    var earliestDeadline: ContinuousClock.Instant? {
        entries.values.map(\.deadline).min()
    }

    func entry(id: UUID) -> LeaseRecord? { entries[id] }

    mutating func insert(_ entry: LeaseRecord) {
        entries[entry.id] = entry
    }

    @discardableResult
    mutating func remove(id: UUID) -> LeaseRecord? {
        entries.removeValue(forKey: id)
    }

    mutating func removeAll() -> [LeaseRecord] {
        let removed = all
        entries.removeAll()
        return removed
    }

    /// Removes every lease that has lapsed as of `instant`, and returns them.
    ///
    /// **Not factored together with `removeAll(heldBy:)`, on purpose.** The two selectors
    /// look alike enough that a shared `removeAll(where:)` is the obvious tidy-up, and
    /// ADR 0005 is the reason not to make it: the TTL and connection death must be two
    /// mechanisms, *"they share no code path"*, and a single predicate-driven remover is
    /// the first step towards one mechanism wearing two names. The duplication is four
    /// lines and it is load-bearing.
    mutating func removeLapsed(asOf instant: ContinuousClock.Instant) -> [LeaseRecord] {
        var lapsed: [LeaseRecord] = []
        for entry in all where entry.hasLapsed(asOf: instant) {
            entries.removeValue(forKey: entry.id)
            lapsed.append(entry)
        }
        return lapsed
    }

    /// Removes every lease bound to `connection`, and returns them.
    ///
    /// See `removeLapsed(asOf:)` for why this is written out rather than shared with it.
    mutating func removeAll(heldBy connection: ConnectionID) -> [LeaseRecord] {
        var released: [LeaseRecord] = []
        for entry in all where entry.connection == connection {
            entries.removeValue(forKey: entry.id)
            released.append(entry)
        }
        return released
    }
}
