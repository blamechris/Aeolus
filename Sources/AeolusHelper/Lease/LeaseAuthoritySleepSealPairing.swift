// `docs/SAFETY.md` § 4's seal over the lease table, and the two generations that pair a sleep
// with its own wake — with the two decisions made over them. Split from `LeaseAuthority.swift` by
// [#128](https://github.com/blamechris/Aeolus/issues/128)'s lease-core pass, beside
// `LeaseAuthority.HandbackRegisters` and under the same three rules: no `async` member, no
// function-typed parameter, and no whole-value use on the actor's side, which holds its one
// instance as `private var sleep`. `LeaseAuthorityRegistersAccessTests` holds all three; the
// file header of `LeaseAuthorityHandbackRegisters.swift` says why each exists.
//
// The actor keeps the acts: it logs what each decision answered, and it asks `isSealed` in
// `acquireLease`'s straight-line region. Why the generations are compared rather than counted,
// and what the first, counting version did: handback-ledger.md § *"Pairing a sleep with its own
// wake"*.

extension LeaseAuthority {

    /// Whether the table is closed for a sleep, and the generations that decide whether a
    /// `.willSleep` or a `.didWake` may change that.
    struct SleepSealPairing: Sendable {

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
        /// event, so IOKit's serial queue orders the **spawns** and nothing orders the bodies.
        /// If the `.willSleep` body is starved past the kernel's ~30 s acknowledgement window
        /// the machine sleeps regardless, and on wake the `.didWake` body can reach
        /// `unsealAfterWake(generation:)` first. The seal for that episode then arrives *after*
        /// its own wake, and setting it would refuse every lease on a machine that is awake in
        /// front of its user until the next sleep and wake.
        ///
        /// Comparing generations answers that exactly: a seal is declined when a **strictly
        /// later** wake has already been seen, because that wake proves the episode is over. No
        /// state accumulates and nothing is spent, so there is no reachable state in which the
        /// seal stops being set and stays that way.
        ///
        /// **The first attempt counted instead, and it latched** — one unpaired wake disabled
        /// the seal for the life of the process, turning a fail-safe defect into a
        /// fail-dangerous one. Why counting cannot work here, and what a declined seal did to
        /// the count: handback-ledger.md § *"Pairing a sleep with its own wake"*.
        ///
        /// **What this does not claim**: the starved body still drops every lease and restores
        /// after the wake, and the client is never told it lost the lease. Bounded and honest
        /// rather than thermal — handback-ledger.md § *"Pairing a sleep with its own wake"*.
        private var latestWakeGeneration: UInt64 = 0

        /// The generation of the newest non-declined `.willSleep` that set or met the seal
        /// standing.
        ///
        /// Without it a *stale* wake would clear a live seal: if episode 2's `.willSleep` body
        /// runs before episode 1's starved `.didWake` body, that late wake is older than the
        /// seal it would otherwise open, and the machine is at that moment going to sleep. A
        /// wake clears the seal only when it is newer than every sleep that met it — so a sleep
        /// that finds the seal already standing still records its generation, the larger of
        /// the two (#347). handback-ledger.md § *"Pairing a sleep with its own wake"*.
        private var sealGeneration: UInt64 = 0

        /// Whether the table is closed for a sleep: `acquireLease`'s third refusal below its
        /// marker.
        var isSealed: Bool { sleepSeal }

        /// `sealForSleep(generation:)`'s decision.
        ///
        /// A seal whose own wake has already been answered is **not** set, and declining leaves
        /// any newer seal standing. One that is not declined records its generation even when it
        /// finds the seal standing, and records the larger of the two (#347) — above the
        /// standing check, which is the whole of that fix.
        mutating func seal(generation: UInt64) -> SealOutcome {
            guard generation > latestWakeGeneration else { return .declined }
            sealGeneration = max(sealGeneration, generation)
            guard !sleepSeal else { return .metStanding }
            sleepSeal = true
            return .sealed
        }

        /// `unsealAfterWake(generation:)`'s decision.
        ///
        /// The generation is recorded **whether or not there was a seal to clear**, because that
        /// is the record a later-arriving seal is compared against. A wake that is older than the
        /// seal standing is ignored for the clearing, and still counted for the ordering.
        ///
        /// - Returns: whether this wake cleared the seal.
        mutating func wake(generation: UInt64) -> Bool {
            latestWakeGeneration = max(latestWakeGeneration, generation)
            guard sleepSeal, generation > sealGeneration else { return false }
            sleepSeal = false
            return true
        }
    }

    /// What `SleepSealPairing.seal(generation:)` did, which the actor logs.
    ///
    /// A sibling of `SleepSealPairing` rather than nested in it: SwiftLint's `nesting` rule allows
    /// one level, as `ReclamationWatchdog.Registration` records.
    enum SealOutcome: Sendable, Equatable {
        /// A strictly later wake was already seen, so the episode is over: nothing changed.
        case declined
        /// The seal was standing already; its generation is now the larger of the two.
        case metStanding
        /// The seal was set.
        case sealed
    }
}
