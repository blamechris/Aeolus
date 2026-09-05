import AeolusXPC
import FanKit
import Foundation

/// The helper's `FanAuthority`: the read path it already had, and the lease core behind it.
///
/// It replaces `ReadOnlyFanAuthority` at the composition root. Until #163 that type *was*
/// the helper's authority, and every control verb on it threw a hard-coded refusal —
/// truthfully, because no lease core was wired into the daemon at all. Every E5 mechanism
/// that had merged was therefore inert in production, which is the finding #103 was reopened
/// on.
///
/// ## What actually changed, which is less than it looks
///
/// On this machine, today, a client sees the same thing it saw before: the same fans, the
/// same sensors, `activeLease: nil`, and every fan
/// `manualControlAvailability: .unavailable(.writePathNotBuilt)`. `SMCFanControlPlane`
/// answers `FanWriteCapability.notBuilt`, so `LeaseAuthority.acquireLease` refuses before it
/// reaches anything else. What changed is **where the refusal comes from**: a literal in a
/// type that could not have done otherwise has become a gate reading the seam that would
/// have to perform the write. The mechanisms behind it — the lease table, both teardown
/// paths, § 3, § 5 — are now running rather than merely present.
///
/// ## It holds no plane, no capability reporter, and cannot write
///
/// It holds the read path and the lease core. Not a `FanControlPlane`: that would put
/// `commandTarget(_:)` one `await` from a decoded client message, which is the shape E2
/// froze this seam to prevent — see `FanControlPlane` and `FanStateSensing` for the same
/// argument made twice already. And not a `FanWriteCapabilityReporting` either, which is a
/// correction rather than an omission. An earlier draft of this file stored one and
/// documented it as *"why `apply` refuses"*, while `apply`'s own documentation said the
/// opposite two screens below: the refusal is **not** sourced from the seam, because there
/// is no control loop here for a capable seam to reach. A stored property no method reads,
/// carrying a doc comment that asserts a gate, is the same defect as the literal this file
/// replaced — so it is gone, and `supervisedApplyRefusesEvenWhenTheSeamCanWrite` pins the
/// behaviour it claimed to explain.
///
/// The capability gate that *is* consulted lives one layer down, in
/// `LeaseAuthority.acquireLease`, where a refusal still stops a write from being attempted.
/// E3 adds the control loop; it does not add it here by accident first.
///
/// ## The composition, in one line each
///
/// - `snapshot` — the read path, plus the lease the lease core reports.
/// - `acquireLease` / `renewLease` / `releaseLease` / `connectionDidInvalidate` — the lease
///   core, verbatim. Every signature already matched, which is what `LeaseAuthority`'s own
///   documentation predicted: *"every method below carries a `FanAuthority` signature
///   verbatim, so the helper's control plane composes it with one-line forwards."*
/// - `apply` — authorises, then refuses. There is no control loop to apply anything with.
/// - `restoreAllToAutomatic` — § 7's panic verb, as much of it as this build can perform.
struct SupervisedFanAuthority: FanAuthority {

    /// The snapshot path, unchanged: `SMCFanEnumeration`, the discovered sensor set, and
    /// `F<n>Md` per fan, all through the scheduler's snapshot reader.
    ///
    /// Composed rather than absorbed. Its discovery cache, its once-per-process `readAll()`
    /// invariant and its per-fan unreadable-mode throttle are all state that belongs to
    /// reading the machine, and moving them here to save an indirection would put them in the
    /// same type as the privilege boundary's control verbs.
    private let reading: ReadOnlyFanAuthority

    private let leases: LeaseAuthority

    /// E5.4d's teardown gate, closed by `SignalTeardown` before it hands the fans back.
    ///
    /// **Owned here and exposed, rather than injected**, which is the opposite of the rule
    /// `LeaseAuthority` states about its latch — *"a defaulted latch would compile and
    /// report a bit nothing sets"* — and the difference is worth stating rather than
    /// leaving to be re-derived. That hazard is a *second instance*: two mechanisms each
    /// holding a private latch, one setting a bit the other cannot see. Here there is
    /// exactly one gate, it is the one the refusals below read, and `HelperComposition`
    /// hands *this* instance to the teardown. A constructor parameter would let a caller
    /// build an authority whose gate nothing closes, which is the same defect through the
    /// other door.
    ///
    /// It is deliberately not `private`: the composition root has to reach it, and a gate
    /// nothing outside this type could close would be a gate that never closes.
    let controlGate = ControlMessageGate()

    private let log: HelperLog

    init(reading: ReadOnlyFanAuthority, leases: LeaseAuthority, log: HelperLog) {
        self.reading = reading
        self.leases = leases
        self.log = log
    }

    // MARK: - Reporting

    /// The machine, then the lease — in that order, deliberately.
    ///
    /// A snapshot's `capturedAt` comes from the read path and covers ~0.5 s of subset reads
    /// on this machine, so the lease is read at one end of that span whichever end is chosen.
    /// It is read at the **end** because `LeaseAuthority.activeLease()` sweeps anything
    /// lapsed first: taken before the reads, a lease that expired during them would be
    /// reported as live, and a client shown a lease that has already stopped holding the fans
    /// is `CLAUDE.md` rule 6 exactly. Taken after, the worst case is a lease granted during
    /// the reads appearing beside fan values from a moment before it existed — a fan reported
    /// automatic under a lease that has not yet commanded anything, which is a true statement
    /// about both.
    ///
    /// The lease is read as a **view** — the lease itself and every fan Aeolus is
    /// accountable for, in one hop — because that fan set is not on the wire and this method
    /// needs it. A fan in manual that Aeolus is not accountable for is under something
    /// else's control and is reported as
    /// `ManualControlAvailability.Reason.foreignManualControl`
    /// ([ADR 0011](../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md)); a fan
    /// in manual that Aeolus put there is not, and `F<n>Md` cannot tell them apart on its
    /// own. Asking for the lease and the fan set in two hops could answer from two views of
    /// the lease core and report Aeolus's own fan as somebody else's, which is `CLAUDE.md`
    /// rule 6 pointed at the user rather than at the client.
    ///
    /// **Accountable for, not merely leasing.** The set is `LeaseAuthority`'s own
    /// `fansAeolusIsAccountableFor` — leases, fans mid-handback, and fans whose handback was
    /// abandoned — which is the identical set the grant path judges against. The narrower
    /// "the first lease's fans" this used to read reported a fan Aeolus pinned and could not
    /// give back as another program's doing, which is the worst of the available wrong
    /// answers: it sends a user to quit software that is not holding their fan.
    ///
    /// **The re-statement touches one field of one fan and nothing else.** The rule, and the
    /// § 5 causes it deliberately does not overwrite, are in
    /// `ReadOnlyFanReport.reportingForeignControl(of:heldByAeolus:)`. The other three
    /// snapshot fields are the read path's own and are passed through untouched: this
    /// re-assembles the value rather than producing a second opinion about any of them.
    func snapshot() async throws -> SystemSnapshot {
        let machine = try await reading.snapshot()
        let held = await leases.activeLeaseView()
        return SystemSnapshot(
            fans: machine.fans.map {
                ReadOnlyFanReport.reportingForeignControl(
                    of: $0, heldByAeolus: held.accountableFans)
            },
            sensors: machine.sensors,
            activeLease: held.lease,
            isThermalEmergencyActive: machine.isThermalEmergencyActive,
            capturedAt: machine.capturedAt
        )
    }

    // MARK: - Control

    func acquireLease(
        _ request: LeaseRequest,
        from connection: ConnectionID
    ) async throws -> Lease {
        try await refuseIfShuttingDown(connection, message: "acquireLease")
        return try await leases.acquireLease(request, from: connection)
    }

    func renewLease(id: UUID, from connection: ConnectionID) async throws -> Lease {
        try await refuseIfShuttingDown(connection, message: "renewLease")
        return try await leases.renewLease(id: id, from: connection)
    }

    func releaseLease(id: UUID, from connection: ConnectionID) async throws {
        try await leases.releaseLease(id: id, from: connection)
    }

    /// Authorises, and then refuses.
    ///
    /// The authorisation is not ceremony: `heldLease(id:from:)` distinguishes "no such
    /// lease", "not yours" and "expired", and a client debugging its own lease handling is
    /// entitled to those answers rather than to a blanket refusal that hides them. It is also
    /// what keeps this method honest the day the control loop lands — the check will already
    /// be here, in front of the write, rather than being added alongside it.
    ///
    /// The refusal is `.writePathNotBuilt` unconditionally, and it is **not** a literal
    /// standing in for the seam's `writeCapability`: there is no control loop in this type
    /// for a capable plane to reach, so this type holds no capability reporter to consult —
    /// see the note at the top of the file for why an unread one was removed rather than
    /// left as decoration. A `.built` seam behind a helper with nothing to apply is a state
    /// only a test can produce, and `supervisedApplyRefusesEvenWhenTheSeamCanWrite` produces
    /// it: answering it any other way would claim a capability this file does not contain.
    /// E3 owns the body; #17 owns the curve behind it.
    func apply(
        _ settings: [FanSetting],
        leaseID: UUID,
        from connection: ConnectionID
    ) async throws {
        try await refuseIfShuttingDown(connection, message: "apply")
        _ = try await leases.heldLease(id: leaseID, from: connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    /// Drops every lease and restores the fans they covered.
    ///
    /// `docs/SAFETY.md` § 7's panic verb, as much of it as exists. `releaseEveryLease()` is
    /// the lease core's half and it is real work now: each dropped lease's fans go through
    /// `HelperFanRestorer`, so both safety registries are told and the firmware is asked.
    ///
    /// **It does not additionally call `restoreToAutomatic(.everyFan)` on the plane**, and
    /// that is a decision rather than an omission. That verb throws `.controlPathNotBuilt`
    /// unconditionally in this build, so calling it would convert a v1 message that succeeds
    /// into one that always fails, while leaving the machine in precisely the same state.
    /// The message's contract is frozen at v1 ([#159](https://github.com/blamechris/Aeolus/issues/159))
    /// and keeps the fewest preconditions it can have. A fan some *other* tool left in manual
    /// is not this verb's to clear either — startup reconciliation owns it
    /// ([#164](https://github.com/blamechris/Aeolus/issues/164)), and E5.4d wires the machine-wide
    /// restore to the signal handlers ([#166](https://github.com/blamechris/Aeolus/issues/166))
    /// once there is a write path for it to use.
    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        await leases.releaseEveryLease()
        log.restoredAllToAutomatic(connection: connection)
    }

    func connectionDidInvalidate(_ connection: ConnectionID) async {
        await leases.connectionDidInvalidate(connection)
    }

    // MARK: - The teardown gate

    /// Refuses a control verb once `SignalTeardown` has begun.
    ///
    /// ## Which verbs, and why not all of them
    ///
    /// The three verbs that call this are the three that can leave a fan off automatic
    /// control, now or once E3 supplies a control loop: `acquireLease` creates the lease
    /// that authorises a write, `renewLease` extends one, and `apply` is the write. Nothing
    /// else is gated, and each exemption is a decision:
    ///
    /// - `releaseLease` and `restoreAllToAutomatic` move *toward* the safe state.
    ///   `HelperConnectionSession.restoreAllToAutomatic()` already argues the general case —
    ///   refusing to hand fans back because the connection is dying would be a safety
    ///   mechanism defeating safety — and it reads the same with "the helper" in place of
    ///   "the connection".
    /// - `connectionDidInvalidate` is a teardown, not a request. A client dying during the
    ///   helper's shutdown must still have its leases released.
    /// - `snapshot` writes nothing. A client watching the helper go down is entitled to see
    ///   what it sees, and refusing would tell it less than the truth.
    ///
    /// ## The refusal is `helperFailed`, and no new fault case was added
    ///
    /// `AeolusXPCFault.helperFailed(detail:)` is the vocabulary's stated home for "the
    /// helper could not carry out the request, for a reason no other code here names", and
    /// no other code names this one. Every alternative asserts something false:
    /// `manualControlUnavailable(.writePathNotBuilt)` blames the build for a refusal that
    /// would stand on a build with a write path, and `thermalEmergencyActive` would send a
    /// client looking at temperatures. `AeolusXPCVersion` therefore does not move.
    private func refuseIfShuttingDown(_ connection: ConnectionID, message: String) async throws {
        guard await controlGate.isClosed else { return }
        log.refusedDuringTeardown(connection, message: message)
        throw Self.shuttingDown
    }

    /// The refusal a control verb gets once the teardown has begun. Fixed text: it describes
    /// the helper and never quotes anything a client sent.
    private static let shuttingDown = AeolusXPCFault.helperFailed(
        detail: "the helper is shutting down")
}
