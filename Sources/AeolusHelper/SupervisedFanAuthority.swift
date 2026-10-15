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
/// Since [#194](https://github.com/blamechris/Aeolus/issues/194) the *snapshot's* answer is
/// sourced from that same seam rather than written out — `ReadOnlyFanAuthority.writeCapability`
/// — so the sentence above stays true of this build and stops being true of the build that can
/// write, which is the whole point of it.
///
/// ## It holds no plane, and the one write it can name is the keystone
///
/// It holds the read path, the lease core, and two narrow roles of the plane:
/// `KeystoneRestoring`, whose one verb is `restoreToAutomatic(_:)`, and
/// `FanWriteCapabilityReporting` ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md)
/// D5). Not a `FanControlPlane`: that would put `commandTarget(_:)` one `await` from a decoded
/// client message, which is the shape E2 froze this seam to prevent — see `FanControlPlane`
/// and `FanStateSensing` for the same argument made twice already. A restore is the one write
/// a client message may cause, because its only expressible effect is the safe state, and § 7
/// issues it only on a plane whose capability is `.built`.
/// `AuthorityRoleTripwireTests` holds this file to the two roles.
///
/// **The capability reporter is back, and this time something reads it.** An earlier draft of
/// this file stored one and documented it as *"why `apply` refuses"*, while `apply`'s own
/// documentation said the opposite two screens below: the refusal is **not** sourced from the
/// seam, because there is no control loop here for a capable seam to reach. A stored property
/// no method read, carrying a doc comment that asserted a gate, was the same defect as the
/// literal this file replaced, so it was removed as decoration. It returned for § 7, whose
/// panic verb reads it before the machine-wide restore. `apply` still does not read it, and
/// `supervisedApplyRefusesEvenWhenTheSeamCanWrite` still pins that.
///
/// The capability gate that stops a forward write lives one layer down, in
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
/// - `restoreAllToAutomatic` — § 7's panic verb: every lease, then the machine-wide restore on
///   a plane that can write, then the read-back, with every grant refused until all three end.
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

    /// § 6's durable refusals, for step 5 of the availability ladder
    /// ([#204](https://github.com/blamechris/Aeolus/issues/204)).
    ///
    /// Required rather than defaulted, for `controlGate`'s reason turned around: a default of
    /// "nothing refused" would compile and let a caller build an authority whose snapshot
    /// offers control the grant path refuses. `HelperComposition` hands it the same
    /// `StartupReconciliation` the lease core asks.
    private let reconciliation: any ReconciliationBaselineReporting

    /// § 7's machine-wide restore: the keystone and nothing else.
    ///
    /// `HelperComposition` hands it a `SafetyActorWriter` at `.panicRestore`, the level of every
    /// other machine-wide restore — provenance only, since nothing reads that level — typed as
    /// the role. The writer itself can command a fan; the role it is held as cannot, so this
    /// file cannot name a fan command.
    private let keystone: any KeystoneRestoring

    /// Whether the plane behind `keystone` can write at all, asked before the restore.
    ///
    /// The same seam the lease core and the snapshot are given, so § 7 and the grant path read
    /// one property. On `.notBuilt` the restore is not issued: the plane would only throw
    /// `.controlPathNotBuilt`, and a build that cannot write cannot have taken a fan off
    /// automatic control.
    private let writeCapability: any FanWriteCapabilityReporting

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

    /// `keystone` and `writeCapability` are required, for `reconciliation`'s reason: a default
    /// would compile and build a panic verb that never restores, or one that never asks.
    init(
        reading: ReadOnlyFanAuthority, leases: LeaseAuthority,
        reconciliation: some ReconciliationBaselineReporting,
        keystone: some KeystoneRestoring,
        writeCapability: some FanWriteCapabilityReporting,
        log: HelperLog
    ) {
        self.reading = reading
        self.leases = leases
        self.reconciliation = reconciliation
        self.keystone = keystone
        self.writeCapability = writeCapability
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
    /// `ManualControlAvailability.Reason.foreignManualControl` — unless § 3 is keeping it after a
    /// restore Aeolus issued, which the view carries apart and is `.restoreToAutomaticUnconfirmed`
    /// (#303)
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
    /// **The view carries the three handback registers apart as well, since
    /// [#187](https://github.com/blamechris/Aeolus/issues/187).** Before it, those registers
    /// reached a client only as an `acquireLease` fault, so a fan mid-handback — or one whose
    /// handback had been abandoned and never would complete — rendered as `.available` in the
    /// same instant a grant over it was refused. `CLAUDE.md` rule 6 in the read path: the user
    /// clicks, and the click fails for a reason the screen never showed. They are read in the
    /// same hop as the lease for the reason above, one cardinality down — a fan reported
    /// mid-handback from one view of the lease core and accountable-to-nobody from another
    /// would be one instant's report built from two.
    ///
    /// **The re-statement touches one field of one fan and nothing else.** The whole ordering
    /// is in `ReadOnlyFanReport` — see `AvailabilityRestatement.swift` for the ladder and
    /// `restatingAvailability(of:observedMode:given:reconciliation:)` for the entry point. Since
    /// [#355](https://github.com/blamechris/Aeolus/issues/355) neither half exempts a fan § 5
    /// gave up: its ledger is reported on `isReclaimedBySystem`, never as an availability. The
    /// other three snapshot fields are the read path's own and are passed through untouched:
    /// this re-assembles the value rather than producing a second opinion about any of them.
    ///
    /// **The machine read is `observe()`, not `snapshot()`**
    /// ([#360](https://github.com/blamechris/Aeolus/issues/360)): it hands back each fan's
    /// `F<n>Md` answer beside the snapshot built from it, because step 5 refuses a fan whose
    /// mode did not read and `FanState.mode` reports such a fan automatic.
    func snapshot() async throws -> SystemSnapshot {
        let machine = try await reading.observe()
        let view = await leases.activeLeaseView()
        // Its own hop, and that is safe for a reason the lease view does not share: the
        // baseline is fixed before the listener resumes, so no two reads of it can differ.
        let baseline = await reconciliation.baseline()
        return SystemSnapshot(
            fans: machine.snapshot.fans.map {
                ReadOnlyFanReport.restatingAvailability(
                    of: $0, observedMode: machine.modes[$0.index], given: view,
                    reconciliation: baseline)
            },
            sensors: machine.snapshot.sensors,
            activeLease: view.lease,
            isThermalEmergencyActive: machine.snapshot.isThermalEmergencyActive,
            capturedAt: machine.snapshot.capturedAt
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
    /// for a capable plane to reach, so the capability reporter this type holds for § 7 is
    /// deliberately not consulted here — see the note at the top of the file for why one was
    /// once removed as decoration. A `.built` seam behind a helper with nothing to apply is a
    /// state only a test can produce, and `supervisedApplyRefusesEvenWhenTheSeamCanWrite`
    /// produces it: answering it any other way would claim a capability this file does not
    /// contain. E3 owns the body; #17 owns the curve behind it.
    func apply(
        _ settings: [FanSetting],
        leaseID: UUID,
        from connection: ConnectionID
    ) async throws {
        try await refuseIfShuttingDown(connection, message: "apply")
        _ = try await leases.heldLease(id: leaseID, from: connection)
        throw AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
    }

    /// Drops every lease, issues the machine-wide restore on a plane that can write, and reads
    /// back the handbacks the firmware accepted — in that order.
    ///
    /// `docs/SAFETY.md` § 7's panic verb, in three acts:
    ///
    /// 1. **`releaseEveryLease()`**, the lease core's half: each dropped lease's fans, and every
    ///    fan whose handback was abandoned (#189), go through `HelperFanRestorer`, so both
    ///    safety registries are told and the firmware is asked, per fan.
    /// 2. **`restoreToAutomatic(.everyFan)`, if and only if `writeCapability` is `.built`**
    ///    ([ADR 0014](../../docs/ADR/0014-apple-silicon-unlock.md) D5). It reaches what the
    ///    sweep cannot: a fan another tool pinned under no lease, one reconciliation recorded
    ///    as `handbackRefused`, and the force key, which only `.everyFan` clears. On
    ///    `.notBuilt`, which is every build on `main` today, it is not issued: the plane would
    ///    throw `.controlPathNotBuilt`, and a build that cannot write cannot have put a fan into
    ///    manual.
    /// 3. **`confirmAcceptedHandbacks()`**, #291's read-back, which lifts a refusal whose
    ///    handback the firmware accepted. It comes **after** the keystone, never before it: a
    ///    read queued ahead of a keystone holds it for as long as the read takes (ADR 0007's
    ///    2026-09-20 amendment). With no keystone behind it, a read that never returns holds
    ///    this client's reply and the grant seal below — every grant refused, the safe
    ///    direction — and no restore.
    ///
    /// **All three run inside `LeaseAuthority.sealingGrants(during:)`**
    /// ([#350](https://github.com/blamechris/Aeolus/issues/350)), from before the sweep empties
    /// the table until after the read-back, and `acquireLease` refuses `.releaseInProgress` for
    /// as long as it is open. So no lease is granted that the restore in flight would undo. The
    /// seal gates grants only: the restore reads nothing from it and waits on nothing new.
    ///
    /// **The reply is v1's "accepted" in every case, so `AeolusXPCVersion` does not move.** A
    /// refused machine-wide restore is caught here — explicitly, never with `try?` — and logged
    /// at `.fault`, and the message still succeeds. The verb answers *accepted*, never *done*
    /// (ADR 0013): the snapshot's existing reasons report each fan, and the fault line is the
    /// only report of a force key left set. Until ADR 0014 this paragraph declined the restore,
    /// because the plane verb throws on this build and a v1 message that succeeds would have
    /// become one that always fails ([#159](https://github.com/blamechris/Aeolus/issues/159)).
    /// Catching the throw keeps the success and the restore both, and the `.built` gate keeps
    /// the call off a plane that has nothing to write with.
    ///
    /// **This paragraph is the one place that decision lives, and `PanicPathScopeTripwireTests`
    /// is what makes that structural.** It fails when the body below stops naming the three acts
    /// in this order inside the seal, or stops gating the second on `.built`, and its message is
    /// the list of documentation that describes this verb's scope — the sites that once said it
    /// restored every fan when it did not ([#228](https://github.com/blamechris/Aeolus/issues/228),
    /// [#222](https://github.com/blamechris/Aeolus/issues/222)).
    func restoreAllToAutomatic(from connection: ConnectionID) async throws {
        let machineWide = await leases.sealingGrants {
            await leases.releaseEveryLease()
            var machineWide = HelperLog.MachineWideRestore.noWritePath
            if writeCapability.writeCapability == .built {
                do {
                    try await keystone.restoreToAutomatic(.everyFan)
                    machineWide = .accepted
                } catch {
                    log.panicRestoreRefused(
                        connection: connection, detail: String(describing: error))
                    machineWide = .refused
                }
            }
            // #291: the read-back that lifts a refusal whose handback the firmware just
            // accepted. A read, never a write, and here rather than inside the teardown because
            // this verb queues no keystone behind it — its own is issued above, ahead of the
            // read. See `LeaseAuthority.confirmAcceptedHandbacks()`.
            await leases.confirmAcceptedHandbacks()
            return machineWide
        }
        log.restoredAllToAutomatic(connection: connection, machineWide: machineWide)
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
