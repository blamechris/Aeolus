/// Which of the helper's readers is asking, and therefore who waits for whom.
///
/// Three cases, and the third has one user. [ADR 0006](../../docs/ADR/0006-single-smc-reader.md)
/// puts **one** continuous reader on the machine, inside this process, and the things that share
/// it want different treatment: `docs/SAFETY.md` § 3's own cycle, whose lateness delays the
/// emergency itself; every other safety mechanism, whose lateness is a slower sweep; and a client
/// snapshot, whose lateness is a slightly older reading.
///
/// Deliberately not a number, and deliberately not `TaskPriority`. A numeric level invites
/// another to be slipped in between, and `SMCReadScheduler`'s bounds are written for exactly
/// these three, each admitted by its own rule rather than by rank.
///
/// ## Two levels, then three, each decided rather than inherited
///
/// [#134](https://github.com/blamechris/Aeolus/issues/134) asked whether § 3 needed a level of
/// its own, with a fact the first version of this enum did not have: within `.supervisor` this
/// scheduler is FIFO, so *N* outstanding supervisor reads admit the last of them
/// `N + (N - 1) / SMCReadScheduler.maxConsecutiveOvertakes` turns after it queues.
/// [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md) D2 answered no: a third level
/// would fix § 3's place in line while leaving the connection saturated by whatever queued ahead
/// of it, so it would make read amplification survivable rather than impossible, and the
/// amplification was the defect `CriticalTemperatureCache` removed.
///
/// [#332](https://github.com/blamechris/Aeolus/issues/332) reopened D2, on the trigger D2 itself
/// named, and for § 3's cycle alone. Since ADR 0014's B1 amendment every command and every
/// restore is its own turn, and a firing cycle on `Mac16,5` is up to eleven of § 3's turns. Each
/// waited behind every outstanding reader, so under client load the queue delayed § 3's own
/// bridge and restore by seconds per turn, and only a design point of *N* ≤ 2 — no load worth
/// serving — kept the firing cycle inside a D_cycle worth having (ADR 0012's alternatives). That
/// delay is not
/// amplification a cache can coalesce: it is § 3's own writes. ADR 0012's 2026-10-18 amendment
/// records the decision and the arithmetic.
///
/// D2's three objections, answered:
///
/// - *Survivable amplification.* What the lane reorders is § 3's own turns at the design point,
///   and actions cannot be coalesced. It adds no capacity and hides no reader: `.supervisor`
///   stays FIFO, and the readers that still slow under load are #332's, which stays open.
/// - *The quota is the cost.* The lane neither spends nor resets the snapshot's overtake quota,
///   so the starvation bound below `.supervisor` is the one it always was, and a supervisor turn
///   waits for at most one lane turn more per turn it waits behind (the lane never holds two
///   turns in a row while another waiter is parked; see `SMCReadScheduler`).
/// - *A level somebody will use.* Tripwires hold the case to the files that name it today
///   (`ThermalCycleLaneTripwireTests`): this enum, the scheduler, the plane view, the
///   composition's § 3 wiring and `HelperFanRestorer`'s routing by cause. And the value set is
///   pinned: `ThermalCycleLaneValueSetTests` switches over these three cases with no `default`, so
///   a fourth, which the scheduler could queue in the lane under another name, does not compile
///   until the pin decides where it goes.
///
/// **Revisit when** a second user of the lane is proposed, or anything in ADR 0012's 2026-10-18
/// amendment's revisit list happens. A supervisor-priority reader that can be neither coalesced
/// nor paced is still #332's, not the lane's: E3's per-command `readEnvelope(ofFan:)`, and since
/// [#270](https://github.com/blamechris/Aeolus/issues/270) the grant's bounds read, stay on
/// `.supervisor`.
enum SMCReadPriority: Sendable, Hashable, CaseIterable {

    /// `docs/SAFETY.md` § 3's own cycle, and nothing else: its critical read, its owed
    /// read-backs, its bridge jobs, and the restores its own revocation causes.
    ///
    /// Admitted ahead of every waiting turn, behind only the turn in flight, and outside the
    /// snapshot's overtake quota. § 3 runs one cycle at a time and its calls are sequential, so
    /// this queue never holds more than one waiter, and § 3 re-queues only after the turn it
    /// ended has been handed on. Each of its turns therefore waits for at most one turn in
    /// flight, which is what makes D_cycle independent of how many readers are outstanding
    /// (`WatchdogLimits.allowanceRoundTrips(criticalReadKeys:fans:)`).
    case thermalCycle

    /// Every other safety mechanism's reads and writes: § 5, § 6, § 7, the grant's
    /// foreign-control and bounds reads, the cache's source, and level 6. FIFO among
    /// themselves. Blind is the failure mode, and it arrives with no error, no fault and no log
    /// line, because every read eventually succeeds.
    case supervisor

    /// A client's `snapshot`: every discovered key, at 1 Hz. Late is the failure mode, and
    /// a late snapshot is a reading with an older `capturedAt` on it.
    case snapshot
}
