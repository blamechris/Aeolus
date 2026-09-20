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
/// **Still no write of any kind** — `SMCConnection.write` is SPI-gated and still
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
///
/// ## The handback ledger lives in a document
///
/// The three registers below — `releasing`, `handbackUnconfirmed`, `restoreAbandoned` — are
/// one mechanism documented in five places, and the whole of it is now
/// [docs/records/handback-ledger.md](../../../docs/records/handback-ledger.md): what enters
/// each register and what clears it, why the grant gate answers with three different
/// refusals in the order it does, why every teardown hands its sweep back in one call, and
/// why the panic sweep has two sources. Each declaration below keeps the fact it states and
/// cites the section that argues it.
///
/// That relocation is why this file is under the 1000-line `file_length` **error** it crossed
/// when #271 and #273 met. The document's first section records what was refused to get there
/// — no `swiftlint:disable`, no `.swiftlint.yml` override, and no split that would widen the
/// `private` state `LeaseAuthorityAccessTests` holds — and #128 had already taken the one
/// seam available without widening it.
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
    ///
    /// `internal` since #128 moved `refuseIfWritePathNotBuilt` to
    /// `LeaseAuthorityRefusals.swift`. A get-only property on a `Sendable` role: the module
    /// can ask the same question, and no answer it gets changes anything here.
    let writeCapability: any FanWriteCapabilityReporting
    /// The third — and, by design, last — thing this type needs of the machine. See
    /// `SightednessProving` for why it is its own role rather than a method on either of the
    /// two above, and why it is deliberately **not** the role § 3's own cycle holds.
    ///
    /// `internal` since #128 moved `refuseIfBlind` to `LeaseAuthorityRefusals.swift`. One
    /// read verb, `sighting()`, on a role that holds no writer and no plane.
    let telemetry: any SightednessProving

    /// `docs/SAFETY.md` § 6's post-reconciliation baseline, asked once per grant.
    ///
    /// **Not a `FanControlPlane`, deliberately.** The lease core has no business reading the
    /// firmware; it asks a question and is told a `ManualControlAvailability.Reason`. See
    /// `ForeignManualControlSensing`, and ADR 0011 for why the answer to a fan somebody else
    /// is holding is a refusal rather than a second restore.
    ///
    /// `internal` since #128 moved `refuseIfForeignManualControl(_:wanting:)` to
    /// `LeaseAuthorityRefusals.swift`. One read verb, `refusalForGrant(overFans:
    /// heldByAeolus:)`, which answers with a `ManualControlAvailability.Reason` and touches
    /// no fan.
    let foreignControl: any ForeignManualControlSensing

    /// The one bit that says `docs/SAFETY.md` § 3 is holding. Read at grant time; set by
    /// `ThermalEmergency`, which this type deliberately holds no reference to — see
    /// `ThermalEmergencyLatch` for why the latch is its own type.
    ///
    /// **Required, with no default**, unlike the other injected collaborators. A defaulted
    /// `ThermalEmergencyLatch()` compiles silently and yields a private latch that nothing
    /// will ever engage, which turns `refuseIfThermalEmergencyActive` into a guard that
    /// cannot fire. `ThermalEmergency` already required its latch; the two types that must
    /// agree with it did not, and an adversarial review named that as the E3 footgun it is.
    ///
    /// **Deliberately still `private` after #128**, where the other three injected
    /// collaborators went `internal` so `LeaseAuthorityRefusals.swift` could reach them.
    /// Those three are stateless query roles; this is a concrete actor with mutators, so
    /// widening the reference would hand every file in the module a route to engage or
    /// release § 3's latch through the lease core. `refuseIfThermalEmergencyActive(_:)`
    /// therefore stayed here with it. `LeaseAuthorityAccessTests` enforces that.
    private let thermalEmergency: ThermalEmergencyLatch

    /// `internal` since #128, for the three refusals in `LeaseAuthorityRefusals.swift`.
    /// `LeaseLog` is an `os.Logger` wrapper that is already constructible anywhere in the
    /// module — this initialiser defaults it to `LeaseLog()` — so the widening adds no
    /// capability that did not exist.
    let log: LeaseLog

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
    /// **One producer, and it is a firmware refusal**: the union in `restore(_:because:)`.
    /// `docs/SAFETY.md` § 4's acknowledgement budget expiring is **not** a second one and was
    /// one until ADR 0007, amendment 2026-09-06 (#209) — a budget is evidence about time
    /// rather than about the firmware, so it records `handbackUnconfirmed` below instead, and
    /// a fan reaches this set from there only when the outstanding restore comes back refused.
    ///
    /// **Not append-only since [#189](https://github.com/blamechris/Aeolus/issues/189)**, and
    /// the one thing that clears it is a restore the restorer reports it did *not* give up on.
    /// **A restore that never returns leaves it standing**, as does one refused again, and
    /// both are the fail-safe direction.
    ///
    /// Why the register was self-sealing until #189, why the clearing standard is the one
    /// `HelperFanRestorer` already deregisters § 3's registry on, and why a weaker one would
    /// lift a refusal three observed firmware refusals set on evidence about a call:
    /// handback-ledger.md § *"`restoreAbandoned` — the durable half"*.
    private var restoreAbandoned: Set<Int> = []

    /// Fans whose restore-to-automatic was issued, stopped being waited for, and has not come
    /// back: `docs/SAFETY.md` § 4's acknowledgement budget expired with it still outstanding.
    ///
    /// The third register in this ledger, between the transient `releasing` and the durable
    /// `restoreAbandoned`, and it is a distinct fact from either: the write is still in
    /// flight, nothing cancelled it, and this process has no answer about the fan's mode.
    /// Decision D33 on [#209](https://github.com/blamechris/Aeolus/issues/209) — ADR 0007,
    /// amendment 2026-09-06.
    ///
    /// **Invariant: it is always a subset of `releasing.keys`.** A fan enters only from
    /// `releasing.keys`, in `recordUnconfirmedHandbacks()`, and leaves only when its
    /// `releasing` count drops to `nil` in `restore(_:because:)`'s `defer` — the instant the
    /// restore that put it there returns. Nothing else writes it, which is why
    /// `fansAeolusIsAccountableFor` needs no third union, and why
    /// `UnconfirmedHandbackTests` asserts the subset rather than leaving it a sentence.
    ///
    /// **Not append-only, and that is the whole of D33**: the three outcomes a handback can
    /// reach, and which register each ends in, are handback-ledger.md § *"The three
    /// registers"*.
    private var handbackUnconfirmed: Set<Int> = []

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
    ///
    /// **Hearing them out of order is a different case, and it is guarded** — see
    /// `wakesAheadOfTheirSeal`. The fail-safe argument above covers a wake that never comes;
    /// it does not cover one that came and was answered before the seal it belonged to was
    /// ever set, which leaves the seal standing over a machine that is demonstrably awake.
    private var sleepSeal = false

    /// Wakes answered while no seal was standing, each owed to a `.willSleep` whose body has
    /// not run yet.
    ///
    /// `SystemPowerObserver.deliver(_:acknowledging:)` spawns an unstructured `Task` per
    /// event, so IOKit's serial queue orders the **spawns** and nothing orders the bodies. If
    /// the `.willSleep` body is starved past the kernel's ~30 s acknowledgement window the
    /// machine sleeps regardless, and on wake the `.didWake` body can reach
    /// `unsealAfterWake()` first. Before this counter that call found `sleepSeal` already
    /// `false`, returned without doing anything, and the starved `sealForSleep()` then set a
    /// seal with nothing left to clear it — every lease refused as `.systemSleeping` until the
    /// *next* sleep and wake, on a machine sitting awake in front of its user.
    ///
    /// So a wake that arrives early is not discarded, it is **banked**: the next
    /// `sealForSleep()` spends the credit and declines to seal, because the sleep episode that
    /// seal belonged to is over and the machine is already awake. Counted rather than a flag
    /// for the same reason `releasing` is counted — two sleep/wake pairs can be in flight at
    /// once on a machine sleeping repeatedly, and a flag would let the first wake's credit
    /// cancel the second episode's seal.
    ///
    /// It does **not** claim the rest of the starved `.willSleep` body is harmless. That body
    /// still runs `releaseEveryLease()` and the keystone restore after the wake, so a lease
    /// taken in between is dropped and its fan handed back at a moment nothing asked for.
    /// `acquireLease` refuses a fan that is mid-`releasing`, which narrows the window rather
    /// than closing it. Stated here rather than fixed because ordering two unstructured task
    /// bodies from a `@convention(c)` callback is a change to `SystemPowerObserver`'s shape,
    /// and this counter is what keeps the *seal* — the part that outlives the episode — from
    /// being the thing that survives it.
    private var wakesAheadOfTheirSeal = 0

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
        // The four refusals in this straight-line region are ordered by how long they last,
        // most durable first: a client told a transient refusal retries, and if it retries
        // into a durable one in the end, the first answer wasted the round trip and told it
        // something less true than what was available. handback-ledger.md § "The grant gate's
        // ordering" argues each of the four positions, including why the two refusals above
        // the marker are transient and above it anyway.
        //
        // This one is the most durable of the four: a fan whose handback was given up on is
        // not coming back on its own, so a client told any of the others retries — past the
        // other client's release, past the handback window — into this refusal in the end.
        let abandoned = request.fanIndices.filter { restoreAbandoned.contains($0) }
        guard abandoned.isEmpty else {
            log.refusedAbandonedHandback(connection, fans: Set(abandoned))
            throw AeolusXPCFault.manualControlUnavailable(reason: .restoreToAutomaticFailed)
        }
        // Second, and above the seal deliberately. A fan whose handback is unconfirmed is
        // also mid-`releasing` by this set's own invariant, so without this check the
        // `.releaseInProgress` guard at the bottom would answer for it — "retry in a moment"
        // about a restore that has already outlived a five-second budget, which is the one
        // thing a client must not be told here.
        let unconfirmed = request.fanIndices.filter { handbackUnconfirmed.contains($0) }
        guard unconfirmed.isEmpty else {
            log.refusedUnconfirmedHandback(connection, fans: Set(unconfirmed))
            throw AeolusXPCFault.manualControlUnavailable(reason: .handbackUnconfirmed)
        }
        // Third, by the same durability ordering: the seal lifts on the next `.didWake`,
        // where an abandoned handback never lifts. Above both lease-table refusals, though,
        // and that is not a durability judgement: neither of those is worth telling a client
        // about a machine that is going to stop running this process before it can act on it.
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
    /// the restore finds an empty table and cannot restore the same fans twice. The whole
    /// sweep is then handed back in **one** `restore` call, not one per entry
    /// ([#188](https://github.com/blamechris/Aeolus/issues/188)), which is how every teardown
    /// path here is written — handback-ledger.md § *"One restore call per sweep"* has the
    /// argument, and `TeardownSweepTripwireTests` makes a return to the per-entry shape fail.
    ///
    /// - Warning: Removing before restoring is the whole of what that buys, and the empty
    ///   table cuts both ways. An emptied table is exactly what makes `acquireLease`'s
    ///   liveness check pass, so a new lease **can** be granted over a fan whose restore is
    ///   still parked inside `FanRestoring`. Demonstrated against this code, not theorised.
    ///   What holds it shut today is the capability gate alone — `SMCFanControlPlane` answers
    ///   `.notBuilt`, so `HelperFanRestorer`'s restore verb throws before touching the
    ///   firmware and no lease can be granted to race in the first place. **#102 owns the
    ///   interlock** for when that stops being true, and the reclamation watchdog is a
    ///   backstop for it rather than a substitute. The losing order, and why #163 narrowed
    ///   this warning rather than closing it, are in the same section of that document.
    func expireLapsedLeases() async {
        let lapsed = table.removeLapsed(asOf: clock.now)
        guard !lapsed.isEmpty else { return }
        let fans = lapsed.reduce(into: Set<Int>()) { $0.formUnion($1.fanIndices) }
        await restore(fans, because: .leaseExpired)
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
    /// removes before it restores — and the whole sweep is restored in one call, for that
    /// method's #188 reason.
    ///
    /// Not throwing and returning nothing, per `FanAuthority`: the connection this concerns
    /// is already gone, so there is nobody a failure could be reported to.
    func connectionDidInvalidate(_ connection: ConnectionID) async {
        if let evicted = tombstones.record(connection) {
            log.evictedTombstone(evicted, capacity: tombstones.count)
        }
        let released = table.removeAll(heldBy: connection)
        guard !released.isEmpty else { return }

        let fans = released.reduce(into: Set<Int>()) { $0.formUnion($1.fanIndices) }
        await restore(fans, because: .connectionInvalidated)
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
    /// paths do it, and the sweep is restored in one call for `expireLapsedLeases`' #188
    /// reason.
    ///
    /// **The log line stays per entry, and only the restore is unified** — a revocation is a
    /// claim being taken from a *named* client, which is this method's own argument for owning
    /// a distinct `FanRestoreCause`, and a single line naming a union of fans would undo it.
    /// handback-ledger.md § *"One restore call per sweep"*, last paragraph.
    func revokeLeases(coveringFan fan: Int, because cause: FanRestoreCause) async {
        let revoked = table.removeAll(covering: fan)
        guard !revoked.isEmpty else { return }
        for entry in revoked {
            log.revoked(entry.connection, fans: entry.fanIndices, because: cause)
        }
        let fans = revoked.reduce(into: Set<Int>()) { $0.formUnion($1.fanIndices) }
        await restore(fans, because: cause)
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
    /// **It is lease-scoped and stays lease-scoped**, which is a decision worth writing down
    /// now that `releaseEveryLease()` is not: § 3 is a mechanism *taking* fans in order to
    /// cool the machine, not a recovery verb, and a fan whose handback was abandoned is one
    /// it may need to command hardest. handback-ledger.md § *"Why `revokeEveryLease` is not
    /// given the same sweep"*; `PanicPathScopeTripwireTests` holds the two verbs apart.
    func revokeEveryLease(because cause: FanRestoreCause) async {
        let revoked = table.removeAll()
        guard !revoked.isEmpty else { return }
        for entry in revoked {
            log.revoked(entry.connection, fans: entry.fanIndices, because: cause)
        }
        let fans = revoked.reduce(into: Set<Int>()) { $0.formUnion($1.fanIndices) }
        await restore(fans, because: cause)
    }

    // MARK: - The panic path

    /// Drops every lease and restores every fan they covered.
    ///
    /// The lease core's half of `restoreAllToAutomatic` — and, on every build that exists, the
    /// whole of what that message performs. The contract is global rather than lease-scoped, so
    /// it additionally specifies `restoreToAutomatic(.everyFan)` on the plane; the shipped
    /// handler deliberately issues no such call, and the decision lives at
    /// `SupervisedFanAuthority.restoreAllToAutomatic`. Read that before changing either.
    ///
    /// **Releasing leases is not restoring the machine**, and this paragraph was present
    /// indicative about the `.everyFan` call until
    /// [#228](https://github.com/blamechris/Aeolus/issues/228). What reaches the plane from
    /// here is one `restoreToAutomatic(.fan(index))` per fan in the sweep, through
    /// `KeystoneRestoreAttempt`. A fan another tool left in manual under no live lease is not
    /// touched, and neither is the machine-wide `Ftst` force key — `.everyFan` is the only
    /// scope that clears it, and this is not one of its three call sites.
    ///
    /// ## The sweep is the table **and** `restoreAbandoned`
    ///
    /// [#189](https://github.com/blamechris/Aeolus/issues/189) is why, and the reason is not a
    /// widening of scope for its own sake: an abandoned fan was **unreachable by every restore
    /// this actor issues**, because every other teardown path derives its fans from table
    /// entries and `acquireLease` refuses every fan in `restoreAbandoned`. It is this verb
    /// rather than another because this verb is the recovery one — § 7 is what a user reaches
    /// for when the fans are stuck, and `docs/RECOVERY.md` is the step after it.
    /// `revokeEveryLease(because:)` is deliberately not given the same sweep — see there.
    ///
    /// **It touches nothing foreign, so ADR 0011 is intact**, and **one `restore` call for the
    /// whole sweep is load-bearing here rather than uniform** — the sweep has two sources, so
    /// a per-source shape would leave one of them outside `releasing` while the other's
    /// restore was on the wire. Both, with the losing order spelled out:
    /// handback-ledger.md § *"The panic sweep has two sources"*.
    ///
    /// **It does not make the message fail**, which is the reason the *machine-wide* restore
    /// was declined here (#159): `restore(_:because:)` cannot throw, and a firmware that
    /// refuses again simply leaves the refusal standing. So a v1 message that succeeds keeps
    /// succeeding, and the contract does not move.
    ///
    /// **Consults no per-`ConnectionID` state**, which is the precondition
    /// `HelperConnectionSession` documents for exempting that message from its teardown
    /// gate: `connection` is attribution only, so both post-invalidation orderings converge
    /// on the same safe state. Making this consult per-connection state would invalidate the
    /// exemption and needs revisiting alongside it —
    /// [#95](https://github.com/blamechris/Aeolus/issues/95).
    /// **One `restore` call over the union, and that is what makes § 4's record complete
    /// rather than partial** ([#202](https://github.com/blamechris/Aeolus/issues/202) item 4).
    /// `restore(_:because:)` increments `releasing` for every fan in the set *before* its
    /// suspension point, so the whole union is mid-handback the instant this awaits — and
    /// `recordUnconfirmedHandbacks()`, which reads `releasing.keys`, therefore sees all of it
    /// even if the first fan's write wedges and nothing after it ever lands. Restoring
    /// per-lease or per-fan in a loop would put each subsequent fan's increment *after* the
    /// previous one's suspension, so a wedge on the first would leave the rest neither
    /// restored nor recorded: § 4 would acknowledge the sleep having registered one fan out of
    /// however many crossed it under manual control. `SleepCycleSurvivalTests` pins this, so
    /// a refactor to a loop goes red rather than silently narrowing the record.
    func releaseEveryLease() async {
        let dropped = table.removeAll()
        let fans = dropped.reduce(into: restoreAbandoned) { $0.formUnion($1.fanIndices) }
        guard !fans.isEmpty else { return }
        await restore(fans, because: .allLeasesDropped)
    }

    // MARK: - The sleep window

    /// Refuses every new lease until the machine wakes. `docs/SAFETY.md` § 4's first act.
    ///
    /// Synchronous, and called *before* the teardown rather than after it, so there is no
    /// instant at which the table is empty and unsealed — which is the whole window. See
    /// `sleepSeal`.
    /// A seal whose wake has already been answered is **not** set: see
    /// `wakesAheadOfTheirSeal` for the ordering that produces one, and for why declining is
    /// the safe direction here even though sealing is the safe direction everywhere else.
    func sealForSleep() {
        guard wakesAheadOfTheirSeal == 0 else {
            wakesAheadOfTheirSeal -= 1
            log.declinedASealItsWakeAlreadyAnswered()
            return
        }
        guard !sleepSeal else { return }
        sleepSeal = true
        log.sealedForSleep()
    }

    /// Reopens acquisition after a wake. Touches no fan and issues no write.
    ///
    /// A wake with no seal standing banks a credit rather than returning silently. That
    /// silent return was the defect: it made the two calls look paired when they were not.
    func unsealAfterWake() {
        guard sleepSeal else {
            wakesAheadOfTheirSeal += 1
            log.wokeBeforeItsSealWasSet()
            return
        }
        sleepSeal = false
        log.unsealedAfterWake()
    }

    /// Records every handback still in flight as one whose outcome nothing has confirmed.
    ///
    /// § 4's budget path, and the reason it is here rather than in `SystemPowerResponder`:
    /// `releasing` is this actor's own, and the set of fans whose restore has been *issued
    /// and has not come back* exists nowhere else. When § 4 gives up its wait, those fans are
    /// in a mode nothing has confirmed, and a lease over one would be `CLAUDE.md` rule 6.
    ///
    /// **It records `handbackUnconfirmed`, not `restoreAbandoned`, and the difference is
    /// decision D33** — ADR 0007, amendment 2026-09-06 (#209) — because **a budget expiring is
    /// evidence about time, not about the firmware.** Nothing here observed a refused write;
    /// what was observed is that five seconds passed. What the durable set cost a healthy
    /// machine that merely slept slowly, and what survives of the old argument, are
    /// handback-ledger.md § *"Why recording it belongs to the lease core"*.
    ///
    /// **Additive and idempotent.** It is called from inside `SleepAcknowledgement`'s
    /// once-only guard, so it runs at most once per sleep; being safe to call twice is a
    /// property worth having anyway, because the alternative is a set whose correctness
    /// depends on a caller elsewhere.
    ///
    /// - Returns: the fans newly or already recorded, so § 4 can name them in its own log
    ///   line rather than asserting that some existed.
    @discardableResult
    func recordUnconfirmedHandbacks() -> Set<Int> {
        let outstanding = Set(releasing.keys)
        handbackUnconfirmed.formUnion(outstanding)
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
    /// One hop rather than two, because two would answer from two views of this actor: a lease
    /// reported live beside an empty fan set, and therefore a fan under Aeolus's own lease
    /// reported as foreign control. It is `fansAeolusIsAccountableFor` rather than the lease's
    /// own fans, and **since [#187](https://github.com/blamechris/Aeolus/issues/187) it carries
    /// the three registers apart** as well as their union — the union cannot answer *"why would
    /// a grant over this fan be refused?"*, and a snapshot that had only it reported a
    /// mid-handback fan and an abandoned one alike as available.
    ///
    /// The grant path has always judged against this set; the snapshot asks the same question of
    /// the same state, in the same hop. Both wrong answers an earlier version gave, and why the
    /// registers are returned rather than exposed as three more properties:
    /// handback-ledger.md § *"What the snapshot is told"*.
    func activeLeaseView() async -> LeaseAccountability {
        await expireLapsedLeases()
        return LeaseAccountability(
            lease: table.all.first?.asLease(),
            accountableFans: fansAeolusIsAccountableFor,
            abandonedHandbacks: restoreAbandoned,
            unconfirmedHandbacks: handbackUnconfirmed,
            handbacksInFlight: Set(releasing.keys)
        )
    }

    var leaseCount: Int { table.count }
    var tombstoneCount: Int { tombstones.count }

    /// The fans § 4's budget gave up waiting for and nothing has answered for since.
    ///
    /// Read-only and derived from state that stays `private`, exactly as
    /// `fansAeolusIsAccountableFor` is: a caller can see the set, and nothing it does with the
    /// answer can put a fan into it or take one out. handback-ledger.md § *"The read-only rule
    /// the accessors are allowed under"* says what the three are for.
    var fansWithUnconfirmedHandbacks: Set<Int> { handbackUnconfirmed }

    /// The fans a restorer gave up on: the firmware refused every attempt. The durable half,
    /// under the same read-only rule as the set above.
    var fansWithAbandonedHandbacks: Set<Int> { restoreAbandoned }

    /// The fans with a restore issued and not yet returned — `releasing`'s keys, and nothing
    /// about its counts. Read-only, under the same rule as the two sets above, and what makes
    /// `handbackUnconfirmed ⊆ releasing.keys` a fact a test asserts rather than a sentence.
    var fansMidHandback: Set<Int> { Set(releasing.keys) }

    func holdsTombstone(for connection: ConnectionID) -> Bool {
        tombstones.contains(connection)
    }

    // MARK: - Guards
    //
    // The three refusals that consult a stateless query role rather than this actor's own
    // state — the build's write capability, the sightedness proof, and § 6's foreign-control
    // baseline — live in `LeaseAuthorityRefusals.swift`, which explains the split. What is
    // left here is what reads state this actor owns.

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

    /// Every fan whose manual state is Aeolus's own doing, and therefore not foreign.
    ///
    /// Three registers, and each one has a **more precise** refusal further down the grant
    /// path — which is the whole reason they are excluded rather than judged. `F<n>Md` reads
    /// `1` for all three and names no owner, so without this a client would be told "another
    /// program holds it" about a fan another *client* legitimately leases, one that is
    /// mid-handback, and one Aeolus put into manual and could not take back.
    /// `handbackUnconfirmed` is deliberately not a fourth union: it is a subset of
    /// `releasing.keys` by its own invariant, so adding it would change no answer.
    ///
    /// **Read by the snapshot as well as by the gate**, through `activeLeaseView()`. One
    /// definition, because two would disagree the moment either moved. The three refusals it
    /// stands in for, and what the disagreement looked like:
    /// handback-ledger.md § *"What the snapshot is told"*.
    ///
    /// `internal` since #128 moved `refuseIfForeignManualControl(_:wanting:)` out. It is
    /// **derived and read-only**, and `activeLeaseView()` — `internal`, and what the control
    /// plane calls — already returns exactly this set, so the widening exposes nothing new.
    /// The three registers it unions stay `private`: this is the union, not a way to reach
    /// them.
    var fansAeolusIsAccountableFor: Set<Int> {
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
    /// It is also the one place the other two registers are cleared, and where each clear sits
    /// is load-bearing in both cases. The `defer` is **inside the same loop as the decrement**,
    /// after it, so `handbackUnconfirmed` loses a fan exactly when its last outstanding restore
    /// returns rather than while another is in flight, and being **in a `defer`** is what makes
    /// a fan the firmware refused leave that set and land in `restoreAbandoned` through the
    /// union below — D33's *"converts to the durable set through the path that already exists"*.
    /// The `restoreAbandoned` clear below the await is the **only** one
    /// ([#189](https://github.com/blamechris/Aeolus/issues/189)) and is conditioned on the
    /// restorer's own report rather than on the call having been made.
    ///
    /// Why that ordering survives clearing having made this mutation non-additive, why a
    /// restore that never returns leaves a fan unconfirmed for the life of the process, and why
    /// the intersection below is not a blanket subtraction: handback-ledger.md § *"Where each
    /// register ends"*.
    ///
    /// - Note: **The overlap the count exists for is unreachable in this build, and the count
    ///   is therefore not load-bearing today.** Replacing it with set membership passes the
    ///   whole suite; it is written this way because the overlap becomes reachable the moment
    ///   either of the two facts that make it unreachable changes. Recorded rather than
    ///   implied, so nobody simplifies it believing a test is watching — handback-ledger.md
    ///   § *"`releasing` — the transient half"* names both facts.
    private func restore(_ fans: Set<Int>, because cause: FanRestoreCause) async {
        log.restored(fans: fans, because: cause)
        for fan in fans { releasing[fan, default: 0] += 1 }
        defer {
            for fan in fans {
                guard let outstanding = releasing[fan] else { continue }
                guard outstanding > 1 else {
                    releasing[fan] = nil
                    handbackUnconfirmed.remove(fan)
                    continue
                }
                releasing[fan] = outstanding - 1
            }
        }
        // Whatever came back was not handed back. Recorded rather than dropped: the fan is
        // in a mode nothing has confirmed, so the next `acquireLease` over it is refused
        // durably instead of being told to retry a window that has closed.
        let abandoned = await restorer.restoreToAutomatic(fans: fans, because: cause)
        restoreAbandoned.formUnion(abandoned)

        // And whatever the restorer did *not* name came back. For a fan that was already in
        // the durable register that is the one fact that lifts it — the firmware refused this
        // fan's handback before, was asked again, and this time did not refuse. The
        // intersection is what keeps this from being a blanket subtraction: it names only fans
        // the register actually held, so the log line below reports a refusal being lifted
        // rather than firing on every ordinary teardown.
        let recovered = restoreAbandoned.intersection(fans.subtracting(abandoned))
        guard !recovered.isEmpty else { return }
        restoreAbandoned.subtract(recovered)
        log.recoveredAbandonedHandback(fans: recovered, because: cause)
    }
}
