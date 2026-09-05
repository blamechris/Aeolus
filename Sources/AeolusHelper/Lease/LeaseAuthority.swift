import AeolusXPC
import FanKit
import Foundation

/// The lease core: the table, the two teardown paths, and the ledger of dead connections.
///
/// ## Where this sits
///
/// Behind `FanAuthority`, not on it. Every method below carries a `FanAuthority` signature
/// verbatim, so the helper's control plane composes it with one-line forwards, but this
/// type owns no hardware and produces no `SystemSnapshot`. It asks for exactly three things
/// of the machine, each as a narrow role rather than a control plane:
///
/// - `FanEnumerating` — which fans exist.
/// - `FanRestoring` — put them back on automatic.
/// - `SightednessProving` — **can the mechanism that protects a leased fan see anything at
///   all**, asked once per grant. This one can cost a real hardware round trip, and since
///   [#134](https://github.com/blamechris/Aeolus/issues/134) usually does not.
///
/// The third arrived with #124 and is the only one that reads. It is worth stating plainly
/// here, because `acquireLease`'s `// ---- No await below this line ----` marker can only be
/// reasoned about correctly by somebody who knows how many suspension points that method
/// has: an earlier version of this paragraph said the type "cannot enumerate a fan, read a
/// sensor, or write a value" and named only two dependencies, which would have hidden the
/// slowest of the three from exactly that analysis.
///
/// It was `CriticalTemperatureSensing` until #134, and the swap is not a rename. A read is
/// still what happens when there is no fresh evidence; what changed is that the grant path
/// asks *"can § 3 see"* rather than *"read the curated set now"*, and § 3's own cycle is the
/// authoritative answer to the first.
/// [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) records why, and
/// `SightednessProving` explains why handing this type the cycle's telemetry no longer
/// compiles.
///
/// **Still no write of any kind** — `SMCConnection.write` is `package`-scoped and still
/// throws, and no write selector exists anywhere in `Sources/`.
///
/// The split keeps this fully testable with no hardware. It no longer keeps it free of the
/// mock SMC: `LeaseFixture.authority` defaults `telemetry:` to a `CriticalTemperatureCache`
/// over a `CuratedCriticalTemperatures` over `ScriptedControlPlane`, so every lease test now
/// runs against the scripted firmware through the shipped cache.
/// That is deliberate — a hand-rolled telemetry double would answer "sighted" without the
/// curated key list or the plausibility gate ever running — and it means emptying
/// `CriticalSensorSet.mac16x5` turns the lease suite red, which is a coupling worth knowing
/// about before it surprises somebody.
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
    /// Whether the build behind the restorer can write at all, asked once per grant.
    ///
    /// **The narrow role, never the plane.** This type owns no hardware, and holding a
    /// `FanControlPlane` to read one property would put `commandTarget(_:)` in the lease
    /// core's hand — the same exclusion `FanStateSensing` exists to give
    /// `ReclamationWatchdog`. See `FanWriteCapabilityReporting` for why the answer is
    /// synchronous, and `acquireLease` for why it is consulted before anything else.
    private let writeCapability: any FanWriteCapabilityReporting
    /// The third — and, by design, last — thing this type needs of the machine. See
    /// `SightednessProving` for why it is its own role rather than a method on either of the
    /// two above, and why it is deliberately **not** the role § 3's own cycle holds.
    private let telemetry: any SightednessProving

    /// `docs/SAFETY.md` § 6's post-reconciliation baseline, asked once per grant.
    ///
    /// **Not a `FanControlPlane`, deliberately.** The lease core has no business reading the
    /// firmware; it asks a question and is told a `ManualControlAvailability.Reason`. See
    /// `ForeignManualControlSensing`, and ADR 0011 for why the answer to a fan somebody else
    /// is holding is a refusal rather than a second restore.
    private let foreignControl: any ForeignManualControlSensing

    /// The one bit that says `docs/SAFETY.md` § 3 is holding. Read at grant time; set by
    /// `ThermalEmergency`, which this type deliberately holds no reference to — see
    /// `ThermalEmergencyLatch` for why the latch is its own type.
    ///
    /// **Required, with no default**, unlike the other injected collaborators. A defaulted
    /// `ThermalEmergencyLatch()` compiles silently and yields a private latch that nothing
    /// will ever engage, which turns `refuseIfThermalEmergencyActive` into a guard that
    /// cannot fire. `ThermalEmergency` already required its latch; the two types that must
    /// agree with it did not, and an adversarial review named that as the E3 footgun it is.
    private let thermalEmergency: ThermalEmergencyLatch
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

    /// Fans a restorer gave up on: the attempts are spent and the firmware never took the
    /// write. The durable half of the same ledger `releasing` holds the transient half of —
    /// see `BoundedFanRestorer` for the bound, and #110 for why there is one.
    ///
    /// **Append-only, and nothing clears it.** A fan that enters stays refused for the life
    /// of the helper process. That is #110's decided outcome and is correct while nothing in
    /// `Sources/` restores a fan outside lease teardown — a clearing path would be code no
    /// test could drive. It stops being correct as soon as one exists, and § 7's panic path
    /// is the first: a fan whose mode write is accepted on that pass is still refused on the
    /// strength of an older failure. [#189](https://github.com/blamechris/Aeolus/issues/189)
    /// owns that, including the harder half — whether a write that merely did not throw is
    /// enough to clear a refusal set by three that did.
    private var restoreAbandoned: Set<Int> = []

    /// Whether `docs/SAFETY.md` § 4 has closed this table for a sleep that is under way.
    ///
    /// § 4 empties the table and hands every fan back in the window `.willSleep` opens, and
    /// nothing in that sequence stops a *new* lease being taken while it runs. The hazard is
    /// the one `acquireLease` already documents about its own straight-line region, arriving
    /// from outside: a request parked on `refuseIfBlind`'s 34-key read resumes after § 4 has
    /// emptied the table and restored, finds an empty table and no fan mid-handback, and
    /// engages manual control as the machine stops running this process. The lease then
    /// crosses the sleep with nothing having handed its fan back, which is the exact failure
    /// § 4 exists to prevent, reached through the one door it does not close.
    ///
    /// **Set before the teardown and cleared on `.didWake`.** Clearing it is not a write —
    /// § 4's "after wake: nothing" is about the firmware, and this touches no fan — so the
    /// wake branch stays the absence it is documented to be.
    ///
    /// A helper that hears `.willSleep` and never hears the wake refuses every lease for the
    /// life of the process. That is the fail-safe direction and is deliberately not guarded
    /// against: refusing manual control is safe, and a lease taken on a machine this process
    /// believes is asleep is not.
    private var sleepSeal = false

    init(
        enumeration: some FanEnumerating,
        restorer: some FanRestoring,
        writeCapability: some FanWriteCapabilityReporting,
        telemetry: some SightednessProving,
        foreignControl: some ForeignManualControlSensing,
        thermalEmergency: ThermalEmergencyLatch,
        clock: some MonotonicClock = SystemMonotonicClock(),
        wallClock: @escaping @Sendable () -> Date = Date.init,
        tombstoneCapacity: Int = ConnectionTombstones.defaultCapacity,
        log: LeaseLog = LeaseLog()
    ) {
        self.enumeration = enumeration
        self.restorer = restorer
        self.writeCapability = writeCapability
        self.telemetry = telemetry
        self.foreignControl = foreignControl
        self.thermalEmergency = thermalEmergency
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
    /// 0. **The build's own write capability is refused before anything else**, because it
    ///    is the only refusal here that is a fact about the *executable* rather than about
    ///    the request or the machine. Nothing a client sends and nothing the SMC says can
    ///    change it, so every other answer given ahead of it invites a retry that can never
    ///    succeed — and one of those answers, `noThermalTelemetry`, can cost a real 34-key
    ///    hardware read to produce. See `refuseIfWritePathNotBuilt`.
    /// 1. **Self-renewal is refused next**, before any work is done for a request that
    ///    cannot be granted whatever the machine says.
    /// 2. The TTL is re-validated here although the listener already checked it. Sharing
    ///    `AeolusXPCValidation` is not the same as the listener doing the checking
    ///    (`CLAUDE.md` rule 7), and this method is reachable from the control plane as well
    ///    as from a message.
    /// 3. The suspension points: enumerating the machine's fans, then sweeping anything
    ///    already lapsed — so the single-lease check below is made against live leases only,
    ///    and a previous lease's fans are back on automatic before new ones are taken — then
    ///    refusing if § 3 is latched, then proving the helper can still see a temperature at
    ///    all, and finally asking § 6's baseline whether anything outside Aeolus is holding
    ///    a requested fan. The sweep runs **before** all of those deliberately: a lapsed
    ///    lease's fans go back to automatic whether or not this machine is blind and whether
    ///    or not it is too hot, and neither is a machine on which to skip a restore. The
    ///    foreign-control question comes last of the four things suspended on — the
    ///    enumeration, § 3's latch, the telemetry read and it, three of which are refusals —
    ///    because it is the only one whose cost scales with the number of fans asked for.
    ///    See `refuseIfForeignManualControl(_:wanting:)`.
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
        try refuseIfWritePathNotBuilt(connection)
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
        try await refuseIfThermalEmergencyActive(connection)
        try await refuseIfBlind(connection)
        try await refuseIfForeignManualControl(
            connection, wanting: Set(request.fanIndices).intersection(enumerated))

        // ---- No `await` below this line. Adding one reopens #95. ----
        try AeolusXPCValidation.validateFanIndices(
            request.fanIndices, enumeratedFanIndices: enumerated)
        try refuseIfInvalidated(connection)
        // The three refusals in this straight-line region are ordered by how long they last,
        // most durable first, for the reason the next comment gives at length. This one is
        // the most durable *of the three*: a fan whose handback was given up on is not coming
        // back on its own, so a client told either of the others retries — past the other
        // client's release, past the handback window — into this refusal in the end.
        //
        // It is not the first refusal in the method, and that is not an inconsistency.
        // `refuseIfThermalEmergencyActive` and `refuseIfBlind` run above, both transient,
        // because both need a suspension point and everything here is below every await by
        // construction — the same "a consequence rather than a choice" `refuseIfBlind`
        // documents about its own position relative to `validateFanIndices`.
        let abandoned = request.fanIndices.filter { restoreAbandoned.contains($0) }
        guard abandoned.isEmpty else {
            log.refusedAbandonedHandback(connection, fans: Set(abandoned))
            throw AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        }
        // Second, by the same durability ordering: the seal lifts on the next `.didWake`,
        // where an abandoned handback never lifts. A client told `.systemSleeping` retries
        // after the wake — and if this fan's handback was also abandoned, that retry has to
        // land on the durable answer rather than being told to wait for a wake that has
        // already happened.
        //
        // Above both lease-table refusals, though, and that is not a durability judgement:
        // neither of those is worth telling a client about a machine that is going to stop
        // running this process before it can act on the answer.
        guard !sleepSeal else {
            log.refusedSystemSleeping(connection)
            throw AeolusXPCFault.manualControlUnavailable(reason: .systemSleeping)
        }
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
    ///   `FanRestoring`. Demonstrated against this code, not theorised. **#163 built the
    ///   restorer this warning said did not exist** — `HelperFanRestorer`, constructed by
    ///   `HelperComposition` over the daemon's own plane — so the remaining reason it is
    ///   harmless is narrower and worth stating exactly: `SMCFanControlPlane` still answers
    ///   `.notBuilt`, so its restore verb throws before touching the firmware and no lease
    ///   can be granted to race in the first place. The window is real code now and is held
    ///   shut by the capability gate alone. Once #102 wires the control plane, the losing
    ///   order is: A's connection dies, A's
    ///   restore is enqueued, B acquires and writes a target, A's restore lands and returns
    ///   the fan to automatic. B then holds a live lease over a fan nothing is honouring,
    ///   which is `CLAUDE.md` rule 6 arriving through a door this comment used to claim was
    ///   shut.
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

    // MARK: - Teardown path 3 of 3: revocation

    /// Drops every lease covering `fan`, whole, and returns all of their fans to automatic.
    ///
    /// `docs/SAFETY.md` § 3's revocation, and the only teardown path here that is not a
    /// lease *ending*: the TTL, connection death and a voluntary release are all a holder
    /// running out of claim, while this is a claim being taken from a client that did
    /// nothing wrong. That is why it carries its own `FanRestoreCause` rather than reusing
    /// one — an operator reading `log show` must be able to tell "the client went away"
    /// from "the machine got too hot", and a cause that cannot be named is a mechanism that
    /// cannot be audited.
    ///
    /// **It does not consult the latch, and must not.** `ThermalEmergency` engages the latch
    /// before it writes and calls this afterwards, so a check here would be the same fact
    /// asked twice — and the second asking is the one that can be wrong, because it happens
    /// after two `await`s during which the latch could have been released by a cooler cycle.
    /// A revocation that quietly declined to run would leave a client holding a lease over
    /// fans this actor has already handed back, which is `CLAUDE.md` rule 6.
    ///
    /// Not throwing and returning nothing, for `connectionDidInvalidate(_:)`'s reason: the
    /// caller is a safety actor mid-teardown and has no use for a failure it cannot act on.
    /// Entries are removed synchronously before the restore is awaited, exactly as the other
    /// paths do it.
    func revokeLeases(coveringFan fan: Int, because cause: FanRestoreCause) async {
        let revoked = table.removeAll(covering: fan)
        for entry in revoked {
            log.revoked(entry.connection, fans: entry.fanIndices, because: cause)
            await restore(entry.fanIndices, because: cause)
        }
    }

    /// Revokes **every** live lease, whatever fans it covers.
    ///
    /// `docs/SAFETY.md` § 3 selects on this rather than on the emergency's own registry of
    /// engaged fans, and the difference is a defect an adversarial review found rather than
    /// a preference. A client can hold a live lease **without having engaged manual control
    /// yet** — acquisition and the first write are separate messages — and such a fan is
    /// still on automatic, so it appears in no registry of engaged fans. An emergency that
    /// revoked only what it had bridged would latch, take back nothing, and leave that
    /// lease live; the client's next write would then engage a fan into an emergency that
    /// has already fired.
    ///
    /// It also closes a window the lease core cannot close from its own side. The latch is
    /// a *different actor*, so `refuseIfThermalEmergencyActive` reads it across a hop and
    /// then awaits `refuseIfBlind`'s sightedness proof before the straight-line region
    /// begins — the emergency can engage during that hop, and the grant proceeds. #134
    /// narrowed the window without closing it: the proof is usually served from § 3's own
    /// last reading now rather than from a fresh 34-key read, so it is an actor hop rather
    /// than a hardware round trip, and a hop is still a window. No
    /// re-check below the marker can fix that, because the hop back is itself a window
    /// ([#95](https://github.com/blamechris/Aeolus/issues/95) is the same shape). What
    /// closes it is the emergency taking back whatever it finds, every cycle it holds.
    ///
    /// **"Every cycle" includes the cycles that can see nothing**, which is the half that
    /// was not true when this paragraph was written. `ThermalEmergency.cycle()` used to
    /// return on a failed read before reaching any revocation, so a lease granted in the
    /// window survived for as long as the SMC stayed quiet — and `renewLease` consults
    /// neither the latch nor telemetry, so its holder renewed indefinitely. See
    /// `ThermalEmergency.cycleSawNothing(_:)`, which is where the claim above is now
    /// honoured, and [#152](https://github.com/blamechris/Aeolus/issues/152) for the rest.
    /// The releasing branch reaches no revocation either, and needs none: it is the branch
    /// on which § 3 has stopped holding.
    ///
    /// Deliberately **not** shared with `releaseEveryLease()`, which drops the same table
    /// for § 7's panic verb. They are different actors — levels 1 and 2 — and
    /// `LeaseTable`'s own selectors are written out for exactly this reason: a shared
    /// predicate remover is the first step towards one mechanism wearing several names, and
    /// an operator reading `log show` must be able to tell the panic path from § 3.
    func revokeEveryLease(because cause: FanRestoreCause) async {
        let revoked = table.removeAll()
        for entry in revoked {
            log.revoked(entry.connection, fans: entry.fanIndices, because: cause)
            await restore(entry.fanIndices, because: cause)
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

    // MARK: - The sleep window

    /// Refuses every new lease until the machine wakes. `docs/SAFETY.md` § 4's first act.
    ///
    /// Synchronous, and called *before* the teardown rather than after it, so there is no
    /// instant at which the table is empty and unsealed — which is the whole window. See
    /// `sleepSeal`.
    func sealForSleep() {
        guard !sleepSeal else { return }
        sleepSeal = true
        log.sealedForSleep()
    }

    /// Reopens acquisition after a wake. Touches no fan and issues no write.
    func unsealAfterWake() {
        guard sleepSeal else { return }
        sleepSeal = false
        log.unsealedAfterWake()
    }

    /// Records every handback still in flight as one the helper stopped waiting for.
    ///
    /// § 4's budget path, and the reason it is here rather than in `SystemPowerResponder`:
    /// `releasing` is this actor's own, and the set of fans whose restore has been *issued
    /// and has not come back* exists nowhere else. When § 4 gives up its wait, those fans are
    /// in a mode nothing has confirmed and this process has stopped tracking them — which is
    /// precisely `restoreAbandoned`'s meaning, arrived at by a bound expiring rather than by
    /// a restorer spending its attempts.
    ///
    /// **Additive and idempotent**, like every other write to that set. The parked restore
    /// may still land afterwards; the refusal it leaves behind is deliberately not undone by
    /// that, for the reason `restoreAbandoned` gives at length — the helper asked, was not
    /// answered in the window it had, and `CLAUDE.md` rule 6 forbids granting a lease over a
    /// fan whose mode nothing has confirmed. [#189](https://github.com/blamechris/Aeolus/issues/189)
    /// owns clearing it.
    ///
    /// - Returns: the fans newly or already recorded, so § 4 can name them in its own log
    ///   line rather than asserting that some existed.
    @discardableResult
    func abandonOutstandingHandbacks() -> Set<Int> {
        let outstanding = Set(releasing.keys)
        restoreAbandoned.formUnion(outstanding)
        return outstanding
    }

    // MARK: - State, for the control plane and for tests

    /// The lease a snapshot reports, sweeping anything lapsed first so a snapshot never
    /// shows a lease that has already stopped holding the fans.
    func activeLease() async -> Lease? {
        await activeLeaseView().lease
    }

    /// The lease a client is shown **and every fan Aeolus is accountable for**, read in one
    /// hop.
    ///
    /// The fan set is not on the wire — `Lease` carries no indices — and the snapshot needs
    /// it anyway, to tell a fan Aeolus is holding from one somebody else is. Two calls would
    /// answer that question from two views of this actor: a lease reported live beside an
    /// empty fan set, and therefore a fan under Aeolus's own lease reported as foreign
    /// control. One hop cannot disagree with itself.
    ///
    /// **It is `fansAeolusIsAccountableFor`, not the lease's own fans, and the two are not
    /// the same set.** An earlier version returned `table.all.first`'s indices, which was
    /// wrong twice over: it named only the *first* entry's fans, so a second table entry's
    /// fans read as foreign; and it omitted the fans that are mid-handback or whose handback
    /// was abandoned. A fan Aeolus itself put into manual and could not give back would then
    /// be reported to the user as another program's — `CLAUDE.md` rule 6, in the direction
    /// `fansAeolusIsAccountableFor` calls *"a considerably worse thing to be told is
    /// somebody else's fault"*. The grant path has always judged against this set; the
    /// snapshot now asks the same question of the same state, in the same hop.
    func activeLeaseView() async -> (lease: Lease?, accountableFans: Set<Int>) {
        await expireLapsedLeases()
        return (table.all.first?.asLease(), fansAeolusIsAccountableFor)
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

    /// Refuses the grant when this build has no SMC write path.
    ///
    /// **Synchronous, and first in `acquireLease`.** Both halves are the point.
    ///
    /// *First*, because this is the only refusal in the method that no client and no machine
    /// can change. `refuseIfBlind` can cost a real 34-key `.supervisor` read — it does
    /// whenever § 3's last reading has aged out, and always on a helper whose supervisor is
    /// not running — so ordering it
    /// ahead of this one would spend a hardware round trip to produce an answer about the
    /// *sensors* for a request that was never going to be granted whatever they said — and a
    /// client told `noThermalTelemetry` reasonably retries when the machine recovers, into a
    /// refusal that is not about the machine at all. `LeaseWriteCapabilityTests` asserts the
    /// read count, not merely the fault, because a check that is merely *present* can be
    /// moved below the read by an ordinary-looking edit and nothing else would notice.
    ///
    /// *Synchronous*, because `FanWriteCapabilityReporting` has no `async` on it: "before
    /// any hardware round trip" is then a property of the type rather than a claim about
    /// where this line sits. See that protocol.
    ///
    /// It replaces `ReadOnlyFanAuthority`'s hard-coded `Self.noWritePath` — the same fault,
    /// the same reason case, sourced from the seam that would have to perform the write
    /// instead of from a literal. `AeolusXPCFault.manualControlUnavailable(reason:)` and
    /// `.writePathNotBuilt` both already exist, so `AeolusXPCVersion` does not move.
    private func refuseIfWritePathNotBuilt(_ connection: ConnectionID) throws {
        guard writeCapability.writeCapability == .notBuilt else { return }
        log.refusedNoWritePath(connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    /// Refuses the grant if the helper cannot currently see a critical temperature.
    ///
    /// **`docs/SAFETY.md` § 3 is a precondition of § 1.** A lease is a promise that
    /// something is watching the fans it pins; a helper that cannot read a temperature is
    /// not watching anything, and the thermal override, the reclamation watchdog and the
    /// sleep supervisor are all equally blind. What is left is the TTL, which
    /// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) accepts as a *backstop*
    /// and nowhere accepts as the whole mechanism.
    ///
    /// ## What it costs, since #134
    ///
    /// Not a read per call. `SightednessProving` is answered by `CriticalTemperatureCache`,
    /// which serves § 3's own most recent reading while it is less than one cycle period
    /// old and coalesces concurrent callers onto a single read when it is not — so a client
    /// retrying `acquireLease` in a tight loop can no longer queue an unbounded number of
    /// `.supervisor` turns ahead of the cycle that would take its fans back. A cold cache,
    /// or a helper whose thermal supervisor is not running, still costs one real 34-key read
    /// per grant. [ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md) records
    /// why that staleness is exact rather than tolerated: this method asks whether § 3 can
    /// see, and § 3's own cycle is the authoritative answer to that question.
    ///
    /// ## Why it sits here in the order
    ///
    /// It is above the straight-line region because it suspends, and it must be: the proof
    /// is the point. That places it ahead of the concurrent-lease and mid-handback
    /// refusals, so a client asking during blindness is told about the blindness even when
    /// another client holds the fans. Both facts are true and this is the one worth
    /// telling: `leaseHeldByAnotherClient` invites "wait for them to finish", which is
    /// wrong advice on a machine where nobody can be granted anything.
    ///
    /// It also lands ahead of `validateFanIndices`, which is the one ordering here that is
    /// a consequence rather than a choice — everything in the straight-line region is below
    /// every suspension point by construction. So a request naming a fan that does not
    /// exist, sent to a blind machine, is answered `noThermalTelemetry` rather than
    /// `invalidFanIndex`. That is tolerable (both are refusals, and the blindness is the
    /// more consequential fact) but it is not a judgement anybody made, and a future reader
    /// comparing this against the validation-first ordering elsewhere should know that.
    ///
    /// ## Why it catches everything except cancellation
    ///
    /// Every failure to obtain telemetry is blindness, whatever its type. There is no
    /// allow-list of error cases that count, because an allow-list means the next error case
    /// somebody adds silently defaults to *granted*, and this guard exists precisely to stop
    /// a lease being handed out on a machine nothing can see. The default is refuse.
    ///
    /// `CancellationError` is the one exception, and it is not a hole in that rule — it is
    /// the one error that is definitionally **not a statement about the machine**. A
    /// cancelled request says the caller went away; it says nothing about whether the SMC
    /// answered. Folding it in would tell a client "no thermal telemetry" when telemetry was
    /// never the problem, and — worse — write a `.fault` line into a root daemon's log
    /// claiming the sensors went silent on a machine whose sensors are fine. That log is
    /// meant to be the record a user reaches for when asking whether the mechanism was
    /// watching; a false entry in it is worse than no entry.
    ///
    /// Re-throwing is also still fail-safe: the lease is not granted either way. Only the
    /// reported reason differs, and `CLAUDE.md` rule 6 is about exactly that — never report
    /// a state that is not the one you are in.
    private func refuseIfBlind(_ connection: ConnectionID) async throws {
        do {
            _ = try await telemetry.sighting()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            log.refusedBlindTelemetry(connection, detail: String(describing: error))
            throw AeolusXPCFault.manualControlUnavailable(reason: .noThermalTelemetry)
        }
    }

    /// Refuses the grant while `docs/SAFETY.md` § 3 is holding.
    ///
    /// **A revoked holder is not silently re-granted.** The emergency revokes the whole
    /// lease covering a fan it fired on, and the client's ordinary response to losing a
    /// lease is to acquire another one — so without this, the mechanism would hand the fans
    /// straight back to the workload that overheated the machine, on a cycle bounded only
    /// by how fast the client retries. Resuming is a fresh `acquireLease`, and it is
    /// refused until a fresh reading falls a hysteresis margin below the ceiling.
    ///
    /// `.thermalEmergencyActive` already exists in `AeolusXPCFault` — E2 built the
    /// vocabulary before the mechanism, so this consumes a fault case rather than adding
    /// one, and `AeolusXPCVersion` does not move.
    ///
    /// ## Why it sits above the blindness check
    ///
    /// Both are refusals and both are true when both apply, so the question is which fact
    /// the client is told. This one, for two reasons. It is the more consequential — a
    /// machine above its thermal ceiling is a worse thing to grant a lease on than a machine
    /// whose sensors went quiet — and it is the only one of the two that costs no hardware
    /// round trip, so a latched machine refuses without spending an SMC read it does not
    /// need. The same reasoning `refuseIfBlind` gives for sitting above the concurrent-lease
    /// refusal, one step further up.
    private func refuseIfThermalEmergencyActive(_ connection: ConnectionID) async throws {
        guard await thermalEmergency.isActive else { return }
        log.refusedThermalEmergency(connection)
        throw AeolusXPCFault.thermalEmergencyActive
    }

    /// `docs/SAFETY.md` § 6's baseline, asked immediately after the blindness gate.
    ///
    /// **Last of the four things `acquireLease` suspends on, and last of the three refusals
    /// among them — and the position is reasoned.** The four are the fan enumeration, § 3's
    /// latch, the curated-telemetry read, and this; the enumeration is the one that is not a
    /// refusal, and the sweep of lapsed leases runs ahead of all four rather than being one
    /// of them. Step 3 of `acquireLease` lists them in that order, and says which count is
    /// which for the same reason this does: two nearby sentences counting different things
    /// with the same word is how the previous "three" and "four" came to disagree. § 3's
    /// latch
    /// and the curated-telemetry read are both properties of the *machine* and answer for
    /// every fan at once; this one costs one `.supervisor` turn **per requested fan**, so it
    /// is the most expensive question here and the one most worth not asking when a cheaper
    /// refusal already applies. `refuseIfWritePathNotBuilt` running first (step 0) is what
    /// keeps it off today's helper's grant path entirely.
    ///
    /// `fansAeolusIsAccountableFor` is read here rather than passed in because it must be
    /// this actor's state as it stands at the moment of the question — see that property for
    /// the three registers it unions and the more precise refusal each of them already has.
    private func refuseIfForeignManualControl(
        _ connection: ConnectionID, wanting fans: Set<Int>
    ) async throws {
        let reason = await foreignControl.refusalForGrant(
            overFans: fans, heldByAeolus: fansAeolusIsAccountableFor)
        guard let reason else { return }
        log.refusedForeignManualControl(connection, fans: fans, reason: reason)
        throw AeolusXPCFault.manualControlUnavailable(reason: reason)
    }

    /// Every fan whose manual state is Aeolus's own doing, and therefore not foreign.
    ///
    /// Three registers, and each one has a **more precise** refusal further down this
    /// method — which is the whole reason they are excluded rather than judged. `F<n>Md`
    /// reads `1` for all three and names no owner, so without this a client would be told
    /// "another program holds it" about:
    ///
    /// - a fan under a live lease (`.leaseHeldByAnotherClient` — another *client*, not
    ///   another program);
    /// - a fan mid-handback (`.releaseInProgress` — retry in a moment);
    /// - a fan whose handback was given up on (`.restoreToAutomaticFailed` — Aeolus put it
    ///   there and could not take it back, which is a considerably worse thing to be told
    ///   is somebody else's fault).
    ///
    /// **Read by the snapshot as well as by the gate**, through `activeLeaseView()`. One
    /// definition, because two would disagree the moment either moved — and the way they
    /// disagreed before was the snapshot naming a fan Aeolus could not hand back as another
    /// program's, while the gate refused it correctly.
    private var fansAeolusIsAccountableFor: Set<Int> {
        table.fansUnderLease.union(restoreAbandoned).union(releasing.keys)
    }

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
        // Whatever came back was not handed back. Recorded rather than dropped: the fan is
        // in a mode nothing has confirmed, so the next `acquireLease` over it is refused
        // durably instead of being told to retry a window that has closed. Additive, so the
        // actor being reentrant across the await above cannot lose an entry.
        restoreAbandoned.formUnion(
            await restorer.restoreToAutomatic(fans: fans, because: cause))
    }
}
