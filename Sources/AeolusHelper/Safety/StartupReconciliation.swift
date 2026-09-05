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
    /// record as unreconciled. The machine-wide verb is deliberately **not** reached for —
    /// the fallback below is for a *mode* read failing on a fan that did enumerate, which is
    /// a different fact — and nothing is lost by declining, because `acquireLease` enumerates
    /// through this same seam and throws before it can grant anything.
    private let enumeration: any FanEnumerating

    /// The keystone path for the per-fan restore — the same `HelperFanRestorer` the lease
    /// core's teardown uses, so a fan handed back here goes through
    /// [#110](https://github.com/blamechris/Aeolus/issues/110)'s bounded attempts and both
    /// safety registries are told, exactly as they would be for an expiring lease.
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
    /// ## The order of the three outcomes
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
    /// 3. **The budget runs out** → the remaining fans go into `unreconciled` and the pass
    ///    returns. The caller resumes the listener anyway; every unreconciled fan is refused
    ///    a lease durably. See `ReconciliationLimits.budget`.
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
        let fans: Set<Int>
        do {
            fans = try await enumeration.enumeratedFanIndices()
        } catch {
            log.reconciliationEnumerationFailed(detail: String(describing: error))
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
                await restoreEveryFan(after: error, fanAt: fan)
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
    }

    /// One fan, through the keystone path, with the refusal this build always produces kept
    /// off the fault channel.
    private func restore(fanAt fan: Int) async {
        log.reconcilingManualFan(fanAt: fan)
        let abandoned = await restorer.restoreToAutomatic(
            fans: [fan], because: .startupReconciliation)
        guard abandoned.contains(fan) else { return }
        // The fan is still in manual and nothing else will clear it. It is not added to
        // `unreconciled`: its mode *was* established — it reads manual — so the grant-time
        // read below refuses it as `.foreignManualControl`, which is the more precise of
        // the two answers and the one a user can act on.
        log.reconciliationRestoreRefused(fanAt: fan, capability: capabilityNote)
    }

    /// The whole-read failure path.
    private func restoreEveryFan(after failure: any Error, fanAt fan: Int) async {
        log.reconciliationReadFailed(
            fanAt: fan, detail: String(describing: failure), unreconciled: unreconciled)
        do {
            try await panic.restoreToAutomatic(.everyFan)
            // The write landed, so no fan is off automatic control and nothing is left to
            // refuse. Cleared *after* the write rather than before, so a throw leaves the
            // durable refusal standing.
            unreconciled = []
            log.reconciliationRestoredEveryFan()
        } catch {
            log.reconciliationEveryFanRestoreFailed(
                detail: String(describing: error), capability: capabilityNote)
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
    /// Two questions, in this order, and the order is the honesty:
    ///
    /// 1. **Did reconciliation reach this fan?** If not, nobody has looked at it and nobody
    ///    will — `.supervisorBlind`, whose own documentation is exactly this sentence
    ///    ("nobody has been able to look") reached from the other direction.
    /// 2. **Is it in manual right now?** A **fresh** `readControlState`, not the mode this
    ///    pass observed at startup. The startup read is minutes or days old by the time a
    ///    client asks, and a fan a foreign tool took in the meantime would otherwise be
    ///    granted. A read that throws is `.supervisorBlind` for the same reason as (1):
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
