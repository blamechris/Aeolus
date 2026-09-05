import FanKit
import Foundation

/// `docs/SAFETY.md` § 6's crash coverage, and the only mechanism in the helper that can
/// clear a fan the *previous* process left behind.
///
/// ## Why it exists at all
///
/// Every other safety mechanism runs inside the helper, so helper death defeats all of them
/// at once — [ADR 0007](../../../docs/ADR/0007-safety-composition.md)'s first hole. The TTL
/// is not counted by anything, the watchdog is not watching, and the SMC keeps the last mode
/// that was written to it. Lease state is in memory and deliberately stays there: *"a lease
/// that survives its enforcer's death is a setting wearing a lease's name."* The only thing
/// that can notice is a **new** process, reading the firmware before it serves anybody.
///
/// This is that read, and [#165](https://github.com/blamechris/Aeolus/issues/165)'s
/// `KeepAlive` is what guarantees there is a new process at all. The two ship together and
/// ADR 0007 says why in one line: a restart policy without reconciliation restarts a helper
/// that then serves without checking what the SMC still holds.
///
/// ## Unconditional, and one-shot
///
/// [#103](https://github.com/blamechris/Aeolus/issues/103)'s decision A2, recorded as
/// [ADR 0011](../../../docs/ADR/0011-reconciliation-and-foreign-manual-control.md): the
/// helper does **not** try to work out who left a fan in manual before restoring it. It
/// cannot. `F<n>Md` reads `1` whether the fan was pinned by a dead Aeolus helper or by
/// another vendor's tool that is running right now, and every way of telling them apart —
/// a breadcrumb on disk, a scan of the process table — either makes a safety action
/// defeasible by a file somebody can delete or is clean-room-adjacent.
///
/// So the asymmetry decides it. Restoring another tool's fan hands it to Apple's thermal
/// management, which is a safe state, is visible, and is one click in that tool to undo.
/// Declining to restore leaves a fan possibly pinned *low* by Aeolus's own dead helper with
/// nothing counting a TTL — the failure `docs/SAFETY.md` opens with.
///
/// **And then it stops.** After this one pass, a fan found in manual that Aeolus did not
/// engage is foreign control, reported as
/// `ManualControlAvailability.Reason.foreignManualControl` and refused a lease — never
/// restored a second time. A restore loop against a live writer *is* the fight: two programs
/// undoing each other's mode write several times a second over a machine's cooling. That is
/// what `refusalForGrant(overFans:heldByAeolus:)` below is for, and it is why this type
/// outlives the bring-up that ran it.
///
/// ## What it deliberately does not do
///
/// It tells `ReclamationWatchdog` nothing. § 5's registry is fans **Aeolus** engaged, and a
/// foreign re-assertion is structurally invisible to it as a result — by design, because §
/// 5's diagnosis is "the system took a fan back from us", which is not what happened.
actor StartupReconciliation<Plane: FanControlPlane>: ForeignManualControlSensing {

    /// The seam every read goes through: one `.supervisor` turn per fan, sequentially.
    private let plane: Plane

    /// Which fans this machine has — the same `SMCFanEnumeration` the snapshot reads, so the
    /// set reconciled is the set a client is shown.
    ///
    /// Held here rather than passed to `reconcile()` so that an enumeration that throws is
    /// handled where this type's log is. A machine whose `FNum` will not read has no fan
    /// index that can be named at all: there is no `.fan(n)` to issue, and no honest set to
    /// record as unreconciled — which is precisely the case the machine-wide verb exists
    /// for, and it is reached for here (ruling D23/D24). An earlier draft declined it and
    /// argued that nothing was lost because `acquireLease` enumerates through this same seam
    /// and throws before it could grant anything. That argument is about *grants*, and this
    /// pass is not about grants: a fan the previous process left pinned stays pinned, on the
    /// cold-restart path this whole mechanism exists to cover, and refusing a lease over it
    /// does not spin it back down.
    private let enumeration: any FanEnumerating

    /// The keystone path for the per-fan restore — the same `HelperFanRestorer` the lease
    /// core's teardown uses, so a fan handed back here goes through
    /// [#110](https://github.com/blamechris/Aeolus/issues/110)'s bounded attempts.
    ///
    /// **It does not buy registry parity with an expiring lease, and an earlier version of
    /// this comment claimed it did.** `HelperFanRestorer` *deregisters*: it drops a fan from
    /// § 5's registry before the write and from § 3's after a write that landed. A fan
    /// reconciliation found in manual was in neither to begin with, because nothing in this
    /// process engaged it. So a restore that lands leaves it correctly in neither — and a
    /// restore the firmware **refuses** leaves it in neither while it is still pinned: § 3
    /// will not bridge it to maximum during an emergency, § 5 is not watching it, and this
    /// pass never runs again.
    ///
    /// That gap is real and is accepted rather than patched (ruling D23): registering the
    /// fan with § 3 needs a `CommandableFan`, and minting one for a fan that may belong to
    /// another program means writing to that program's fan during an emergency, which is the
    /// contest ADR 0011 exists to decline. What happens instead is `handbackRefused` —
    /// a durable refusal, so nothing is *claimed* over a fan nothing is watching. Recorded
    /// in ADR 0011's Consequences and held open by
    /// [#201](https://github.com/blamechris/Aeolus/issues/201).
    private let restorer: HelperFanRestorer<Plane>

    /// The machine-wide verb, at `docs/SAFETY.md` § 7's level, for the one case that needs
    /// it. Not routed through `restorer`: `HelperFanRestorer` documents at length why it
    /// issues `.fan(n)` and never `.everyFan`, and this is the caller that genuinely wants
    /// the machine-wide act rather than a loop over fans it could not enumerate the state of.
    private let panic: SafetyActorWriter<Plane>

    private let clock: any MonotonicClock
    private let budget: Duration
    private let log: SafetyLog

    /// Fans this pass never established the mode of. Empty after a complete run.
    ///
    /// Written once, by `reconcile()`, and read for the life of the process. It is
    /// durable in the strongest available sense: reconciliation is one-shot, so nothing
    /// revises it.
    private var unreconciled: Set<Int> = []

    /// The pass established nothing at all, because the machine's fans would not enumerate.
    ///
    /// `unreconciled` cannot carry this. It is a set of fan *indices*, and a machine whose
    /// `FNum` will not read has none to put in it — so the fact that nothing was looked at
    /// needs a flag of its own rather than an empty set that reads as "a complete run".
    /// Cleared only by a machine-wide restore that the firmware took, on the same argument
    /// `restoreEveryFan()` makes for clearing `unreconciled`.
    private var nothingEstablished = false

    /// Fans this pass found in manual, asked to hand back, and was refused.
    ///
    /// Durable, and the most precise of the three refusals this type produces: Aeolus asked
    /// the firmware for automatic control of the fan, spent #110's attempts, and the write
    /// never took — which is `ManualControlAvailability.Reason.restoreToAutomaticFailed`
    /// verbatim, *"it asked for automatic, was refused, and stopped asking"*. The lease core
    /// says exactly this about its own abandoned handbacks, from its own `restoreAbandoned`
    /// set, and this is the same fact reached at bring-up instead of at teardown.
    ///
    /// It is checked **ahead of** the fresh grant-time read rather than left to it, and that
    /// is the difference this set buys. The read would answer `.foreignManualControl` while
    /// the fan still reads manual and `nil` — a grant — the moment something else hands it
    /// back. Neither is honest about a fan Aeolus has proved it cannot return to automatic
    /// control: taking a lease over it would claim control this process has already
    /// demonstrated it cannot give up. Nothing is watching such a fan either
    /// ([#201](https://github.com/blamechris/Aeolus/issues/201)), which is the other half of
    /// why it is refused rather than judged afresh.
    ///
    /// **A later machine-wide restore does not clear it**, unlike `unreconciled` and
    /// `nothingEstablished`. Those two mean "the mode is unknown", which a `.everyFan` write
    /// the firmware took genuinely resolves. This one means "this fan refused *this* write",
    /// which a different verb succeeding does not un-demonstrate — and the fail-safe
    /// direction on a fan with a proven refusal is to keep refusing.
    private var handbackRefused: Set<Int> = []

    /// Whether the one-shot pass has run.
    ///
    /// One-shot is not an observation about the call site; it is the property the whole
    /// baseline rests on. A second pass would clear every durable refusal above and issue
    /// the second restore ADR 0011's D2 exists to refuse — the first move of the standing
    /// fight — so the guard is here, in the mechanism, rather than in the composition root
    /// that happens to call it once today.
    private var hasRun = false

    init(
        plane: Plane,
        enumeration: some FanEnumerating,
        restorer: HelperFanRestorer<Plane>,
        panic: SafetyActorWriter<Plane>,
        clock: some MonotonicClock = SystemMonotonicClock(),
        budget: Duration = ReconciliationLimits.budget,
        log: SafetyLog = SafetyLog()
    ) {
        self.plane = plane
        self.enumeration = enumeration
        self.restorer = restorer
        self.panic = panic
        self.clock = clock
        self.budget = budget
        self.log = log
    }

    // MARK: - The one-shot pass

    /// Enumerates the machine's fans, reads `F<n>Md` for each, and hands back anything found
    /// in manual.
    ///
    /// ## The order of the four outcomes
    ///
    /// 1. **A fan reads `manual`** → `restoreToAutomatic(.fan(n))` through the restorer,
    ///    logged at fault. Except a `.controlPathNotBuilt` refusal, which is *this build's
    ///    expected state* and logs at notice: `SMCFanControlPlane` has no write path, so
    ///    every restore here is refused, and a `.fault` line per fan per start would train
    ///    a reader to ignore the one that matters.
    /// 2. **A read throws** → the per-fan pass is abandoned and one unconditional
    ///    `restoreToAutomatic(.everyFan)` is issued. ADR 0007's assumption table already
    ///    settles this: *"`F0Md`/`Ftst` are readable for reconciliation … If it fails:
    ///    reconciliation falls back to unconditional restore-to-automatic at startup — safe
    ///    either way."* One unreadable fan means the helper cannot say which fans are held,
    ///    and the machine-wide verb needs no data at all — which is precisely why ADR 0007
    ///    makes it the keystone.
    /// 3. **The enumeration throws** → the same keystone, and nothing else can be done: no
    ///    fan index exists to name, so there is no per-fan restore to issue and no honest
    ///    set to record as unreconciled. `nothingEstablished` carries that instead, and
    ///    every grant is refused while it stands.
    /// 4. **The budget runs out** → the remaining fans go into `unreconciled`, the keystone
    ///    is issued for them, and the pass returns. The caller resumes the listener anyway;
    ///    every unreconciled fan is refused a lease durably. See `ReconciliationLimits.budget`.
    ///
    /// **The last three are one rule, applied wherever the pass cannot see** (ruling D24).
    /// A fan the budget never reached and a fan whose mode read threw are both fans of
    /// unknown mode; a machine whose fans will not enumerate is every fan of unknown mode.
    /// The keystone needs no data, which is exactly why ADR 0007 makes it the keystone, so
    /// there is no fact any of the three has that the others lack and no reason to treat one
    /// as more urgent. Issuing it over fans the pass *did* reach and found automatic costs
    /// nothing: the verb is idempotent over them.
    ///
    /// ## Sequential, one turn each
    ///
    /// The reads are a `for` loop with an `await` in it, never a task group.
    /// [#134](https://github.com/blamechris/Aeolus/issues/134) is about the number of
    /// *outstanding* `.supervisor` reads — each one drags a quota-forced snapshot turn along
    /// behind it once every `maxConsecutiveOvertakes` — and a fan-out here would widen
    /// exactly that, at the one moment in the process's life when the scheduler is coldest.
    /// Reconciliation has no deadline to race; it has a budget, which is the other thing.
    func reconcile() async {
        guard !hasRun else {
            log.reconciliationAlreadyRan()
            return
        }
        hasRun = true

        let fans: Set<Int>
        do {
            fans = try await enumeration.enumeratedFanIndices()
        } catch {
            log.reconciliationEnumerationFailed(detail: String(describing: error))
            // Set before the write, cleared after one that landed: a throw inside the
            // keystone must leave the durable refusal standing.
            nothingEstablished = true
            await restoreEveryFan(because: .enumerationFailed)
            return
        }

        let deadline = clock.now.advanced(by: budget)
        var remaining = fans.sorted()

        while let fan = remaining.first {
            guard clock.now < deadline else { break }
            remaining.removeFirst()

            let mode: FirmwareFanMode
            do {
                mode = try await plane.readControlState(ofFan: fan).mode
            } catch {
                // Everything not yet read is unknown, and so is this one. The machine-wide
                // restore covers all of them without needing to name any.
                unreconciled = Set(remaining).union([fan])
                log.reconciliationReadFailed(
                    fanAt: fan, detail: String(describing: error), unreconciled: unreconciled)
                await restoreEveryFan(because: .modeReadFailed)
                return
            }

            guard mode == .manual else { continue }
            await restore(fanAt: fan)
        }

        unreconciled = Set(remaining)
        guard !unreconciled.isEmpty else {
            log.reconciliationCompleted(fans: fans.count)
            return
        }
        log.reconciliationBudgetExhausted(unreconciled: unreconciled, budget: budget)
        await restoreEveryFan(because: .budgetExhausted)
    }

    /// One fan, through the keystone path, with the refusal this build always produces kept
    /// off the fault channel.
    private func restore(fanAt fan: Int) async {
        log.reconcilingManualFan(fanAt: fan)
        let abandoned = await restorer.restoreToAutomatic(
            fans: [fan], because: .startupReconciliation)
        guard abandoned.contains(fan) else { return }
        // The fan is still in manual, nothing else will clear it, and nothing is watching
        // it — see `restorer` and #201. It is not added to `unreconciled`, whose meaning is
        // "nobody looked": this fan was looked at and its mode *was* established. It goes
        // into `handbackRefused` instead, which is the fact this branch actually knows.
        handbackRefused.insert(fan)
        log.reconciliationRestoreRefused(fanAt: fan, capability: capabilityNote)
    }

    /// The keystone, issued wherever the pass could not see. It needs no data — which is
    /// why every branch that has none reaches for it.
    private func restoreEveryFan(because reason: SafetyLog.KeystoneReason) async {
        do {
            try await panic.restoreToAutomatic(.everyFan)
            // The write landed, so no fan is off automatic control and nothing is left to
            // refuse. Cleared *after* the write rather than before, so a throw leaves the
            // durable refusal standing.
            unreconciled = []
            nothingEstablished = false
            log.reconciliationRestoredEveryFan(because: reason)
        } catch {
            log.reconciliationEveryFanRestoreFailed(
                because: reason, detail: String(describing: error),
                capability: capabilityNote)
        }
    }

    /// Whether a refused write is this build's expected state or a real firmware refusal.
    ///
    /// `SMCFanControlPlane` answers `.notBuilt` and every write verb on it throws
    /// `.controlPathNotBuilt`, so on today's helper *every* restore below is refused. That
    /// is not news and must not be logged as though it were.
    private var capabilityNote: FanWriteCapability { plane.writeCapability }

    // MARK: - The post-reconciliation baseline

    /// Why a lease over `fans` cannot be granted, or `nil` when nothing here objects.
    ///
    /// Four questions, in this order, and the order is the honesty — most durable and most
    /// specific first, so a client is never told the vaguer of two true things:
    ///
    /// 1. **Did the pass establish anything at all?** A machine whose fans would not
    ///    enumerate has been looked at in no respect — `.supervisorBlind` for every fan
    ///    asked for, until a keystone write lands.
    /// 2. **Did Aeolus already fail to hand this fan back?** `.restoreToAutomaticFailed`:
    ///    the pass found it in manual, spent its attempts, and the firmware never took the
    ///    write. Answered from `handbackRefused` rather than from the read below, because
    ///    the read would eventually answer "granted" for a fan this process has proved it
    ///    cannot release.
    /// 3. **Did reconciliation reach this fan?** If not, nobody has looked at it and nobody
    ///    will — `.supervisorBlind`, whose own documentation is exactly this sentence
    ///    ("nobody has been able to look") reached from the other direction.
    /// 4. **Is it in manual right now?** A **fresh** `readControlState`, not the mode this
    ///    pass observed at startup. The startup read is minutes or days old by the time a
    ///    client asks, and a fan a foreign tool took in the meantime would otherwise be
    ///    granted. A read that throws is `.supervisorBlind` for the same reason as (3):
    ///    the helper cannot say what it is granting.
    ///
    /// `heldByAeolus` is the fans a live lease already covers, and they are skipped rather
    /// than answered. A fan Aeolus itself put into manual reads exactly like a foreign one
    /// — `F<n>Md` names no owner — so without this the lease core would tell a second client
    /// "another program has it" about its own work, instead of the `.leaseHeldByAnotherClient`
    /// the caller goes on to produce.
    func refusalForGrant(
        overFans fans: Set<Int>, heldByAeolus held: Set<Int>
    ) async -> ManualControlAvailability.Reason? {
        let candidates = fans.subtracting(held)
        guard !candidates.isEmpty else { return nil }
        guard !nothingEstablished else { return .supervisorBlind }
        guard candidates.isDisjoint(with: handbackRefused) else {
            return .restoreToAutomaticFailed
        }
        guard candidates.isDisjoint(with: unreconciled) else { return .supervisorBlind }

        for fan in candidates.sorted() {
            do {
                let state = try await plane.readControlState(ofFan: fan)
                guard state.mode == .manual else { continue }
                log.foreignManualControlObserved(fanAt: fan)
                return .foreignManualControl
            } catch {
                log.grantTimeStateUnreadable(fanAt: fan, detail: String(describing: error))
                return .supervisorBlind
            }
        }
        return nil
    }

    /// The fans this pass never established the mode of, for tests and diagnostics.
    var unreconciledFans: Set<Int> { unreconciled }

    /// The fans this pass found in manual and could not hand back, for tests and
    /// diagnostics. See `handbackRefused` and #201.
    var fansWithRefusedHandback: Set<Int> { handbackRefused }

    /// Whether the pass established nothing at all, for tests and diagnostics.
    var establishedNothing: Bool { nothingEstablished }
}

// MARK: - The seam the lease core sees

/// What `LeaseAuthority` asks before it grants, and the whole of what it may ask.
///
/// Narrow on purpose. The lease core has no business driving reconciliation, and giving it
/// the whole of `StartupReconciliation` would put `reconcile(fans:)` one `await` from a
/// decoded client message — the same argument `FanAuthority` makes about not holding a
/// `FanControlPlane`. It asks a question and is told a reason.
protocol ForeignManualControlSensing: Sendable {

    /// Why manual control of `fans` cannot be granted, or `nil` when this mechanism has no
    /// objection. `heldByAeolus` is excluded from the judgement, never judged.
    func refusalForGrant(
        overFans fans: Set<Int>, heldByAeolus held: Set<Int>
    ) async -> ManualControlAvailability.Reason?
}

// MARK: - The bound

enum ReconciliationLimits {

    /// How long the whole pass may take before the helper serves clients anyway.
    ///
    /// **A budget, not a timeout.** It is checked between fans, so it bounds the number of
    /// reads the pass will start — not the duration of any one of them. A single read that
    /// never returns still hangs the bring-up, and that is deliberate rather than an
    /// oversight: `HelperComposition.bringUp()` records the same choice for itself, because
    /// a daemon that answers no connections is the fail-safe direction and a daemon serving
    /// over unreconciled fans is not. Making one read cancellable would mean abandoning a
    /// `.supervisor` turn mid-flight, which is the scheduler's invariant to keep, not this
    /// mechanism's to break.
    ///
    /// Five seconds against a machine whose 34-key curated supervisor read costs 5.6 ms and
    /// whose whole 2930-key snapshot costs 2.3 s (measured, `Mac16,5`): a two-fan
    /// reconciliation is three orders of magnitude inside it, and a machine that cannot do
    /// two mode reads in five seconds is one whose lease refusal is the correct outcome.
    static let budget: Duration = .seconds(5)
}
