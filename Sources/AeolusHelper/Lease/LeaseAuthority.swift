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
/// The third arrived with #124 and is a suspension point in `acquireLease` that an earlier
/// version of this paragraph hid; since #134 it asks whether § 3 can see rather than reading
/// the curated set now ([ADR 0010](../../../docs/ADR/0010-coalesced-supervisor-reads.md)).
/// handback-ledger.md § *"Where this sits: the third role, and the swap from #134"*.
///
/// **Still no write of any kind** — `SMCConnection.write` is SPI-gated and still
/// throws, and no write selector exists anywhere in `Sources/`.
///
/// Tests run it against the shipped cache over the scripted firmware, not a hand-rolled
/// double, so emptying `CriticalSensorSet.mac16x5` turns the lease suite red.
/// handback-ledger.md § *"Where this sits: what the lease suite runs against"*.
///
/// ## One lease at a time, and why the contract settles it
///
/// A snapshot reports one global `activeLease` and the wire shape is frozen at v1, so a
/// second lease would be unreportable; it is refused with
/// `.manualControlUnavailable(reason: .leaseHeldByAnotherClient)`.
/// handback-ledger.md § *"One lease at a time, and why the contract settles it"*.
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
///
/// Relocating prose cannot relieve `type_body_length`, which counts this body's code: about 85
/// lines of headroom remain before its error at 350. New behaviour belongs in value types and
/// the `EngagementDriver` (ADR 0014), not in this actor.
actor LeaseAuthority: HeldLeaseRole {

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
    /// heldByAeolus:awaitingConfirmation:)`, which answers with a
    /// `ManualControlAvailability.Reason` and touches no fan.
    let foreignControl: any ForeignManualControlSensing

    /// § 3's fans awaiting confirmation of a restore Aeolus issued (#303), as a role and never the
    /// actor. `nil` until bound, which answers `.foreignManualControl` — still a refusal.
    private(set) var emergencyRestores: (any EmergencyRestoreConfirming)?

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
    /// the one thing that clears it is a restore the restorer did *not* give up on **and** a
    /// later read reporting automatic (#291, `confirmAcceptedHandbacks()`).
    /// **A restore that never returns leaves it standing**, as does one refused again, and
    /// both are the fail-safe direction.
    ///
    /// Why the register was self-sealing until #189, why the clearing standard is the one
    /// `HelperFanRestorer` already deregisters § 3's registry on, and why a weaker one would
    /// lift a refusal three observed firmware refusals set on evidence about a call:
    /// handback-ledger.md § *"`restoreAbandoned` — the durable half"*.
    private var restoreAbandoned: Set<Int> = []

    /// Fans in `restoreAbandoned` whose latest restore the firmware **accepted**, owed a
    /// read-back before the refusal lifts (#291). Always a subset of `restoreAbandoned`:
    /// handback-ledger.md § *"Accepted is not automatic"*.
    private var handbackAcceptedUnconfirmed: Set<Int> = []

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
    /// Set before § 4's teardown and cleared on `.didWake`, so no lease can be taken in the
    /// window where the table is empty and the machine is about to sleep. A wake that never
    /// comes refuses every lease, which is the fail-safe direction.
    /// handback-ledger.md § *"`sleepSeal` — why the table is closed for a sleep"*.
    ///
    /// **Hearing them out of order is a different case, and it is guarded** — see
    /// `wakesAheadOfTheirSeal`. The fail-safe argument above covers a wake that never comes;
    /// it does not cover one that came and was answered before the seal it belonged to was
    /// ever set, which leaves the seal standing over a machine that is demonstrably awake.
    private var sleepSeal = false

    /// The generation of the latest `.didWake` this actor has been told about.
    ///
    /// `SystemPowerObserver.deliver(_:acknowledging:)` spawns an unstructured `Task` per
    /// event, so IOKit's serial queue orders the **spawns** and nothing orders the bodies. If
    /// the `.willSleep` body is starved past the kernel's ~30 s acknowledgement window the
    /// machine sleeps regardless, and on wake the `.didWake` body can reach
    /// `unsealAfterWake(generation:)` first. The seal for that episode then arrives *after*
    /// its own wake, and setting it would refuse every lease on a machine that is awake in
    /// front of its user until the next sleep and wake.
    ///
    /// Comparing generations answers that exactly: a seal is declined when a **strictly
    /// later** wake has already been seen, because that wake proves the episode is over. No
    /// state accumulates and nothing is spent, so there is no reachable state in which the
    /// seal stops being set and stays that way.
    ///
    /// **The first attempt counted instead, and it latched** — one unpaired wake disabled the
    /// seal for the life of the process, turning a fail-safe defect into a fail-dangerous one.
    /// Why counting cannot work here, and what a declined seal did to the count:
    /// handback-ledger.md § *"Pairing a sleep with its own wake"*.
    ///
    /// **What this does not claim**: the starved body still drops every lease and restores
    /// after the wake, and the client is never told it lost the lease. Bounded and honest
    /// rather than thermal — handback-ledger.md § *"Pairing a sleep with its own wake"*.
    private var latestWakeGeneration: UInt64 = 0

    /// The generation of the `.willSleep` whose seal is currently standing.
    ///
    /// Without it a *stale* wake would clear a live seal: if episode 2's `.willSleep` body
    /// runs before episode 1's starved `.didWake` body, that late wake is older than the seal
    /// it would otherwise open, and the machine is at that moment going to sleep. A wake
    /// clears the seal only when it is newer than the seal standing.
    private var sealGeneration: UInt64 = 0

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

    /// Binds § 3's role; `HelperComposition.bindSafetyRegistries()` calls it with the others.
    func bind(emergencyRestores: some EmergencyRestoreConfirming) {
        self.emergencyRestores = emergencyRestores
    }

    // MARK: - Acquisition

    /// Grants manual control of the requested fans, or refuses.
    ///
    /// The order of the steps is the design, so it is worth reading as one:
    ///
    /// 0. – 3. In this order: the build's own write capability, self-renewal, TTL and holder
    ///    re-validation, then the suspension points (enumerate, sweep lapsed leases, § 3's
    ///    latch, sightedness, foreign control). Why each sits where it does:
    ///    handback-ledger.md § *"The order of `acquireLease`'s steps"*.
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
        let exempted = try await refuseIfForeignManualControl(
            connection, wanting: Set(request.fanIndices).intersection(enumerated))

        // ---- No `await` below this line. Adding one reopens #95. ----
        try AeolusXPCValidation.validateFanIndices(
            request.fanIndices, enumeratedFanIndices: enumerated)
        try refuseIfInvalidated(connection)
        // The five refusals in this straight-line region are ordered by how long they last,
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
        // Last, and least durable: a fan exempted above whose handback landed since (#311).
        try refuseIfExemptionLapsed(connection, exempted: exempted)

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
    /// Takes no instant, and shares no code path with connection invalidation beyond the
    /// terminal action — the independence ADR 0005 requires.
    /// handback-ledger.md § *"`expireLapsedLeases`: no instant, and no shared path"*.
    ///
    /// Entries are removed **before** the restore is awaited, so a call interleaving during
    /// the restore finds an empty table and cannot restore the same fans twice. The whole
    /// sweep is then handed back in **one** `restore` call, not one per entry
    /// ([#188](https://github.com/blamechris/Aeolus/issues/188)), which is how every teardown
    /// path here is written — handback-ledger.md § *"One restore call per sweep"* has the
    /// argument, and `TeardownSweepTripwireTests` makes a return to the per-entry shape fail.
    ///
    /// - Warning: removing before restoring means an emptied table can admit a new lease over
    ///   a fan whose restore is still in flight. Only the capability gate holds that shut today;
    ///   #102 owns the interlock. handback-ledger.md § *"The warning on `expireLapsedLeases`"*.
    func expireLapsedLeases() async {
        let lapsed = table.removeLapsed(asOf: clock.now)
        guard !lapsed.isEmpty else { return }
        let fans = lapsed.reduce(into: Set<Int>()) { $0.formUnion($1.fanIndices) }
        await restore(fans, because: .leaseExpired)
    }

    /// When the earliest outstanding lease lapses, or `nil` when none is outstanding. What
    /// `LeaseExpirySupervisor` sleeps until.
    func nextExpiryDeadline() -> ContinuousClock.Instant? { table.earliestDeadline }

    /// ADR 0009 D2's question about one lease and one fan, asked at `clock.now` by § 5 and the
    /// engagement driver — see `LeaseTable.covers(_:under:liveAt:)`. There is deliberately no
    /// form that asks whether *any* lease covers a fan (#357). It sweeps nothing: the TTL path
    /// hands lapsed fans back.
    func hasLiveLease(id: UUID, coveringFan fan: Int) -> Bool {
        table.covers(fan, under: id, liveAt: clock.now)
    }

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
    /// `docs/SAFETY.md` § 3's revocation: a claim taken from a client that did nothing wrong,
    /// not a lease ending, hence its own `FanRestoreCause`.
    /// handback-ledger.md § *"`revokeLeases` is a claim being taken, not a lease ending"*.
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

    /// Revokes the lease `id` names, **whole**, if it is live, and returns whether it did.
    ///
    /// § 5's terminal action (#353): it revokes the lease it was holding the fan for and no
    /// other. A lease already gone, or past its deadline, is not revoked — a lapsed one is left
    /// to the TTL sweep, which records `.leaseExpired` — so no client is told the system took
    /// control it had already given up. Removed synchronously before the one restore call, as
    /// every teardown here is (#188). handback-ledger.md § *"`revokeLease(id:because:)`: the one
    /// lease § 5 held the fan for"*.
    func revokeLease(id: UUID, because cause: FanRestoreCause) async -> Bool {
        guard let entry = table.entry(id: id), !entry.hasLapsed(asOf: clock.now) else {
            return false
        }
        table.remove(id: id)
        log.revoked(entry.connection, fans: entry.fanIndices, because: cause)
        await restore(entry.fanIndices, because: cause)
        return true
    }

    /// Revokes **every** live lease, whatever fans it covers.
    ///
    /// Selected by § 3 on every live lease, not on its registry of engaged fans: a client can
    /// hold a lease before it has engaged manual control, and the emergency takes that back on
    /// every cycle it holds, including cycles that read nothing (#134, #152). Lease-scoped, and
    /// deliberately not shared with `releaseEveryLease()`.
    /// handback-ledger.md § *"Why § 3 revokes every lease, and why it is not
    /// `releaseEveryLease()`"*.
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
    /// The lease core's half of `restoreAllToAutomatic`, and on every build on `main` today the
    /// whole of what that message performs. The contract is global rather than lease-scoped, so
    /// the handler follows this with `restoreToAutomatic(.everyFan)` on a plane whose capability
    /// is `.built` — there, not here: the decision, its gate and its order live at
    /// `SupervisedFanAuthority.restoreAllToAutomatic`. Read that before changing either.
    ///
    /// **Releasing leases is not restoring the machine**, and this paragraph was present
    /// indicative about the `.everyFan` call until
    /// [#228](https://github.com/blamechris/Aeolus/issues/228). What reaches the plane from
    /// here is one `restoreToAutomatic(.fan(index))` per fan in the sweep, through
    /// `KeystoneRestoreAttempt`. A fan another tool left in manual under no live lease is not
    /// touched, and on a plane that cannot write neither is the machine-wide `Ftst` force key —
    /// `.everyFan` is the only scope that always clears it, and this is not one of its call
    /// sites; the handler is. On a plane that can, a `.fan(index)` restore clears the key when it
    /// hands back the last fan the plane engaged (ADR 0014 D5).
    ///
    /// ## The sweep is the table **and** `restoreAbandoned`
    ///
    /// Sweeps the table and `restoreAbandoned` (#189) in one `restore` call; touches nothing
    /// foreign (ADR 0011); issues no machine-wide restore itself — the handler does, after this,
    /// on a plane that can write — and never fails the message (#159); and consults no
    /// per-`ConnectionID` state, the precondition for `HelperConnectionSession`'s teardown-gate
    /// exemption (#95).
    /// handback-ledger.md § *"`releaseEveryLease()`: what the sweep is, and what it is not"*.
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
    /// A seal whose own wake has already been answered is **not** set, and declining leaves
    /// any newer seal standing.
    /// handback-ledger.md § *"`sealForSleep`: declining a seal its wake already answered"*.
    ///
    /// - Parameter generation: the notification's place in the delivery order, stamped on
    ///   IOKit's serial queue — see `SystemPowerNotification.generation`.
    func sealForSleep(generation: UInt64) {
        guard generation > latestWakeGeneration else {
            log.declinedASealItsWakeAlreadyAnswered()
            return
        }
        guard !sleepSeal else { return }
        sleepSeal = true
        sealGeneration = generation
        log.sealedForSleep()
    }

    /// Reopens acquisition after a wake. Touches no fan and issues no write.
    ///
    /// The generation is recorded **whether or not there was a seal to clear**, because that
    /// is the record a later-arriving seal is compared against. A wake that is older than the
    /// seal standing is ignored for the clearing, and still counted for the ordering.
    ///
    /// - Parameter generation: as `sealForSleep(generation:)`.
    func unsealAfterWake(generation: UInt64) {
        latestWakeGeneration = max(latestWakeGeneration, generation)
        guard sleepSeal, generation > sealGeneration else { return }
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
    /// One hop, so the lease and the fan sets it is reported beside come from one view of this
    /// actor; since #187 it carries the three registers apart as well as their union.
    /// handback-ledger.md § *"`activeLeaseView()`: one hop, and three registers apart"*.
    ///
    /// The grant path has always judged against this set; the snapshot asks the same question of
    /// the same state, in the same hop. Both wrong answers an earlier version gave, and why the
    /// registers are returned rather than exposed as three more properties:
    /// handback-ledger.md § *"What the snapshot is told"*.
    func activeLeaseView() async -> LeaseAccountability {
        await expireLapsedLeases()
        // § 3 first, then this actor's fields with no await between them: see the field.
        let awaiting = await emergencyRestores?.fansAwaitingRestoreConfirmation ?? []
        return LeaseAccountability(
            lease: table.all.first?.asLease(),
            accountableFans: fansAeolusIsAccountableFor,
            abandonedHandbacks: restoreAbandoned,
            unconfirmedHandbacks: handbackUnconfirmed,
            handbacksInFlight: Set(releasing.keys),
            restoresAwaitingConfirmation: awaiting
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
    /// A revoked holder is not silently re-granted: the refusal holds until a fresh reading
    /// falls a hysteresis margin below the ceiling. It consumes `.thermalEmergencyActive`, so
    /// `AeolusXPCVersion` does not move.
    /// handback-ledger.md § *"`refuseIfThermalEmergencyActive`: a revoked holder is not
    /// silently re-granted"*.
    ///
    /// ## Why it sits above the blindness check
    ///
    /// The more consequential fact, and the only one of the two that costs no hardware round
    /// trip. handback-ledger.md § *"Why the thermal refusal sits above the blindness check"*.
    private func refuseIfThermalEmergencyActive(_ connection: ConnectionID) async throws {
        guard await thermalEmergency.isActive else { return }
        log.refusedThermalEmergency(connection)
        throw AeolusXPCFault.thermalEmergencyActive
    }

    /// Every fan the lease core answers for itself, so exempt from the foreign-control step.
    ///
    /// The lease `table`, `restoreAbandoned` and `releasing` each have a more precise refusal
    /// further down the grant path, so they are excluded from the foreign-control step.
    /// handback-ledger.md § *"`fansAeolusIsAccountableFor`: why these three are exempt"*.
    ///
    /// **Read by the snapshot as well as by the gate**, through `activeLeaseView()`. One
    /// definition, because two would disagree the moment either moved. The three refusals it
    /// stands in for, and what the disagreement looked like:
    /// handback-ledger.md § *"What the snapshot is told"*.
    ///
    /// `internal` since #128: derived and read-only, and `activeLeaseView()` already returns
    /// this set. handback-ledger.md § *"`fansAeolusIsAccountableFor` is `internal`, and why that
    /// exposes nothing"*.
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
    /// It is also where `handbackUnconfirmed` is cleared, and where that sits is load-bearing:
    /// the `defer` is **inside the same loop as the decrement**, after it, so a fan leaves
    /// exactly when its last outstanding restore returns, and being **in a `defer`** is what
    /// makes a refused fan land in `restoreAbandoned` through the union below — D33. It clears
    /// nothing from `restoreAbandoned` since #291; `confirmAcceptedHandbacks()` does.
    /// Why, and why a restore that never returns leaves a fan unconfirmed for the life of the
    /// process: handback-ledger.md § *"Where each register ends"*.
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

        // Refused again: no longer owed a read-back, and a `confirmAcceptedHandbacks()`
        // mid-read for it will not lift the refusal just renewed.
        handbackAcceptedUnconfirmed.subtract(abandoned)

        // A fan the register held whose write was accepted is only marked owed a read-back:
        // accepted is not automatic (#291), and the read is **not** taken here, because sleep
        // and SIGTERM issue the keystone only after this returns — handback-ledger.md
        // § *"Accepted is not automatic"*.
        let accepted = restoreAbandoned.intersection(fans.subtracting(abandoned))
        guard !accepted.isEmpty else { return }
        handbackAcceptedUnconfirmed.formUnion(accepted)
        log.abandonedHandbackAcceptedUnconfirmed(fans: accepted, because: cause)
    }

    /// Reads back every fan owed one and lifts the refusal over each that reads automatic.
    /// `docs/SAFETY.md` § 7's last act, after the lease release and any machine-wide keystone:
    /// the one caller with no keystone queued behind the read, because § 7 issues its own
    /// first. A fan that reads manual or will not read keeps its refusal, and stays owed. The
    /// set is re-read after the await, so a refusal renewed meanwhile is not lifted. Why each
    /// of these: handback-ledger.md § *"Accepted is not automatic"*.
    func confirmAcceptedHandbacks() async {
        let owed = handbackAcceptedUnconfirmed
        guard !owed.isEmpty else { return }
        let automatic = await foreignControl.fansReadingAutomatic(among: owed)
        let recovered = automatic.intersection(handbackAcceptedUnconfirmed)
        let unconfirmed = owed.subtracting(automatic)
        if !unconfirmed.isEmpty {
            log.abandonedHandbackStillUnconfirmed(fans: unconfirmed)
        }
        guard !recovered.isEmpty else { return }
        handbackAcceptedUnconfirmed.subtract(recovered)
        restoreAbandoned.subtract(recovered)
        log.recoveredAbandonedHandback(fans: recovered)
    }
}
