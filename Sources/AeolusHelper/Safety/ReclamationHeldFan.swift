// What § 5 keeps per fan. Split from `ReclamationWatchdog.swift` when ADR 0009 D2
// ([#180](https://github.com/blamechris/Aeolus/issues/180)) pushed that file past SwiftLint's
// 1000-line error, and it is the third split of the kind that file's `- Note:` allows: one that
// widens no state. This is a type, not state. `held` — the only place a `HeldFan` means
// anything — is `private` to `ReclamationWatchdog.Registry`, whose one instance is `private` to
// the actor, so moving the declaration from `private` to module-internal lets another file
// construct a value that nothing will accept, and reaches nothing the actor owns.
//
// Since [#128](https://github.com/blamechris/Aeolus/issues/128)'s third pass the per-reading
// judgement is here too: `judge(_:)` moves this record's counters as one readable cycle moves
// them and says which branch the cycle took, and the actor acts on the answer. A value's
// mutating method, so the counters are read and written with no suspension point between.

import FanKit
import Foundation

extension ReclamationWatchdog {

    /// What this mechanism knows about one fan it is watching.
    ///
    /// **No write permit is kept here, deliberately.** One was, and it was read nowhere: a
    /// `CommandableFan` stored at registration and overwritten by every envelope read. The hazard
    /// was not the dead field, it was the sentence attached to it — *"replaced by every successful
    /// re-assert, so it is never older than the last envelope actually read"* — which is both
    /// inaccurate on its own terms and an argument, handed to the next editor, for deleting
    /// `reassert(fanAt:heldUnder:attempt:reengaging:)`'s fresh `readEnvelope(ofFan:)` and passing
    /// the stored permit instead. That would remove the bounds check the branch exists to perform
    /// and the "no envelope → restore, not command" failure path with it. ADR 0008's context is the
    /// same defect: a comment telling an editor that load-bearing code was redundant. The field is
    /// gone rather than re-documented, because there is nothing to reuse if nothing is kept.
    ///
    /// ## Built once per registration, per lease
    ///
    /// `registering(_:over:)` keeps an existing entry only when it was registered under the
    /// same lease, so registering a fan twice without an intervening release keeps its
    /// `commanded` target, its grace counter, its re-assert attempts and its blind-cycle count —
    /// #180's rule against rearming them. A registration under a different lease starts fresh:
    /// that lease's end restored the fan, so its record is stale, and keeping it would hand the
    /// new lease the old target and the spent budget (#357). Why each half matters, and why the
    /// fresh start under a new lease is not a rearm: reclamation-watchdog.md § *"Built once per
    /// registration, per lease"*.
    ///
    /// `ReclamationRegistrationWindowTests.reRegisteringMidGraceDoesNotRefillIt` and
    /// `.reRegisteringKeepsWhatWasCommanded` are the same-lease half;
    /// `ReclamationLeaseIdentityTests.aRegistrationUnderANewLeaseStartsAFreshRecord` the other.
    struct HeldFan: Sendable {
        /// The lease this fan was registered under — the one `apply` authorised. Every
        /// judgement § 5 makes about the fan asks about this lease, and no other (#357).
        let lease: UUID
        /// The step last put on the wire, or `nil` when nothing has been commanded yet. Written
        /// only by `record(_:)`, so both of its writers pass the one check of what it may hold.
        private(set) var commanded: CommandedTarget?
        /// Cycles in a row that could not read this fan. Reset by any successful read.
        var consecutiveReadFailures = 0
        /// Cycles in a row the actual speed has been short of the commanded target. Reset
        /// by convergence and by a fresh command.
        var actualDwellCycles = 0
        /// Re-asserts issued for the current episode. Reset by convergence.
        var reassertAttempts = 0
        /// Whether a reclamation episode is in flight for this record: from a readable cycle whose
        /// primary signal diverged outside the registration grace to the next readable cycle whose
        /// primary converges, or until the record is dropped or replaced (#366). The terminal
        /// action drops it, and so do `restoreAndForget` (§ 3's yield, `.leaseLapsed`, a re-assert
        /// that yields) and `release`; a newer lease's registration replaces it. A cycle that
        /// cannot read ends nothing. While it is set, a registration under this record's lease
        /// leaves the ledger's mark to the episode. Kept by `registering(_:over:)` with the rest of
        /// a same-lease record.
        var episodeInFlight = false
        /// The fan's registration generation when the examination now in flight began, stamped
        /// by `beginExamination(atGeneration:inBound:)` before the control-state read (#381).
        /// Kept by `registering(_:over:)` with the rest of a same-lease record, so a registration
        /// under this lease since then shows as a generation past it. `nil` until the first
        /// examination.
        var examinedAtGeneration: UInt64?
        /// Whether the examination now in flight began inside the gate's bound, stamped beside
        /// `examinedAtGeneration`: `false` only past it, when the re-assert stands down and
        /// writes nothing away from automatic control (ADR 0014's A6 amendment). It says nothing
        /// about holding the gate: a wait cancelled inside the bound holds nothing and is stamped
        /// `true`, because its re-assert stops at the cancellation guard before any write (#144).
        var examinedInBound = false

        /// Gives back an attempt booked for a write that never reached the firmware —
        /// `reassert`'s cancellation exit. Decremented rather than assigned, and floored at
        /// zero, so a concurrent reset cannot leave it negative and hand the fan an extra try.
        mutating func refundReassertAttempt() {
            reassertAttempts = max(0, reassertAttempts - 1)
        }
        /// Divergent cycles spent on this fan before anything was ever commanded on it —
        /// the registration grace, see `judge(_:)`.
        ///
        /// **Spent, never reset.** A fan cannot be graced indefinitely by alternating
        /// between divergence and convergence — `judge(_:)`'s converged branch resets
        /// `actualDwellCycles` and `reassertAttempts`, declared above, and deliberately not this
        /// one — and it cannot be graced
        /// indefinitely by being registered again either: the budget belongs to one
        /// registration, and the only thing that refills it is a fresh `HeldFan`, which
        /// `registering(_:over:)` builds only for a fan not already held under that lease.
        var uncommandedDivergentCycles = 0

        init(lease: UUID) {
            self.lease = lease
        }

        /// The record a registration under `lease` leaves: `existing` when it was registered
        /// under the same lease, otherwise a fresh one.
        static func registering(_ lease: UUID, over existing: HeldFan?) -> HeldFan {
            if let existing, existing.lease == lease { return existing }
            return HeldFan(lease: lease)
        }

        /// Stamps this record as the examination of it begins, with the fan's registration
        /// `generation` (#381) and whether its wait for the gate stayed inside the bound (A6):
        /// `Registry.beginExamination(ofFan:inBound:)`. A method on the record rather than an
        /// assignment through `Registry.held`, so a stamp that reads the record's own fields as
        /// well is one exclusive access to it.
        mutating func beginExamination(atGeneration generation: UInt64, inBound: Bool) {
            examinedAtGeneration = generation
            examinedInBound = inBound
        }

        /// Records `target` as the step last put on the wire: the one write of `commanded`, which
        /// a report (`command(_:)`) and a re-assert (`Registry.recordReassertedTarget`) both pass
        /// through (#395).
        ///
        /// A target that is not finite, or is below `FanSafetyLimits.minimumManualRPM`, is one no
        /// permit can produce, because every permit clamps to a floor at least that high. It is
        /// no report, so the record keeps the last one, and the next cycle judges the fan against
        /// that. The check is a floor and no ceiling: a fan's maximum is its envelope's, which
        /// the record does not hold, so a target above it is not caught here.
        ///
        /// - Returns: `false`, having recorded nothing, when `target` fails that check.
        mutating func record(_ target: CommandedTarget) -> Bool {
            let writable = target.rpm.isFinite && target.rpm >= FanSafetyLimits.minimumManualRPM
            guard writable else { return false }
            commanded = target
            return true
        }

        /// Records the step just put on the wire for this fan, through `record(_:)`.
        ///
        /// A fresh command resets the secondary dwell: the fan is being asked for something
        /// new, and cycles spent short of the *previous* target say nothing about this one. A
        /// target the record refused is no command, so it resets nothing.
        ///
        /// - Returns: `false`, having changed nothing, when `record(_:)` refused `target`.
        mutating func command(_ target: CommandedTarget) -> Bool {
            guard record(target) else { return false }
            actualDwellCycles = 0
            return true
        }

        /// Counts one more cycle that could not read this fan.
        ///
        /// - Returns: the cycles in a row that could not read it, this one included.
        mutating func recordReadFailure() -> Int {
            consecutiveReadFailures += 1
            return consecutiveReadFailures
        }

        // MARK: - One readable cycle

        /// Judges one readable cycle: the primary signal first, and it is the only one that can
        /// reach the terminal action; then the secondary, which reports and stops; then
        /// convergence.
        ///
        /// ## The episode: `episodeInFlight`
        ///
        /// Opened by every `.diverged`, the grace's included once it runs out, and never by
        /// `.graced`; closed by the next cycle whose primary converges, `.short` as well as
        /// `.converged`, because that cycle is the one the actor clears the ledger's mark on
        /// (#366). The terminal action ends the episode by dropping the record, as does anything
        /// else that drops or replaces it (`episodeInFlight`); a cycle that cannot read ends
        /// nothing.
        ///
        /// It absorbs what were `ReclamationWatchdog`'s `gracedBeforeItsFirstCommand(_:of:fanAt:)`
        /// and `reportShortfall(_:fanAt:)`, with their reasons, below. Both were synchronous so
        /// that no suspension point fell between reading a counter and writing it back, and a
        /// value's mutating method is that by construction.
        ///
        /// ## The registration grace: `.graced`
        ///
        /// Whether this divergence is still inside the window that follows registration, and so
        /// must not reach the terminal action yet.
        ///
        /// ## The window this closes
        ///
        /// On a fan with nothing commanded, `.modeReclaimed` (the write-to-read-back lag) and
        /// `.targetUnreadable` are decided before `commanded` is consulted, and either would take
        /// the terminal action: restore, revoke **the client's lease**, blame the OS (#147).
        /// reclamation-watchdog.md § *"The window this closes"*.
        ///
        /// ## Why the failure asymmetry inverts here, and only here
        ///
        /// With no commanded target there is no pinned-fan hazard, so over-firing costs the client
        /// a lease it still held. The tolerance is granted only while `commanded` is `nil`; the
        /// first `commandedTarget(_:under:)` ends it.
        /// reclamation-watchdog.md § *"Why the failure asymmetry inverts here, and only here"*.
        ///
        /// ## Bounded by `blindCyclesBeforeDivergence`, and not by a fourth constant
        ///
        /// The same constant as `cycleCouldNotSee(fanAt:heldUnder:detail:)`, because it is the
        /// same question. reclamation-watchdog.md § *"Bounded by `blindCyclesBeforeDivergence`,
        /// and not by a fourth constant"*.
        ///
        /// ## The secondary signal reports, and does nothing else: `.short`
        ///
        /// The fan has been short of its commanded speed for `dwell` cycles. The caller says so
        /// when the dwell is reached, and stops. The cycle's primary converged, so the caller also
        /// clears any mark the ledger holds for the fan, as on `.converged` (#366): the mark
        /// follows the primary signal, and the shortfall itself changes nothing.
        ///
        /// ## Why this no longer reaches the terminal action
        ///
        /// The secondary signal is only evaluated once the primary has converged, so the firmware
        /// is holding Aeolus's target and nothing was reclaimed: a fan that cannot reach it is
        /// reported, and neither re-asserted, restored nor marked `isReclaimedBySystem`.
        /// reclamation-watchdog.md § *"Why this no longer reaches the terminal action"*.
        ///
        /// ## `==` and not `>=`
        ///
        /// One line per episode, which is why `.short` carries the dwell and the caller reports
        /// only when it *equals* `ReclamationLimits.actualDwellCycles`. `>=` would emit at the
        /// supervisor's 1 Hz for as long as the shortfall lasted, which is #124's forward
        /// constraint exactly: *an unchanged degraded set logged every tick at 1 Hz is not a log,
        /// it is a denial of service against the reader.* The dwell counter goes on rising and the
        /// next transition through convergence, or a fresh `commandedTarget(_:under:)`, resets it
        /// — so a fan that recovers and falls short again produces a second line rather than
        /// silence.
        ///
        /// ## Convergence does not refill the grace: `.converged`
        ///
        /// `uncommandedDivergentCycles` is deliberately **not** reset alongside the dwell and the
        /// attempts — see `uncommandedDivergentCycles`. A fan whose `F<n>Tg` is merely flaky
        /// rather than gone would otherwise refill the registration grace on every readable cycle
        /// and stay off automatic control for as long as the flapping lasted, which is
        /// `ReclamationRegistrationWindowTests.aConvergedCycleDoesNotRefillTheGrace`.
        mutating func judge(_ state: FanControlState) -> Judgement {
            if let primary = ReclamationWatchdog.primaryDivergence(of: state, against: commanded) {
                actualDwellCycles = 0
                if commanded == nil {
                    uncommandedDivergentCycles += 1
                    // Log the transition, not the state — #124's forward constraint, and
                    // `cycleCouldNotSee(fanAt:heldUnder:detail:)`'s rule for the same reason.
                    if uncommandedDivergentCycles < ReclamationLimits.blindCyclesBeforeDivergence {
                        return .graced(primary, firstCycle: uncommandedDivergentCycles == 1)
                    }
                }
                // Before the actor's `diverged` reaches the ledger, so a registration landing in
                // any of its hops finds the episode open (#366). Only the re-assert's envelope read
                // is exercised by a test; the latch and ledger hops have no seam to land one in.
                episodeInFlight = true
                return .diverged(primary)
            }

            // The primary converged: the firmware holds Aeolus's target, so whatever the secondary
            // says, nothing is reclaimed and no episode is in flight (#366).
            episodeInFlight = false

            if let shortfall = ReclamationWatchdog.actualShortfall(of: state, against: commanded) {
                actualDwellCycles += 1
                return .short(
                    actual: shortfall.actual, commanded: shortfall.commanded,
                    dwell: actualDwellCycles)
            }

            actualDwellCycles = 0
            reassertAttempts = 0
            return .converged
        }
    }

    /// What one readable cycle said about a held fan, with its counters already moved as that
    /// cycle moves them: `HeldFan.judge(_:)`'s answer, which `examine(fanAt:inBound:)` acts on.
    ///
    /// A sibling of `HeldFan` rather than nested in it, because SwiftLint's `nesting` rule
    /// allows one level and `HeldFan` is already that level.
    enum Judgement: Sendable, Equatable {
        /// The primary signal fired, outside the registration grace: re-assert or fall back.
        case diverged(ReclamationDivergence)
        /// The primary signal fired inside the registration grace, which this cycle spent part
        /// of. `firstCycle` is whether it was the grace's first: the transition, and the only
        /// cycle that says so.
        case graced(ReclamationDivergence, firstCycle: Bool)
        /// The primary signal converged and the fan is short of its commanded speed, for
        /// `dwell` cycles in a row counting this one.
        case short(actual: Double, commanded: Double, dwell: Int)
        /// Converged on both signals.
        case converged
    }
}
