// What § 5 keeps per fan. Split from `ReclamationWatchdog.swift` when ADR 0009 D2
// ([#180](https://github.com/blamechris/Aeolus/issues/180)) pushed that file past SwiftLint's
// 1000-line error, and it is the third split of the kind that file's `- Note:` allows: one that
// widens no state. This is a type, not state. `held` — the only place a `HeldFan` means
// anything — stays `private` to the actor, so moving the declaration from `private` to
// module-internal lets another file construct a value that nothing will accept, and reaches
// nothing the actor owns. [#128](https://github.com/blamechris/Aeolus/issues/128) owns the rest.

import Foundation

extension ReclamationWatchdog {

    /// What this mechanism knows about one fan it is watching.
    ///
    /// **No write permit is kept here, deliberately.** One was, and it was read nowhere: a
    /// `CommandableFan` stored at registration and overwritten by every envelope read. The hazard
    /// was not the dead field, it was the sentence attached to it — *"replaced by every successful
    /// re-assert, so it is never older than the last envelope actually read"* — which is both
    /// inaccurate on its own terms and an argument, handed to the next editor, for deleting
    /// `reassert(_:fanAt:heldUnder:attempt:reengaging:)`'s fresh `readEnvelope(ofFan:)` and passing
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
        /// The step last put on the wire, or `nil` when nothing has been commanded yet.
        var commanded: CommandedTarget?
        /// Cycles in a row that could not read this fan. Reset by any successful read.
        var consecutiveReadFailures = 0
        /// Cycles in a row the actual speed has been short of the commanded target. Reset
        /// by convergence and by a fresh command.
        var actualDwellCycles = 0
        /// Re-asserts issued for the current episode. Reset by convergence.
        var reassertAttempts = 0

        /// Gives back an attempt booked for a write that never reached the firmware —
        /// `reassert`'s cancellation exit. Decremented rather than assigned, and floored at
        /// zero, so a concurrent reset cannot leave it negative and hand the fan an extra try.
        mutating func refundReassertAttempt() {
            reassertAttempts = max(0, reassertAttempts - 1)
        }
        /// Divergent cycles spent on this fan before anything was ever commanded on it —
        /// the registration grace, see `gracedBeforeItsFirstCommand(_:of:fanAt:)`.
        ///
        /// **Spent, never reset.** A fan cannot be graced indefinitely by alternating
        /// between divergence and convergence — `examine(fanAt:)`'s converged branch resets
        /// the two counters below it and deliberately not this one — and it cannot be graced
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
    }
}
