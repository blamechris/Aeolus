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
enum SMCReadPriority: Sendable, Hashable, CaseIterable {

    /// `docs/SAFETY.md` § 3's cycle: the curated critical set — thirty-four keys on
    /// `Mac16,5` — on a 1 Hz loop. Blind is the failure mode, and it arrives with no error,
    /// no fault and no log line, because every read eventually succeeds.
    case supervisor

    /// A client's `snapshot`: every discovered key, at 1 Hz. Late is the failure mode, and
    /// a late snapshot is a reading with an older `capturedAt` on it.
    case snapshot
}
