/// Which of the helper's two readers is asking, and therefore who waits for whom.
///
/// Two cases and no third. [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) puts
/// **one** continuous reader on the machine, inside this process, and the two things that
/// share it want opposite treatment: a safety cycle whose lateness is blindness, and a
/// client snapshot whose lateness is a slightly older reading.
///
/// Deliberately not a number, and deliberately not `TaskPriority`. A numeric level invites
/// a third one to be slipped in between, and the whole point of `SMCReadScheduler`'s
/// starvation bound is that it has exactly one pair to arbitrate between.
///
/// ## Two levels, re-decided rather than inherited
///
/// [#134](https://github.com/blamechris/Aeolus/issues/134) asked for that argument to be
/// re-read rather than assumed, with a fact it did not have when it was written: within
/// `.supervisor` this scheduler is FIFO, so *N* outstanding supervisor reads admit the last
/// of them `N + (N - 1) / SMCReadScheduler.maxConsecutiveOvertakes` turns after it queues —
/// and `docs/SAFETY.md` § 3's cycle is one of those *N*, with no standing among them.
/// [ADR 0010](../../docs/ADR/0010-coalesced-supervisor-reads.md) records the answer:
/// **FIFO stands, and the unbounded reader was bounded instead.**
///
/// The reason is stronger than the one written above, and it is worth having here because
/// this is where the next person will come looking. A third level would fix § 3's *place in
/// line* while leaving the single SMC connection saturated by whatever queued ahead of it —
/// the client snapshot starves, § 5's sweep stretches, and #133's blind spot widens — so it
/// would make read amplification *survivable* rather than impossible. The amplification was
/// the defect; `CriticalTemperatureCache` removes it, and § 3 is then contending with at
/// most one other supervisor read rather than with a client's retry loop. A level, once
/// added, is also effectively permanent: this enum is named at every call site.
///
/// **Revisit when** a supervisor-priority reader exists that can be neither coalesced nor
/// paced. E3's per-command `readEnvelope(ofFan:)` is the candidate — one read per client
/// message, over a value the client is about to act on, which is exactly the shape that
/// cannot be served from a cycle's own reading.
enum SMCReadPriority: Sendable, Hashable, CaseIterable {

    /// `docs/SAFETY.md` § 3's cycle: the curated critical set — thirty-four keys on
    /// `Mac16,5` — on a 1 Hz loop. Blind is the failure mode, and it arrives with no error,
    /// no fault and no log line, because every read eventually succeeds.
    case supervisor

    /// A client's `snapshot`: every discovered key, at 1 Hz. Late is the failure mode, and
    /// a late snapshot is a reading with an older `capturedAt` on it.
    case snapshot
}
