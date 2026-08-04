import Foundation

/// The `ConnectionID`s this helper has seen die.
///
/// ## What it is for
///
/// [#95](https://github.com/blamechris/Aeolus/issues/95): `HelperConnectionSession`'s
/// teardown gate refuses a message that *arrives* after `invalidate()`, and structurally
/// cannot refuse one already **in flight** — it is an actor, so the gate is a synchronous
/// check before an `await`, and invalidation can run on the same actor during that
/// suspension. The message then resumes and binds a lease to a `ConnectionID` whose
/// connection-death teardown has already run and will never run again, leaving the TTL
/// alone where ADR 0005 promises two independent paths.
///
/// Binding is the authority's act, so the refusal has to be the authority's too. This is
/// the ledger that makes it possible, and `LeaseAuthority` re-checks it **after its last
/// suspension point, immediately before registering**. A check before a suspension is not a
/// check.
///
/// The session-side gate stays. It is cheap, it costs nothing on the hot path, and it stops
/// a post-teardown message from being decoded and dispatched at all. Two mechanisms
/// covering two interleavings is the shape ADR 0005 asks for, not redundancy to tidy away.
///
/// ## Why it is bounded, and what the bound costs
///
/// Unbounded, a scripted client reconnecting once a second grows a **root daemon's**
/// memory for as long as the machine is up. So the set is capped and evicts oldest-first,
/// with every eviction logged.
///
/// **Eviction is safe only because v1 refuses self-renewing leases.** Evicting a tombstone
/// reopens #95's race for that one `ConnectionID`, and the worst case it can produce is a
/// lease bound to a dead connection: no client is alive to renew it, no further
/// invalidation will fire for it, and the TTL therefore restores the fans within the
/// lease's remaining lifetime — 30 seconds by default, 120 at the outside.
///
/// **Self-renewal is the one configuration where the TTL does not backstop.** A
/// helper-renewed lease never lapses, so the same evicted-tombstone race would pin fans
/// indefinitely with no live holder and nothing left to notice.
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) states the coupling and this
/// comment repeats it where the code is: **enabling self-renewal must revisit this eviction
/// in the same change.** `LeaseAuthority` refuses `isSelfRenewing` today, which is what
/// makes the paragraph above true rather than hopeful.
///
/// ## Cost of the eviction itself
///
/// Oldest-first over an `Array`, so an eviction is an O(*capacity*) move of 4096 UUIDs —
/// tens of microseconds, paid only once a connection has died and only once the cap is
/// reached. A ring buffer would make it O(1) and would be hand-rolled index arithmetic in a
/// root daemon to save time nobody is waiting for. Connection deaths happen at human speed.
struct ConnectionTombstones: Sendable {

    /// How many dead connections are remembered.
    ///
    /// Sized so that the realistic client population — an app, a CLI invocation or two —
    /// never approaches it, while a scripted reconnect loop is bounded at roughly 64 KB.
    /// A machine would have to die and reconnect 4096 times before any tombstone is
    /// evicted, and every eviction says so in the log.
    static let defaultCapacity = 4_096

    private let capacity: Int
    private var members: Set<ConnectionID> = []
    /// Oldest first. Parallel to `members`, which is what makes `contains` O(1) while
    /// eviction stays ordered.
    private var order: [ConnectionID] = []

    init(capacity: Int = ConnectionTombstones.defaultCapacity) {
        // A capacity below 1 would make `record` evict what it just inserted and hand back
        // a set that refuses nothing, which is a safety mechanism that silently does not
        // run. Clamped rather than trapped: a root daemon does not abort over a
        // configuration value, and one is the smallest set that still refuses something.
        self.capacity = max(1, capacity)
    }

    var count: Int { members.count }

    func contains(_ connection: ConnectionID) -> Bool {
        members.contains(connection)
    }

    /// Records a dead connection, evicting the oldest if the set is full.
    ///
    /// Idempotent: recording a connection already present neither duplicates it nor moves
    /// it to the back of the eviction order. `HelperConnectionSession.invalidate()` is
    /// itself idempotent, but a teardown that a double call would corrupt is not one a root
    /// daemon should depend on being called exactly once.
    ///
    /// - Returns: The connection evicted to make room, or `nil` if none was.
    @discardableResult
    mutating func record(_ connection: ConnectionID) -> ConnectionID? {
        guard members.insert(connection).inserted else { return nil }
        order.append(connection)

        guard members.count > capacity else { return nil }
        let evicted = order.removeFirst()
        members.remove(evicted)
        return evicted
    }
}
