// The handback ledger's three registers, and the set of fans owed a read-back before a refusal
// lifts — with every synchronous decision made over them. Split from `LeaseAuthority.swift` by
// [#128](https://github.com/blamechris/Aeolus/issues/128)'s lease-core pass, before #269 would
// have taken that actor's body past the 320 code lines its trigger was set at.
//
// It moves state rather than a function, as § 5's `ReclamationWatchdog.Registry` did, and it
// widens none. The actor holds its one instance as `private var registers`, so another file can
// construct a `HandbackRegisters` and reach nothing the actor owns: an instance outside the actor
// governs nothing. What moved is the bookkeeping. Every `await`, every re-read after one and every
// act — each log line, each restore, and resuming the revocations outwaiting a fan — stays on the
// actor's side, in the order it had. The actor's reentrancy rule is stated once, on
// `LeaseAuthority` itself, and binds the calls into this type exactly as it bound the statements
// they replace.
//
// A value type, so nothing here can suspend, and three rules keep it that way.
// `LeaseAuthorityRegistersAccessTests` holds each, because the compiler holds only the first half
// of the first:
//
// - **No `async` member.** The compiler refuses a *mutating* `async` call on an actor's stored
//   struct, but a non-mutating one compiles, and would answer from a copy taken before its own
//   suspension.
// - **No function-typed parameter.** A closure handed in here that reaches the actor's
//   `registers` while it is being mutated compiles, and traps at run time with "Simultaneous
//   accesses": in a root daemon, a trap is the helper dying. So every transition is named.
// - **No whole-value use on the actor's side.** `let before = registers`, an `await`, and a write
//   back loses every transition that ran during the suspension. The actor reaches the registers
//   only through their members.
//
// Why each register exists, what enters and what clears it, is
// [docs/records/handback-ledger.md](../../../docs/records/handback-ledger.md), as it was before
// the move; each declaration below keeps the fact it states and the section that argues it.

extension LeaseAuthority {

    /// `releasing`, `restoreAbandoned`, `handbackAcceptedUnconfirmed` and `handbackUnconfirmed`:
    /// what the lease core knows about every handback it has issued.
    ///
    /// Every transition is synchronous, closure-free, and named for the step of
    /// `restore(_:because:)`, `recordUnconfirmedHandbacks()` or `confirmAcceptedHandbacks()` it
    /// is. The queries are what the grant gate, the snapshot and the outwait read.
    struct HandbackRegisters: Sendable {

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
        /// **One producer, and it is a firmware refusal**: the union in
        /// `recordRestore(of:abandoned:)`, which `restore(_:because:)` calls with what the
        /// restorer gave back. `docs/SAFETY.md` § 4's acknowledgement budget expiring is **not**
        /// a second one and was one until ADR 0007, amendment 2026-09-06 (#209) — a budget is
        /// evidence about time rather than about the firmware, so it records
        /// `handbackUnconfirmed` below instead, and a fan reaches this set from there only when
        /// the outstanding restore comes back refused.
        ///
        /// **Not append-only since [#189](https://github.com/blamechris/Aeolus/issues/189)**,
        /// and the one thing that clears it is a restore the restorer did *not* give up on
        /// **and** a later read reporting automatic (#291, `liftRefusals(readingAutomatic:)`
        /// from `confirmAcceptedHandbacks()`). **A restore that never returns leaves it
        /// standing**, as does one refused again, and both are the fail-safe direction.
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

        /// Fans whose restore-to-automatic was issued, stopped being waited for, and has not
        /// come back: `docs/SAFETY.md` § 4's acknowledgement budget expired with it still
        /// outstanding.
        ///
        /// The third register in this ledger, between the transient `releasing` and the durable
        /// `restoreAbandoned`, and it is a distinct fact from either: the write is still in
        /// flight, nothing cancelled it, and this process has no answer about the fan's mode.
        /// Decision D33 on [#209](https://github.com/blamechris/Aeolus/issues/209) — ADR 0007,
        /// amendment 2026-09-06.
        ///
        /// **Invariant: it is always a subset of `releasing.keys`.** A fan enters only from
        /// `releasing.keys`, in `recordUnconfirmedHandbacks()`, and leaves only when its
        /// `releasing` count drops to `nil` in `endHandback(ofFan:)`, from
        /// `restore(_:because:)`'s `defer` — the instant the restore that put it there returns.
        /// Nothing else writes it, which is why `fansAeolusIsAccountableFor` needs no third
        /// union, and why `UnconfirmedHandbackTests` asserts the subset rather than leaving it
        /// a sentence.
        ///
        /// **Not append-only, and that is the whole of D33**: the three outcomes a handback can
        /// reach, and which register each ends in, are handback-ledger.md § *"The three
        /// registers"*.
        private var handbackUnconfirmed: Set<Int> = []

        // MARK: - Queries

        /// `restoreAbandoned`: what the snapshot is told, and what the panic sweep adds to the
        /// table's fans.
        var abandonedHandbacks: Set<Int> { restoreAbandoned }

        /// `handbackUnconfirmed`: what the snapshot is told.
        var unconfirmedHandbacks: Set<Int> { handbackUnconfirmed }

        /// `releasing`'s keys, and nothing about its counts.
        var fansMidHandback: Set<Int> { Set(releasing.keys) }

        /// `handbackAcceptedUnconfirmed`: the fans `confirmAcceptedHandbacks()` reads back.
        var handbacksOwedAReadBack: Set<Int> { handbackAcceptedUnconfirmed }

        /// Whether a restore of `fan` is on the wire: what a `.gone` revocation outwaits.
        func isMidHandback(_ fan: Int) -> Bool { releasing[fan] != nil }

        /// The requested fans a restorer gave up on, in request order: the grant gate's first
        /// refusal below its marker.
        func abandoned(among fans: [Int]) -> [Int] {
            fans.filter { restoreAbandoned.contains($0) }
        }

        /// The requested fans whose handback nothing has answered for, in request order: the
        /// grant gate's second.
        func unconfirmed(among fans: [Int]) -> [Int] {
            fans.filter { handbackUnconfirmed.contains($0) }
        }

        /// The requested fans with a restore on the wire, in request order: the grant gate's
        /// mid-handback refusal.
        func midHandback(among fans: [Int]) -> [Int] {
            fans.filter { releasing[$0] != nil }
        }

        // MARK: - Transitions

        /// Counts one more restore of `fan` on the wire: `restore(_:because:)`'s prologue, before
        /// its first suspension.
        mutating func beginHandback(ofFan fan: Int) {
            releasing[fan, default: 0] += 1
        }

        /// Counts one restore of `fan` back: `restore(_:because:)`'s `defer`.
        ///
        /// The last one out clears `handbackUnconfirmed` in the same transition as `releasing`,
        /// so a fan leaves exactly when its last outstanding restore returns.
        ///
        /// - Returns: whether that was its last outstanding restore, so the actor resumes the
        ///   revocations outwaiting it; `false`, having touched nothing, when none was.
        mutating func endHandback(ofFan fan: Int) -> Bool {
            guard let outstanding = releasing[fan] else { return false }
            guard outstanding > 1 else {
                releasing[fan] = nil
                handbackUnconfirmed.remove(fan)
                return true
            }
            releasing[fan] = outstanding - 1
            return false
        }

        /// Records what a restore of `fans` came back with: `abandoned` is what the restorer
        /// gave up on, recorded rather than dropped, so the next `acquireLease` over one is
        /// refused durably instead of being told to retry a window that has closed.
        ///
        /// The `guard` is the one `restore(_:because:)` had before its log line, kept here so
        /// every statement runs under exactly the condition it ran under in the actor; the
        /// actor repeats it for its own log line.
        ///
        /// - Returns: the fans the register held whose write was accepted this time, now owed a
        ///   read-back (#291), which the actor logs.
        mutating func recordRestore(of fans: Set<Int>, abandoned: Set<Int>) -> Set<Int> {
            restoreAbandoned.formUnion(abandoned)

            // Refused again: no longer owed a read-back, and a `confirmAcceptedHandbacks()`
            // mid-read for it will not lift the refusal just renewed.
            handbackAcceptedUnconfirmed.subtract(abandoned)

            // A fan the register held whose write was accepted is only marked owed a read-back:
            // accepted is not automatic (#291), and the read is **not** taken here, because sleep
            // and SIGTERM issue the keystone only after the restore returns — handback-ledger.md
            // § *"Accepted is not automatic"*.
            let accepted = restoreAbandoned.intersection(fans.subtracting(abandoned))
            guard !accepted.isEmpty else { return accepted }
            handbackAcceptedUnconfirmed.formUnion(accepted)
            return accepted
        }

        /// § 4's budget path: every fan with a restore issued and not yet returned is recorded
        /// as one nothing has confirmed. Additive and idempotent.
        ///
        /// - Returns: the fans newly or already recorded.
        mutating func recordUnconfirmedHandbacks() -> Set<Int> {
            let outstanding = Set(releasing.keys)
            handbackUnconfirmed.formUnion(outstanding)
            return outstanding
        }

        /// Lifts the refusal over every fan owed a read-back that `automatic` — a read taken
        /// across the actor's `await` — reports automatic. Judged against the owed set as it
        /// stands now, so a refusal `recordRestore(of:abandoned:)` renewed during the read is
        /// not lifted. The `guard` is `confirmAcceptedHandbacks()`'s, kept for
        /// `recordRestore(of:abandoned:)`'s reason.
        ///
        /// - Returns: the fans whose refusal lifted.
        mutating func liftRefusals(readingAutomatic automatic: Set<Int>) -> Set<Int> {
            let recovered = automatic.intersection(handbackAcceptedUnconfirmed)
            guard !recovered.isEmpty else { return recovered }
            handbackAcceptedUnconfirmed.subtract(recovered)
            restoreAbandoned.subtract(recovered)
            return recovered
        }
    }
}
