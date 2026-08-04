import AeolusXPC
import FanKit
import Foundation

/// The lease core: the table, the two teardown paths, and the ledger of dead connections.
///
/// ## Where this sits
///
/// Behind `FanAuthority`, not on it. Every method below carries a `FanAuthority` signature
/// verbatim, so the helper's control plane composes it with one-line forwards, but this
/// type owns no hardware and produces no `SystemSnapshot`: it cannot enumerate a fan, read a
/// sensor, or write a value. It asks `FanEnumerating` which fans exist and tells
/// `FanRestoring` to put them back, and those are the only two things it needs of the
/// machine.
///
/// That split is what keeps E5.1 fully testable with no hardware and no mock SMC, and it is
/// why this file contains no write of any kind — `SMCConnection.write` is still
/// `package`-scoped and still throws, and no write selector exists anywhere in `Sources/`.
///
/// ## One lease at a time, and why the contract settles it
///
/// `FanAuthority.snapshot()` takes **no `ConnectionID`**, and `SystemSnapshot.activeLease`
/// is a single optional `Lease`. So the lease a snapshot reports is a global fact, identical
/// for every client, and there is exactly one slot for it. Two simultaneous leases — even
/// over disjoint fans — would be unreportable: one of them would be invisible to every
/// client including its own holder, and a client that cannot see who holds the fans cannot
/// tell "nothing is holding this" from "somebody else is". That is `CLAUDE.md` rule 6
/// arriving one step earlier than usual.
///
/// The wire shape is frozen at v1 and shipped, so the choice is between refusing the second
/// lease and misreporting it. This refuses it, with
/// `.manualControlUnavailable(reason: .leaseHeldByAnotherClient)`.
///
/// ## Strict concurrency
///
/// An actor, with every piece of mutable state — the table and the tombstones — inside it,
/// and both are value types so no reference escapes. There is no `@unchecked` conformance
/// anywhere here and none is needed; `CLAUDE.md` rule 10 and this repository's
/// `no_unchecked_sendable_in_helper` rule would both treat one as a claim requiring review.
///
/// **Reentrancy is the hazard here, not data races.** An actor is reentrant across `await`,
/// so every method is written as: suspend for whatever it needs, then decide in one
/// straight-line region containing no `await`. Those regions are marked in the source. The
/// register step in `acquireLease` is the one that matters —
/// [#95](https://github.com/blamechris/Aeolus/issues/95) is precisely what happens when a
/// liveness check and the registration it guards are separated by a suspension point.
actor LeaseAuthority {

    private let clock: any MonotonicClock
    private let wallClock: @Sendable () -> Date
    private let enumeration: any FanEnumerating
    private let restorer: any FanRestoring
    private let log: LeaseLog

    private var table = LeaseTable()
    private var tombstones: ConnectionTombstones

    /// Fans whose restore-to-automatic write is in flight right now, counted rather than
    /// set-membership because the panic path can overlap a teardown on the same fan.
    ///
    /// Removing a lease from the table and completing its restore are not the same instant,
    /// and the actor is reentrant across the `await` between them. Without this, an emptied
    /// table is exactly what lets the next `acquireLease` through — the table being empty is
    /// the *condition* it checks — so a client could take a lease over a fan whose handback
    /// is still on the wire.
    private var releasing: [Int: Int] = [:]

    init(
        enumeration: some FanEnumerating,
        restorer: some FanRestoring,
        clock: some MonotonicClock = SystemMonotonicClock(),
        wallClock: @escaping @Sendable () -> Date = Date.init,
        tombstoneCapacity: Int = ConnectionTombstones.defaultCapacity,
        log: LeaseLog = LeaseLog()
    ) {
        self.enumeration = enumeration
        self.restorer = restorer
        self.clock = clock
        self.wallClock = wallClock
        self.tombstones = ConnectionTombstones(capacity: tombstoneCapacity)
        self.log = log
    }

    // MARK: - Acquisition

    /// Grants manual control of the requested fans, or refuses.
    ///
    /// The order of the steps is the design, so it is worth reading as one:
    ///
    /// 1. **Self-renewal is refused first**, before any work is done for a request that
    ///    cannot be granted whatever the machine says.
    /// 2. The TTL is re-validated here although the listener already checked it. Sharing
    ///    `AeolusXPCValidation` is not the same as the listener doing the checking
    ///    (`CLAUDE.md` rule 7), and this method is reachable from the control plane as well
    ///    as from a message.
    /// 3. The suspension points: enumerating the machine's fans, then sweeping anything
    ///    already lapsed — so the single-lease check below is made against live leases only,
    ///    and a previous lease's fans are back on automatic before new ones are taken.
    /// 4. **The liveness check, after the last suspension point and immediately before
    ///    registering.** Everything from there to the `insert` is straight-line: the actor
    ///    cannot be re-entered between the check and the act it guards.
    ///
    /// **There is deliberately no earlier liveness check.** One would cost a hardware round
    /// trip less in a case `HelperConnectionSession`'s teardown gate already refuses, and it
    /// would buy that with a real hazard: a test could stay green on the early refusal while
    /// the guarded region below was unprotected, which is exactly how a guard survives being
    /// deleted. One check, in the only place a check means anything.
    func acquireLease(
        _ request: LeaseRequest,
        from connection: ConnectionID
    ) async throws -> Lease {
        guard !request.isSelfRenewing else {
            log.refusedSelfRenewal(connection)
            throw AeolusXPCFault.manualControlUnavailable(reason: .selfRenewalNotBuilt)
        }
        try AeolusXPCValidation.validateTimeToLive(request.timeToLive)
        // Re-checked here for the same reason as the TTL above, and it is the field that
        // needs it more: `holderDescription` is client-chosen text that reaches a root
        // daemon's log at `privacy: .public`. A caller arriving from the control plane
        // rather than from a message would otherwise put newlines and bidi overrides into
        // `log show` — the exact harm `validateHolderDescription` exists to prevent.
        try AeolusXPCValidation.validateHolderDescription(request.holderDescription)

        let enumerated = try await enumeration.enumeratedFanIndices()
        await expireLapsedLeases()

        // ---- No `await` below this line. Adding one reopens #95. ----
        try AeolusXPCValidation.validateFanIndices(
            request.fanIndices, enumeratedFanIndices: enumerated)
        try refuseIfInvalidated(connection)
        // The durable refusal is checked first, deliberately. Both can apply at once — a
        // dying holder's fan is mid-handback while a second client legitimately holds
        // another — and `.releaseInProgress` documents itself as "retry in a moment". A
        // client told that, when the real answer is "somebody else holds the fans and will
        // for as long as they live", retries into a different refusal forever.
        guard table.isEmpty else {
            log.refusedConcurrentLease(connection)
            throw AeolusXPCFault.manualControlUnavailable(reason: .leaseHeldByAnotherClient)
        }
        let midHandback = request.fanIndices.filter { releasing[$0] != nil }
        guard midHandback.isEmpty else {
            log.refusedMidHandback(connection, fans: Set(midHandback))
            throw AeolusXPCFault.manualControlUnavailable(reason: .releaseInProgress)
        }

        let entry = LeaseRecord(
            id: UUID(),
            connection: connection,
            holderDescription: request.holderDescription,
            fanIndices: Set(request.fanIndices),
            timeToLive: request.timeToLive,
            deadline: clock.now.advanced(by: .seconds(request.timeToLive)),
            expiresAt: wallClock().addingTimeInterval(request.timeToLive)
        )
        table.insert(entry)
        log.granted(
            connection,
            holder: entry.holderDescription,
            fans: entry.fanIndices,
            timeToLive: entry.timeToLive
        )
        return entry.asLease()
    }

    // MARK: - Renewal and voluntary release

    /// Extends a lease this connection holds, or refuses.
    ///
    /// Synchronous from the lookup to the write-back — there is no `await` in the body at
    /// all — so a renewal cannot interleave with a teardown halfway through.
    ///
    /// An expired lease is **re-acquired, never resurrected**, per `AeolusXPCProtocol`: a
    /// client that stopped proving it was alive does not get to carry on as though it never
    /// had. `.leaseExpired` rather than `.leaseUnknown`, because the two are different facts
    /// and only one of them tells the client what to do next.
    func renewLease(id: UUID, from connection: ConnectionID) throws -> Lease {
        var entry = try heldLease(id: id, from: connection)
        entry.deadline = clock.now.advanced(by: .seconds(entry.timeToLive))
        entry.expiresAt = wallClock().addingTimeInterval(entry.timeToLive)
        table.insert(entry)
        log.renewed(connection, timeToLive: entry.timeToLive)
        return entry.asLease()
    }

    /// Drops a lease this connection holds and returns its fans to automatic.
    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        let entry = try heldLease(id: id, from: connection)
        table.remove(id: entry.id)
        await restore(entry.fanIndices, because: .leaseReleased)
    }

    /// The live lease `connection` holds under `id`, or the refusal.
    ///
    /// **Synchronous, and that is the point.** It is what the control plane's `apply` calls
    /// to authorise a write, and [#95](https://github.com/blamechris/Aeolus/issues/95) asks
    /// for the same reasoning to be applied to every method given per-connection state. A
    /// check that can suspend before the act it authorises is not a check — so this one
    /// cannot suspend.
    ///
    /// It does **not** sweep a lapsed lease it finds. Refusing the client and restoring the
    /// fans are different jobs: this refuses, and `LeaseExpirySupervisor` restores, on its
    /// own schedule and without being triggered from here.
    ///
    /// - Note: A caller outside this actor still awaits the hop to reach it, so "authorised"
    ///   and "written" are separated by a suspension the lease core cannot close from here.
    ///   The control plane closes it by keeping the check and the write in one isolated
    ///   region, or by re-checking after the write and restoring if the lease has gone.
    func heldLease(id: UUID, from connection: ConnectionID) throws -> LeaseRecord {
        guard let entry = table.entry(id: id) else { throw AeolusXPCFault.leaseUnknown }
        // Ownership is judged before expiry: a lease bound to another connection is not
        // this client's business at all, and whether it has lapsed is not a fact this
        // client is entitled to learn.
        guard entry.connection == connection else {
            throw AeolusXPCFault.leaseNotHeldByThisConnection
        }
        guard !entry.hasLapsed(asOf: clock.now) else { throw AeolusXPCFault.leaseExpired }
        return entry
    }

    // MARK: - Teardown path 1 of 2: the TTL

    /// Expires every lapsed lease and restores its fans.
    ///
    /// **Takes no instant.** A caller cannot supply one, so no caller can supply a
    /// wall-clock-derived one — ADR 0005's monotonic rule made inexpressible rather than
    /// merely documented, which is the argument `AeolusXPCProtocol` makes for the messages
    /// it does not have.
    ///
    /// **Nothing on the connection-invalidation path calls this, and it calls nothing on
    /// that path.** That is the independence ADR 0005 requires: *"Either mechanism alone
    /// suffices; both must fail for the fans to stay pinned; they share no code path."* The
    /// one thing the two paths do share is their terminal action, and that is deliberate —
    /// ADR 0007's keystone is that restore-to-automatic is a single bounds-free verb every
    /// safety mechanism ends in.
    ///
    /// Entries are removed **before** the restore is awaited, so a call interleaving during
    /// the restore finds an empty table and cannot restore the same fans twice.
    ///
    /// - Warning: That is the whole of what it buys, and the empty table cuts both ways. An
    ///   emptied table is exactly what makes `acquireLease`'s liveness check pass, so a new
    ///   lease **can** be granted over a fan whose restore is still parked inside
    ///   `FanRestoring`. Demonstrated against this code, not theorised. It is harmless today
    ///   because `FanRestoring` has no conformer and nothing writes — but once #102 wires
    ///   the control plane, the losing order is: A's connection dies, A's restore is
    ///   enqueued, B acquires and writes a target, A's restore lands and returns the fan to
    ///   automatic. B then holds a live lease over a fan nothing is honouring, which is
    ///   `CLAUDE.md` rule 6 arriving through a door this comment used to claim was shut.
    ///   **#102 owns the interlock**, and the reclamation watchdog is a backstop for it
    ///   rather than a substitute.
    func expireLapsedLeases() async {
        let lapsed = table.removeLapsed(asOf: clock.now)
        for entry in lapsed {
            await restore(entry.fanIndices, because: .leaseExpired)
        }
    }

    /// When the earliest outstanding lease lapses, or `nil` when none is outstanding. What
    /// `LeaseExpirySupervisor` sleeps until.
    func nextExpiryDeadline() -> ContinuousClock.Instant? { table.earliestDeadline }

    // MARK: - Teardown path 2 of 2: connection death

    /// A connection died: crash, `SIGKILL`, logout, or an orderly disconnect.
    ///
    /// **The tombstone is recorded first, before anything can suspend.** Recording it after
    /// the restore would leave a window in which an `acquireLease` already in flight
    /// resumes, finds no tombstone, and binds a lease to this very connection — #95,
    /// reintroduced by statement order rather than by a missing guard.
    ///
    /// Removing the entries is synchronous too, for the same reason `expireLapsedLeases`
    /// removes before it restores.
    ///
    /// Not throwing and returning nothing, per `FanAuthority`: the connection this concerns
    /// is already gone, so there is nobody a failure could be reported to.
    func connectionDidInvalidate(_ connection: ConnectionID) async {
        if let evicted = tombstones.record(connection) {
            log.evictedTombstone(evicted, capacity: tombstones.count)
        }
        let released = table.removeAll(heldBy: connection)

        for entry in released {
            await restore(entry.fanIndices, because: .connectionInvalidated)
        }
    }

    // MARK: - The panic path

    /// Drops every lease and restores every fan they covered.
    ///
    /// The lease core's half of `restoreAllToAutomatic`. The control plane additionally
    /// restores every enumerated fan, because that message's contract is global rather than
    /// lease-scoped.
    ///
    /// **Consults no per-`ConnectionID` state**, which is the precondition
    /// `HelperConnectionSession` documents for exempting that message from its teardown
    /// gate: `connection` is attribution only, so both post-invalidation orderings converge
    /// on the same safe state. Making this consult per-connection state would invalidate the
    /// exemption and needs revisiting alongside it —
    /// [#95](https://github.com/blamechris/Aeolus/issues/95).
    func releaseEveryLease() async {
        let dropped = table.removeAll()
        for entry in dropped {
            await restore(entry.fanIndices, because: .allLeasesDropped)
        }
    }

    // MARK: - State, for the control plane and for tests

    /// The lease a snapshot reports, sweeping anything lapsed first so a snapshot never
    /// shows a lease that has already stopped holding the fans.
    func activeLease() async -> Lease? {
        await expireLapsedLeases()
        return table.all.first?.asLease()
    }

    var leaseCount: Int { table.count }
    var tombstoneCount: Int { tombstones.count }

    func holdsTombstone(for connection: ConnectionID) -> Bool {
        tombstones.contains(connection)
    }

    // MARK: - Guards

    /// The refusal a message gets when its own connection died while it was in flight.
    ///
    /// Deliberately worded differently from `HelperConnectionSession`'s teardown refusal.
    /// The two guards cover different interleavings — that one covers arrival, this one
    /// covers flight — and a log that cannot tell them apart cannot tell an operator which
    /// half of the mechanism fired. `.helperFailed` for the reason the session picked it:
    /// nothing else in the vocabulary describes this without asserting something false about
    /// the client.
    private static let invalidatedInFlight = AeolusXPCFault.helperFailed(
        detail: "the connection was invalidated while this request was in flight")

    private func refuseIfInvalidated(_ connection: ConnectionID) throws {
        guard tombstones.contains(connection) else { return }
        log.refusedInFlightBinding(connection)
        throw Self.invalidatedInFlight
    }

    /// The one place a restore is issued, and therefore the one place the handback window
    /// can be held open.
    ///
    /// `releasing` is incremented before the suspension and decremented after it, so
    /// `acquireLease` can see the window from inside the actor. Counted rather than a `Set`
    /// so two overlapping restores of the same fan — a teardown and the panic path — cannot
    /// have the first to finish clear a flag the second still needs.
    ///
    /// - Note: **That overlap is unreachable in this build, and the count is therefore not
    ///   load-bearing today.** `guard table.isEmpty` holds the table to a single entry, and
    ///   every teardown path removes its entry synchronously before restoring, so whichever
    ///   path removes first is the only one that restores. Replacing the count with set
    ///   membership passes the whole suite. It is written this way because the overlap
    ///   becomes reachable the moment either of those two facts changes — E5.3's control
    ///   plane issuing a restore outside lease teardown, or the table holding more than one
    ///   lease — and both are cheaper to be already correct for than to retrofit. Recorded
    ///   rather than implied, so nobody simplifies it believing a test is watching.
    private func restore(_ fans: Set<Int>, because cause: FanRestoreCause) async {
        log.restored(fans: fans, because: cause)
        for fan in fans { releasing[fan, default: 0] += 1 }
        defer {
            for fan in fans {
                guard let outstanding = releasing[fan] else { continue }
                releasing[fan] = outstanding > 1 ? outstanding - 1 : nil
            }
        }
        await restorer.restoreToAutomatic(fans: fans, because: cause)
    }
}
