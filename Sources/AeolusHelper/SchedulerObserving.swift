/// The seam `SMCReadScheduler` reports through, and the only way anything outside it learns
/// what it did.
///
/// ## Why the scheduler needs an outward seam at all
///
/// `SMCReadScheduler`'s whole design is arithmetic about waiting — one outstanding
/// supervisor read waits at most two turns, a snapshot completes within
/// `turns × (turnCost + quota × supervisorTurnCost)` — and **none of it is observable in the
/// running daemon.** The numbers in that type's documentation come from
/// `HelperHardwareTests`, which drives it directly; a helper that has been up for a week can
/// say nothing at all about whether the bound it was built around is the bound it is living
/// under. [#133](https://github.com/blamechris/Aeolus/issues/133) is the issue that wants to
/// say it, and [#135](https://github.com/blamechris/Aeolus/issues/135) wants to act on the
/// one case that matters — a waiter parked far longer than the arithmetic permits.
///
/// This is the seam both build on, and #103's decision A7 is that it lands **now**, empty of
/// policy: the two consumers each add their own emission rules against a hook that already
/// exists and is already exercised, rather than each widening the scheduler in their own
/// direction.
///
/// ## What is here and what is deliberately not
///
/// Here: the events. **Not** here — a counter, a rate limit, a log line, a threshold, or any
/// judgement about which of these matters. `SMCReadScheduler` reports; whoever holds the
/// observer decides. That split is the reason this is a protocol and not three `os_log`
/// calls inside the actor: a policy compiled into the scheduler is a policy that cannot be
/// tested apart from it, and the scheduler is the one type in the helper whose timing a test
/// must own completely.
///
/// There is also **no served-from-cache or coalesced event**, and that is a decision rather
/// than an omission. [#134](https://github.com/blamechris/Aeolus/issues/134) will add read
/// coalescing and would want one; a case declared here today would be a `Kind` nothing emits,
/// which `SchedulerObservingTests.everyEventKindIsEmittedInAScriptedRun` cannot cover — and
/// the honest way to carry an uncoverable case is an exemption list, which is a hole in the
/// one assertion that keeps this enum's cases from going quietly dead. #134 adds the case and
/// its emission together, in one change, and the test stays exhaustive throughout.
///
/// ## Fire-and-forget, from inside the actor
///
/// `schedulerDidObserve(_:)` is synchronous and is called from inside `SMCReadScheduler`'s
/// own isolation, in the same step that changes the state being reported. That is what makes
/// the report *ordered*: a `Task` per event would deliver them in whatever order the pool
/// chose, and "three failures in a row" is not a fact an unordered stream can carry.
///
/// The cost of that ordering is a rule on the conformer, and it is not negotiable: **return
/// promptly and do not block.** An implementation that took a lock another task holds would
/// stall the helper's only SMC reader. `ConnectionHealth` — the one conformer in
/// `Sources/` — yields into an `AsyncStream` and returns, which is the shape to copy.
protocol SchedulerObserving: Sendable {

    /// One thing the scheduler just did.
    ///
    /// - Important: called from inside the scheduler's actor. See this protocol's
    ///   documentation: return promptly, take no lock that anything else holds across an
    ///   `await`, and do no work here that a consumer's own task could do instead.
    func schedulerDidObserve(_ event: SchedulerEvent)
}

// MARK: - The events

/// What `SMCReadScheduler` did, as it did it.
///
/// The set is #103 decision A7's, and each case is a fact the scheduler already knows at the
/// instant it is reported — never a derived one. A consumer that wants "how long did this
/// turn wait" subtracts `queuedAt` from its own clock; the scheduler does not compute it,
/// because a scheduler that started measuring its own latency would need a clock seam, and a
/// clock seam is a thing a test can get wrong in a type whose whole subject is ordering.
enum SchedulerEvent: Sendable, Hashable {

    /// A read could not be served at once and took a place in `priority`'s queue.
    ///
    /// [#135](https://github.com/blamechris/Aeolus/issues/135)'s deadline observer starts
    /// here: a waiter still unmatched by a `turnGranted` carrying the same `queuedAt` is a
    /// waiter that has been parked since then.
    case waiterParked(priority: SMCReadPriority, queuedAt: ContinuousClock.Instant)

    /// The connection was handed to a turn at `priority`.
    ///
    /// `queuedAt` is when that turn joined the queue — equal to the grant instant for a turn
    /// admitted straight away, which is how "it waited for nothing" and "it waited" are told
    /// apart without a second case.
    case turnGranted(priority: SMCReadPriority, queuedAt: ContinuousClock.Instant)

    /// A turn gave the connection back — because its read finished, because it threw, or
    /// because a multi-turn read is yielding between slices.
    ///
    /// All three, deliberately. The invariant `SchedulerTurnLifecycleTests` exists for is
    /// that a taken turn is always given back, and an event emitted only on the happy path
    /// would be blind to precisely the failure that matters.
    case turnEnded(priority: SMCReadPriority)

    /// A supervisor turn was admitted ahead of a snapshot turn that was already waiting.
    ///
    /// `consecutive` is how many in a row, after this one — so it is `1` on the first and
    /// `SMCReadScheduler.maxConsecutiveOvertakes` on the last one the quota allows.
    case overtakeTaken(consecutive: Int)

    /// The overtake quota was spent, so the next turn went to the snapshot even though
    /// `waitingSupervisorTurns` supervisor turns were queued.
    ///
    /// `CLAUDE.md` rule 6 in event form: this is the scheduler deliberately making a safety
    /// read wait, and it is the one moment in the design where that happens on purpose. Not
    /// emitted when nothing was overtaken — a snapshot admitted with no supervisor waiting
    /// has exhausted nothing.
    case quotaExhausted(waitingSupervisorTurns: Int)

    /// A whole `read(keys:at:)` completed — every turn of it, in order — and produced at
    /// least one reading.
    ///
    /// One is enough, and it is the only thing that earns this case: a reading is an IOKit
    /// round trip that came back with a value, which is the one fact that proves the handle
    /// alive. A request that failed only on keys this machine does not have is
    /// `wholeReadAbsentOnly`, not this — it *was* this for one head of #198, and ruling D25
    /// is why it is not.
    case wholeReadSucceeded(priority: SMCReadPriority)

    /// A whole `read(keys:at:)` produced no reading, and every failure in it was
    /// `.unknownKey`: the request asked only for keys this machine does not expose.
    ///
    /// ## Neutral, and a third case because neither of the other two is honest about it
    ///
    /// It is not a failure. An absent key is a fact about the *Mac*, not about the handle —
    /// `SMCFanEnumeration` asks every Mac for `FNum` and a fanless one has none, and
    /// `CriticalSensorSet` asks for keys some firmwares lack — so counting it would rebuild
    /// a working connection every 1.5 s for ever, on the machines least able to afford it.
    /// That is ruling D21's false-positive guard and it is unchanged.
    ///
    /// It is not a success either, and for one head of #198 it was reported as one.
    /// `SMCConnection.read(keys:)` answers a key outside `knownKeys` with `.keyNotFound` at
    /// **zero round trips**: nothing in the request touched IOKit, so nothing proved the
    /// handle alive. Reported as a success it *reset* `ConnectionHealth`'s run — and on a
    /// fanless Mac with a stale handle, where the fan-count read is absent-only on every
    /// snapshot, the pump saw success, failure, success, failure for ever, the run peaked at
    /// one, and [#68](https://github.com/blamechris/Aeolus/issues/68)'s
    /// render-unavailable-forever survived the mechanism built to close it. Ruling D25 is
    /// this case: `ConnectionHealth` neither increments nor resets on it.
    ///
    /// A request with at least one real value is `wholeReadSucceeded`; one with no value
    /// and at least one failure that is not `.unknownKey` is `wholeReadFailed`. D21 only had
    /// two answers where three were needed.
    case wholeReadAbsentOnly(priority: SMCReadPriority)

    /// A whole `read(keys:at:)` produced **no reading at all**, and at least one of its
    /// failures was not "this machine does not have that key" — or it threw.
    ///
    /// **A whole-request failure, never a per-key one.** Losing one thermistor out of
    /// thirty-four is not this; the request still answered. This is the connection failing to
    /// answer at all.
    ///
    /// ## It is decided from the outcomes, and a throw is the rarer half
    ///
    /// An earlier version of this comment said the case *was* the throw, and a review
    /// established that the failure it exists for cannot produce one.
    /// [#68](https://github.com/blamechris/Aeolus/issues/68)'s stale `io_connect_t` is open
    /// and non-zero, so `SMCConnection.open()` returns from its own `guard` having done
    /// nothing and `SMCConnection.read(keys:)` — which does not throw — reports every key as
    /// a per-key failure. The one event `ConnectionHealth` counts was therefore unreachable
    /// on the one machine state it was written for.
    /// `SMCReadScheduler.wholeReadEvent(for:at:)` is the rule that replaced it, and carries
    /// the reasoning — including why `.unknownKey` is on neither side of it, which is
    /// `wholeReadAbsentOnly`.
    ///
    /// `detail` is diagnostic and is never parsed.
    case wholeReadFailed(priority: SMCReadPriority, detail: String)
}

extension SchedulerEvent {

    /// A case's discriminant, without its payload.
    ///
    /// It exists for one assertion — that a scripted run emits every kind — and that
    /// assertion is what stops a case from going quietly dead. Adding a case to
    /// `SchedulerEvent` and forgetting to emit it is otherwise invisible: nothing fails to
    /// compile, and a consumer simply never hears about a thing that happens.
    /// `CaseIterable` on the discriminant is what makes the check exhaustive by
    /// construction rather than by a list somebody remembered to extend.
    enum Kind: Sendable, Hashable, CaseIterable {
        case waiterParked
        case turnGranted
        case turnEnded
        case overtakeTaken
        case quotaExhausted
        case wholeReadSucceeded
        case wholeReadAbsentOnly
        case wholeReadFailed
    }

    var kind: Kind {
        switch self {
        case .waiterParked: return .waiterParked
        case .turnGranted: return .turnGranted
        case .turnEnded: return .turnEnded
        case .overtakeTaken: return .overtakeTaken
        case .quotaExhausted: return .quotaExhausted
        case .wholeReadSucceeded: return .wholeReadSucceeded
        case .wholeReadAbsentOnly: return .wholeReadAbsentOnly
        case .wholeReadFailed: return .wholeReadFailed
        }
    }
}
