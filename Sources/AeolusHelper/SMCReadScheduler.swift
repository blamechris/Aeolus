import SMCCore

/// The one gate every helper-side SMC read passes through, so the safety cycle is never
/// stuck behind a client's snapshot.
///
/// ## The defect this exists to close
///
/// `SMCConnection.read(keys:)` is `keys.map(readOutcome(for:))` — **synchronous inside the
/// actor, with no suspension point anywhere in it.** A request for every discovered key is
/// therefore one indivisible occupation of the connection, and actor reentrancy cannot
/// help: nothing else runs on `SMCConnection` until the last key returns. A supervisor read
/// issued one key into that request waits for all of the rest.
///
/// That wait is invisible. No read fails, nothing throws, and no log line is emitted —
/// § 3 is simply looking at a temperature from half a second ago while a fan is pinned. It
/// is the exact shape [#127](https://github.com/blamechris/Aeolus/issues/127) was filed
/// against, and the reason the seam in `FanControlPlane` was drawn: **drawing the seam made
/// this schedulable; this type is what schedules it.**
///
/// ## The measurement the design rests on
///
/// From ADR 0006 and re-measured by `Tests/AeolusHelperTests/HelperHardwareTests` on every
/// hardware run, on `Mac16,5` / macOS 26.5.2:
///
/// | What | Cost | How often |
/// |---|---|---|
/// | Discovery, `readAll()` | 2.2 s warm, 5.9 s cold | once per process |
/// | Warm snapshot refresh, 2929 keys | ~0.5 s | every tick, at 1 Hz |
///
/// ~0.5 s across 2929 keys is **~0.17 ms per key**, and every number below is derived from
/// that one figure rather than guessed. #127's summary quotes "2.2 s warm" for the
/// snapshot; that is the *discovery* cost, which this type deliberately does not schedule —
/// see below. The number that governs a turn is the refresh.
///
/// ## Turns
///
/// Access is granted in **turns**, and no turn may cover more than `maxKeysPerTurn` keys. A
/// large read is split into as many turns as it needs and gives the connection up between
/// them, which is what converts one 0.5 s occupation into 46 short ones a waiting
/// supervisor can be admitted between.
///
/// Splitting is not a loss of atomicity that anything relied on: a 2929-key snapshot already
/// spans ~0.5 s of wall time and carries a single `capturedAt`, so its readings were never
/// simultaneous. What changes is only who else may read inside that window.
///
/// ## Priority, and the bound in the other direction
///
/// A waiting supervisor turn is admitted ahead of a waiting snapshot turn — but only
/// `maxConsecutiveOvertakes` times in a row. After that the next turn goes to the snapshot
/// whatever else is queued. Both directions are therefore bounded, and both bounds are
/// arithmetic rather than hope:
///
/// - **One outstanding supervisor read waits at most two turns** — the one in flight, plus
///   one more if it arrives with the overtake quota already spent. At 64 keys a turn that is
///   ~22 ms, against the ~500 ms it waits today.
///
///   **The qualifier is load-bearing, and this bullet stated it unconditionally until a
///   review panel produced the counterexample.** `supervisorWaiters` is FIFO, and the quota
///   forces a snapshot turn after every `maxConsecutiveOvertakes`, so *N* concurrently
///   outstanding supervisor reads make the last one wait roughly
///   `N + N / maxConsecutiveOvertakes` turns — measured at 4 turns for N=3, and 17 for N=12.
///   That is not a defect the scheduler could fix: a serial connection cannot serve two
///   readers at once, and a supervisor read waiting behind other supervisor work is not the
///   snapshot delaying it. It is a defect in the *claim*, and the claim is what a future
///   reader checks the mechanism against instead of re-deriving it.
///
///   It is also not hypothetical. `LeaseAuthority.refuseIfBlind` already issues
///   supervisor-priority reads off the § 3 cycle, one per `acquireLease`, and each XPC
///   message runs in its own `Task` — so #103 and #126 will routinely have several
///   outstanding at once. `SMCReadSchedulerTests.theSupervisorBoundIsPerOutstandingRead`
///   pins the real behaviour so this paragraph cannot quietly drift back.
/// - **A snapshot completes within `turns × (turnCost + quota × supervisorTurnCost)`** —
///   46 × (11 ms + 2 × ~6 ms) ≈ 1.1 s worst case against a ~0.5 s nominal, where ~6 ms is
///   the curated thirty-four keys. Reaching it needs two supervisor reads outstanding at
///   every turn boundary — they must arrive within one boundary's span, ~11 ms of snapshot
///   turn plus up to 2 × ~6 ms of supervisor turns, so ~87 Hz — against § 3's 1 Hz. The
///   quota is for the adversarial case, not the expected one, and no hardware run has
///   reached it.
///
/// `CLAUDE.md` rule 6 is why the second bound is not simply "the supervisor always wins": a
/// client that never receives a snapshot is a UI reporting nothing, and a UI reporting
/// nothing is a UI a user cannot act on.
///
/// ### What that came out as, on the machine
///
/// `HelperHardwareTests` drives the real thing and prints it. One run on `Mac16,5`, with the
/// curated cycle re-issued in a serial loop — 49 cycles against an 898 ms snapshot, so
/// **~55 Hz**:
///
/// | | Measured |
/// |---|---|
/// | 34 curated keys, uncontended | 7.0 ms |
/// | Warm 2930-key snapshot, uncontended | 601 ms |
/// | **Worst cycle against an in-flight snapshot** | **31.3 ms**, over 49 cycles |
/// | That snapshot, under the load | 898 ms |
///
/// 31.3 ms against the ~601 ms a cycle would wait behind an unscheduled refresh. That is the
/// number this whole type exists to produce, and it is measured.
///
/// **What these figures are not.** An earlier draft called them worst-case and the load
/// ~180 Hz; both were wrong, and a review panel caught it. The test's loop awaits each cycle
/// before issuing the next, so at most **one** supervisor read is ever queued — and when a
/// lone supervisor turn ends, `nextTurn()` finds `supervisorWaiters` empty, takes the
/// "nobody to starve" branch and resets `consecutiveOvertakes`. The quota therefore never
/// reaches its limit under this load and **never fires**: 46 turns × one overtake each is
/// exactly the 49 cycles observed, and deleting the quota outright leaves the hardware test
/// passing with the same numbers. The two-overtake case is unmeasured on hardware; what
/// covers it is `SMCReadSchedulerTests.snapshotStarvationIsBounded`, which queues twelve
/// supervisor reads at once and asserts the gaps. Read 898 ms as one-overtake-per-boundary,
/// never as the ceiling the bound permits.
///
/// ## `readAll()` is not a turn, and that is the sharpest decision here
///
/// Discovery is one opaque call on `SensorProvider` that this type cannot split — the walk
/// over the index table belongs to `SMCSensorProvider.readAll()`, not to anything visible
/// from here. Held as a single turn it would be a **guaranteed 2.2 s — 5.9 s cold — with
/// the supervisor locked out**, which is far worse than the defect being fixed.
///
/// So it takes no turn at all. Ungated, `readAll()`'s own walk hops the `SMCConnection`
/// actor twice per key, ~2929 times, and a supervisor read enqueued there is serviced
/// within about one round trip. That is a property of how the walk is written rather than a
/// guarantee the language makes about actor fairness, and it is stated that way on purpose:
/// the choice is between a scheduling property that is very good in practice and a
/// structural 5.9 s barrier, not between a guarantee and a hope.
///
/// Its only caller is `ReadOnlyFanAuthority`'s discovery, which caches its key set and so
/// runs once for the life of the process on the sequential path
/// `ReadOnlyFanAuthorityTests` covers. Not *provably* once: `snapshot()` awaits inside an
/// actor and is therefore reentrant, so two snapshots racing the very first tick can each
/// enter discovery before either caches. That predates this type and is unchanged by it —
/// it is written down here because "once per process" is the sentence doing the work above,
/// and it is a habit rather than an invariant.
///
/// ## Waiting is not cancellable, deliberately
///
/// A queued turn is resumed by the scheduler and by nothing else, so a cancelled task still
/// waits for its turn. Every turn is bounded and the queue always drains, so that wait is
/// the ~22 ms above. Honouring cancellation at the gate would mean a waiter could vanish
/// between being chosen and being resumed, and the turn would have to be handed on from a
/// task that is already gone — a hole worth far more than 22 ms of promptness in a root
/// daemon.
actor SMCReadScheduler {

    /// The most keys any one turn may cover.
    ///
    /// At the measured ~0.17 ms per key this is ~11 ms of connection occupancy, which sets
    /// the supervisor's worst-case wait, and 46 turns for a 2929-key snapshot, which is the
    /// switching cost. Lower it and the supervisor is admitted sooner against more actor
    /// hops; raise it and the opposite. It is a knob with a measured basis, not a magic
    /// number — but it is not configurable, because a configuration file that could widen
    /// it could blind § 3, and `CLAUDE.md` rule 5 answers that shape of thing generally.
    static let maxKeysPerTurn = 64

    /// The most consecutive supervisor turns that may be admitted ahead of a snapshot turn
    /// that is already waiting.
    ///
    /// Two, because § 3's cycle issues one read per second against a ~0.5 s warm snapshot,
    /// so the *cycle* contributes at most one read per snapshot. One would leave no headroom
    /// for a cycle that overruns.
    ///
    /// **The cycle is not the only supervisor-priority caller**, and an earlier version of
    /// this comment reasoned as though it were. `LeaseAuthority.refuseIfBlind` issues one per
    /// `acquireLease`, unpaced and off-cycle, and `SAFETY.md` § 3 explicitly predicts a
    /// revoked client retrying as fast as it likes. The quota still bounds what the snapshot
    /// suffers — that is what it is for, and it holds however many supervisor readers there
    /// are. It says nothing about how long any one of them waits; see the class doc.
    static let maxConsecutiveOvertakes = 2

    /// The single provider every read here goes to. `SMCSensorProvider` in the daemon, a
    /// double under test.
    private let provider: any SensorProvider

    /// Whether a turn is executing. The invariant that makes the rest simple: **when this
    /// is `false`, both queues are empty**, because every release admits the next waiter in
    /// the same actor-isolated step that clears it.
    private var isTurnInFlight = false

    /// Waiters, FIFO within each priority, so equal-priority reads cannot starve each
    /// other either.
    private var supervisorWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []

    /// Supervisor turns admitted in a row while a snapshot turn was waiting. Reset by every
    /// snapshot turn, which is what makes "consecutive" mean what it says.
    private var consecutiveOvertakes = 0

    /// The underlying provider's identifier, carried so a prioritised view can answer
    /// `SensorProvider.identifier` without an `await`.
    nonisolated let identifier: String

    init(provider: some SensorProvider) {
        self.provider = provider
        self.identifier = provider.identifier
    }

    /// Whether the machine has a readable SMC at all. Takes no turn: it is a static IOKit
    /// capability check that never touches the connection.
    var isAvailable: Bool {
        get async { await provider.isAvailable }
    }

    // MARK: - Reads

    /// Reads `keys`, in as many turns as it takes, at `priority`.
    ///
    /// One outcome per requested key, in the order requested, including duplicates —
    /// `SensorProvider.read(keys:)`'s contract, preserved across the split because turns are
    /// consecutive slices and the results are concatenated in order.
    func read(
        keys: [String], at priority: SMCReadPriority
    ) async throws -> [SensorReadOutcome] {
        guard !keys.isEmpty else { return [] }

        var outcomes: [SensorReadOutcome] = []
        outcomes.reserveCapacity(keys.count)

        await takeTurn(at: priority)
        // Holds on every exit, including a throw from the provider: the turn is held from
        // `takeTurn` above or from the last `yieldTurn` below, and never anywhere else.
        defer { endTurn() }

        for (offset, turn) in Self.turns(over: keys).enumerated() {
            if offset > 0 { await yieldTurn(at: priority) }
            outcomes.append(contentsOf: try await provider.read(keys: Array(turn)))
        }

        return outcomes
    }

    /// Discovery. **Takes no turn** — see this type's documentation for why holding one
    /// would be worse than the contention it would be trying to arbitrate.
    func readAll() async throws -> [SensorReading] {
        try await provider.readAll()
    }

    /// How many turns are queued at `priority`.
    ///
    /// An observation of the queue, not a control on it. It exists so that "the supervisor
    /// read has been queued" is a fact a test can wait on rather than infer from timing —
    /// a race test that infers it reports a regression as a CI timeout instead of a red
    /// assertion, which is [#109](https://github.com/blamechris/Aeolus/issues/109).
    func queuedTurns(at priority: SMCReadPriority) -> Int {
        switch priority {
        case .supervisor: return supervisorWaiters.count
        case .snapshot: return snapshotWaiters.count
        }
    }

    // MARK: - Prioritised views

    /// The snapshot path's `SensorProvider`, and the **only** one this type vends.
    ///
    /// There is deliberately no matching `supervisorReader`. A `SensorProvider` carries no
    /// priority in its signature, so a prioritised view of one is a value whose behaviour
    /// cannot be read off its type — and the one place that would be dangerous is the
    /// safety path. `SMCFanControlPlane` therefore takes this scheduler directly and names
    /// `.supervisor` itself, at the point the read is issued, so a supervisor read wired at
    /// snapshot priority is not a mistake anyone can make.
    ///
    /// `nonisolated` because it reads nothing: it hands back a reference to this actor
    /// wearing a different protocol, which is what lets the composition root wire it
    /// without an `await` in a synchronous `main`.
    nonisolated var snapshotReader: SnapshotSensorReads {
        SnapshotSensorReads(scheduler: self)
    }

    // MARK: - Turns

    /// Consecutive slices of at most `maxKeysPerTurn` keys, in request order.
    private static func turns(over keys: [String]) -> [ArraySlice<String>] {
        stride(from: 0, to: keys.count, by: maxKeysPerTurn).map { start in
            keys[start..<min(start + maxKeysPerTurn, keys.count)]
        }
    }

    /// Waits for the connection, then holds it.
    private func takeTurn(at priority: SMCReadPriority) async {
        if !isTurnInFlight && supervisorWaiters.isEmpty && snapshotWaiters.isEmpty {
            isTurnInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            enqueue(continuation, at: priority)
        }
        // Resumed by `admitNext()`, which set `isTurnInFlight` on this turn's behalf before
        // resuming it. Setting it here instead would leave a window in which the connection
        // looks free to a caller arriving in between — and the fast path above tests the
        // queues as well, so the window is only reachable for a caller arriving in the
        // instant `admitNext()` drains the last waiter. That is narrow enough that a
        // concurrency test which starts all its work at once cannot reach it at all;
        // `SchedulerTurnLifecycleTests.aFreshArrivalCannotBargeOntoAHeldTurn` scripts the
        // arrival, and is the only thing in the suite that catches the flag going missing.
    }

    /// Gives the connection up between two turns of the same read, and takes a place at the
    /// back of the queue for the next one.
    ///
    /// **Enqueueing happens before admitting, and that ordering is load-bearing.** Admitting
    /// first would take a multi-turn snapshot out of the queue at exactly the instant the
    /// scheduler decides whether anybody is being overtaken: it would see no snapshot
    /// waiting, take the "nobody to starve" branch in `nextTurn()`, and reset the quota to
    /// zero on a turn that really did overtake something.
    ///
    /// Measured rather than assumed — the mutation is in `SMCReadSchedulerTests` and was
    /// run: every gap widens from two overtakes to **three**, one free reset per turn
    /// boundary. Not unboundedly, because the snapshot re-enters the queue immediately
    /// afterwards and the quota spends normally from there. That is the more dangerous
    /// shape of the two: a bound that is still enforced, still tested, and quietly means
    /// `maxConsecutiveOvertakes + 1`.
    private func yieldTurn(at priority: SMCReadPriority) async {
        isTurnInFlight = false
        await withCheckedContinuation { continuation in
            enqueue(continuation, at: priority)
            admitNext()
        }
    }

    /// Releases the connection at the end of a read.
    private func endTurn() {
        isTurnInFlight = false
        admitNext()
    }

    private func enqueue(
        _ continuation: CheckedContinuation<Void, Never>, at priority: SMCReadPriority
    ) {
        switch priority {
        case .supervisor: supervisorWaiters.append(continuation)
        case .snapshot: snapshotWaiters.append(continuation)
        }
    }

    /// Hands the connection to whichever waiter the policy chooses, if any.
    private func admitNext() {
        guard !isTurnInFlight, let next = nextTurn() else { return }
        isTurnInFlight = true
        next.resume()
    }

    /// The policy itself: strict supervisor priority, spent down by a quota.
    ///
    /// Deleting the middle branch is the mutation `SMCReadSchedulerTests` names — it leaves
    /// a plain two-queue FIFO that compiles, answers every key correctly, and orders the
    /// supervisor behind the snapshot again. Run: the three ordering tests go red and the
    /// read-correctness ones stay green, which is the split worth having.
    private func nextTurn() -> CheckedContinuation<Void, Never>? {
        // Nobody to starve: the quota has nothing to protect, so it does not run down.
        guard !snapshotWaiters.isEmpty else {
            consecutiveOvertakes = 0
            return supervisorWaiters.isEmpty ? nil : supervisorWaiters.removeFirst()
        }

        if !supervisorWaiters.isEmpty, consecutiveOvertakes < Self.maxConsecutiveOvertakes {
            consecutiveOvertakes += 1
            return supervisorWaiters.removeFirst()
        }

        consecutiveOvertakes = 0
        return snapshotWaiters.removeFirst()
    }
}

/// The snapshot path's view of the scheduler, as a plain `SensorProvider`.
///
/// A view rather than a change to `ReadOnlyFanAuthority`'s shape: the snapshot path asks for
/// keys and gets outcomes, exactly as it did when it held `SMCSensorProvider` directly, and
/// scheduling is a property of where it was obtained rather than of what it does.
///
/// Its initialiser is `fileprivate`, so the only way to hold one is
/// `SMCReadScheduler.snapshotReader` — a reader detached from a scheduler is not a value
/// this module can construct.
struct SnapshotSensorReads: SensorProvider {

    private let scheduler: SMCReadScheduler

    fileprivate init(scheduler: SMCReadScheduler) {
        self.scheduler = scheduler
    }

    var identifier: String { scheduler.identifier }

    var isAvailable: Bool {
        get async { await scheduler.isAvailable }
    }

    func readAll() async throws -> [SensorReading] {
        try await scheduler.readAll()
    }

    func read(keys: [String]) async throws -> [SensorReadOutcome] {
        try await scheduler.read(keys: keys, at: .snapshot)
    }
}
