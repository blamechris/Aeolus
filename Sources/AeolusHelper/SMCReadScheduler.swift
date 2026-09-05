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
/// That wait is invisible: no read fails, nothing throws, no log line is emitted — § 3 is
/// simply reading a temperature from half a second ago while a fan is pinned. It is the
/// shape [#127](https://github.com/blamechris/Aeolus/issues/127) was filed against, and why
/// `FanControlPlane`'s seam was drawn: **the seam made this schedulable; this schedules it.**
///
/// ## The measurement the design rests on
///
/// From ADR 0006 and re-measured by `Tests/AeolusHelperTests/HelperHardwareTests` on every
/// hardware run, on `Mac16,5` / macOS 26.6.2:
///
/// | What | Cost | How often |
/// |---|---|---|
/// | Discovery, `readAll()` | 2.2 s warm, 5.9 s cold | once per process |
/// | Warm snapshot refresh, ~2929 keys | ~0.5 s | every tick, at 1 Hz |
///
/// ~0.5 s across ~2929 keys is **~0.17 ms per key**, and every number below derives from
/// that one figure. The count moves with the OS build — 2929 on 26.5.2, 2930 on 26.6.2, and
/// `ceil(n/64)` is 46 either way — so nothing asserts on it; ADR 0006 has the detail.
/// #127's summary quotes "2.2 s warm" for the snapshot; that is the *discovery* cost, which
/// this type does not schedule. The refresh governs a turn.
///
/// ## Turns
///
/// Access is granted in **turns** of at most `maxKeysPerTurn` keys. A large read is split
/// into as many as it needs and gives the connection up between them, converting one 0.5 s
/// occupation into 46 short ones a waiting supervisor can be admitted between.
///
/// Splitting is not a loss of atomicity that anything relied on: a 2929-key snapshot already
/// spans ~0.5 s and carries a single `capturedAt`, so its readings were never simultaneous.
/// What changes is only who else may read inside that window.
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
///   forces a snapshot turn after every `maxConsecutiveOvertakes`, so with *N* supervisor
///   reads outstanding the last is admitted `N + (N - 1) / maxConsecutiveOvertakes` turns
///   after it queues — **4 turns for N=3 and 17 for N=12**, one more in each case if the
///   quota was already spent. (Two earlier drafts had this wrong: `N + N / …` differs at
///   every **even** N, and the correction that said "from N=4 up" excluded N=2 where it is
///   wrong and implied N=5 where it is not.) N=3 is measured by the test named below;
///   N=12 is derived, not observed.
///
///   That is not a defect the scheduler could fix: a serial connection cannot serve two
///   readers at once, and a supervisor read waiting behind other supervisor work is not the
///   snapshot delaying it. It is a defect in the *claim*, and the claim is what a future
///   reader checks the mechanism against instead of re-deriving it.
///
///   It is also not hypothetical. `LeaseAuthority.refuseIfBlind` already issues a
///   supervisor-priority `readCriticalTemperatures` per `acquireLease`, unpaced by any
///   cycle, and each XPC message runs in its own `Task`. Those reads do not reach this
///   scheduler *in this build* — they go through `telemetry`, and nothing constructs
///   `SMCFanControlPlane` yet — but the call site exists and #103 connects it, so #103 and
///   #126 will routinely have several outstanding.
///   `SchedulerTurnLifecycleTests.theSupervisorBoundIsPerOutstandingRead` pins the real
///   behaviour so this paragraph cannot drift back.
/// - **A snapshot completes within `turns × (turnCost + quota × supervisorTurnCost)`** —
///   46 × (11 ms + 2 × ~6 ms) ≈ 1.1 s worst case against a ~0.5 s nominal, where ~6 ms is
///   the curated thirty-four keys. Reaching it needs two supervisor reads outstanding at
///   every boundary — arriving within one boundary's span, ~11 ms of snapshot turn plus up
///   to 2 × ~6 ms of supervisor turns, so ~87 Hz — against § 3's 1 Hz. No hardware run has
///   reached it.
///
///   **Per `read(keys:at:)`, not per `snapshot()`.** A `snapshot()` is 48 turns but *three*
///   reads, and between them nothing sits in `snapshotWaiters`, so the quota restarts. The
///   1.1 s bounds the 46-turn refresh; nothing here bounds `snapshot()` end to end, and an
///   earlier draft implied it did. Small in wall-clock, but a gap in the claim — #134.
///
/// `CLAUDE.md` rule 6 is why the second bound is not "the supervisor always wins": a client
/// that never receives a snapshot is a UI reporting nothing, which a user cannot act on.
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
/// **Not worst-case figures**, though two drafts said they were: the loop awaits each cycle,
/// so one supervisor read is ever queued and the quota **never fires**.
/// `SMCReadSchedulerTests.snapshotStarvationIsBounded` covers the two-overtake case, which
/// no hardware run has reached. [ADR 0006](../../docs/ADR/0006-single-smc-reader.md) has the
/// full reconciliation, including why 49 cycles and not 48.
///
/// ## `readAll()` is not a turn, and that is the sharpest decision here
///
/// Discovery is one opaque call on `SensorProvider` that this type cannot split — the walk
/// over the index table belongs to `SMCSensorProvider.readAll()`, not to anything visible
/// from here. Held as a single turn it would be a **guaranteed 2.2 s — 5.9 s cold — with
/// the supervisor locked out**, which is far worse than the defect being fixed.
///
/// So it takes no turn at all — with **one** exclusion kept, because one hazard survives the
/// argument above. A recycle closing the `io_connect_t` mid-walk does not merely slow the walk
/// down: `SMCSensorProvider.readAll()` skips every key that fails, and `ReadOnlyFanAuthority`
/// caches what comes back for the life of the daemon, so the machine would run on a silently
/// truncated sensor set until the next boot. `withExclusiveAccess(_:)` and `readAll()`
/// therefore wait for each other, without either holding a turn while it waits; ruling D22 and
/// that method's documentation have the shape.
///
/// Ungated against *reads*, `readAll()`'s own walk hops the `SMCConnection`
/// actor twice per key, ~2929 times, and a supervisor read enqueued there is serviced
/// within about one round trip. That is a property of how the walk is written rather than a
/// guarantee the language makes about actor fairness, and it is stated that way on purpose:
/// the choice is between a scheduling property that is very good in practice and a
/// structural 5.9 s barrier, not between a guarantee and a hope.
///
/// Its only caller is `ReadOnlyFanAuthority`'s discovery, and the invariant is stated there
/// in the two halves it is actually enforced in: **at most one walk is ever in flight, and
/// after a successful one there are no more.** Not "spent once for the life of the process"
/// — a walk that throws is deliberately not cached, so N failed walks cost N exemptions, one
/// after another. The looser wording is what [#149](https://github.com/blamechris/Aeolus/issues/149)
/// was filed on: two comments describing the same mechanism, one of them optimistic.
///
/// That was a habit until [#149](https://github.com/blamechris/Aeolus/issues/149) and is now
/// an invariant. `snapshot()` awaits inside an actor and is therefore reentrant, so two
/// snapshots racing the very first tick really could each enter discovery before either
/// cached — the authority now holds the in-flight discovery `Task` itself, so the second
/// arrival awaits the running walk instead of starting one.
/// `ReadOnlyFanAuthorityTests.concurrentSnapshotsShareOneDiscovery` drives exactly that
/// interleaving through a provider that suspends inside `readAll()`.
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
    /// `acquireLease`, unpaced and off-cycle. (An earlier version of this comment attributed
    /// the unpaced-retry prediction to `SAFETY.md` § 3. It is not there — § 3 says a latched
    /// emergency *refuses* the next `acquireLease`, and the prediction about how fast a
    /// client comes back is `LeaseAuthority`'s own doc comment. Cite the file that says it.)
    /// The quota still bounds what the snapshot
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
    private var supervisorWaiters: [ParkedTurn] = []
    private var snapshotWaiters: [ParkedTurn] = []

    /// Supervisor turns admitted in a row while a snapshot turn was waiting. Reset by every
    /// snapshot turn, which is what makes "consecutive" mean what it says.
    private var consecutiveOvertakes = 0

    /// Discovery walks running right now — see `withExclusiveAccess(_:)` for what this
    /// excludes and why a turn could not express it.
    ///
    /// A count rather than a flag because this type does not enforce `ReadOnlyFanAuthority`'s
    /// at-most-one-walk invariant and must not quietly depend on it: that invariant lives one
    /// layer up, is stated there, and a second walk arriving here has to be waited out rather
    /// than lose the first one's exclusion.
    private var discoveryWalksInFlight = 0

    /// Exclusive bodies claimed right now, counted from the moment one starts waiting for a
    /// walk rather than from the moment it holds a turn.
    ///
    /// Also a count, and for a sharper reason: two recycles overlapping is ordinary — the
    /// second waits at the gate for the first's turn — and a flag the first cleared on its way
    /// out would let a walk start inside the second one's body.
    private var exclusiveClaims = 0

    /// Exclusive bodies parked until the last discovery walk ends.
    private var waitingForDiscovery: [CheckedContinuation<Void, Never>] = []

    /// Discovery walks parked until the last exclusive claim ends.
    private var waitingForExclusive: [CheckedContinuation<Void, Never>] = []

    /// The underlying provider's identifier, carried so a prioritised view can answer
    /// `SensorProvider.identifier` without an `await`.
    nonisolated let identifier: String

    /// Who is told what this scheduler did, or nobody.
    ///
    /// `nonisolated` and reported synchronously, so a report costs no actor hop and no task —
    /// see `SchedulerObserving`, which also carries the rule that buys: a conformer must
    /// return promptly, because this call happens inside the turn it is describing.
    ///
    /// Optional because the daemon is the only composition that has one: every scheduler
    /// built under `Tests/` for a reason other than observing passes nothing, and gets the
    /// same code path with the reports discarded at the `?.`.
    nonisolated private let observer: (any SchedulerObserving)?

    init(provider: some SensorProvider, observer: (any SchedulerObserving)? = nil) {
        self.provider = provider
        self.identifier = provider.identifier
        self.observer = observer
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
        defer { endTurn(at: priority) }

        do {
            for (offset, turn) in Self.turns(over: keys).enumerated() {
                if offset > 0 { await yieldTurn(at: priority) }
                outcomes.append(contentsOf: try await provider.read(keys: Array(turn)))
            }
        } catch {
            // Reported here rather than in the `defer`, because the `defer` cannot see the
            // error and a "the read ended" event that could not say whether it ended well is
            // exactly the successful-report-of-nothing shape this repository keeps refusing.
            report(.wholeReadFailed(priority: priority, detail: String(describing: error)))
            throw error
        }

        // A throw is not the only way a whole read fails, and for the case this hook exists
        // for it is not even the usual one. See `blindnessDetail(in:)`.
        if let detail = Self.blindnessDetail(in: outcomes) {
            report(.wholeReadFailed(priority: priority, detail: detail))
        } else {
            report(.wholeReadSucceeded(priority: priority))
        }
        return outcomes
    }

    /// Why this request produced **nothing**, or `nil` if it produced anything at all.
    ///
    /// ## Deciding from the outcomes rather than from a throw, and why that is the whole fix
    ///
    /// The first version of this type reported `.wholeReadFailed` only when
    /// `provider.read(keys:)` threw, and a review established that
    /// [#68](https://github.com/blamechris/Aeolus/issues/68)'s stale `io_connect_t` **cannot
    /// reach that path**: `SMCSensorProvider.read(keys:)` throws from exactly one place,
    /// `SMCConnection.open()`, and `open()` is `guard connection == 0 else { return }` — a
    /// handle that is stale but non-zero returns from it having done nothing. What follows is
    /// `SMCConnection.read(keys:)`, which is `keys.map(readOutcome(for:))` and is **not
    /// throwing**: it reports every key as a per-key `.readFailed` and returns normally. So
    /// the exact failure `ConnectionHealth` was built to notice arrived here as a *successful*
    /// read of nothing, and the only test that said otherwise was a double that threw where
    /// production does not. #103's ruling D21 is this method.
    ///
    /// ## The three-way rule, and why `.unknownKey` is on the other side of it
    ///
    /// - A request in which **any** key produced a value read successfully. One thermistor
    ///   going quiet is not the connection, and never was — that is the distinction the
    ///   `wholeReadFailed` case's documentation has always drawn.
    /// - A request in which every failure is `.unknownKey` succeeded too. An absent key is a
    ///   fact about the *machine*, not about the handle: `CriticalSensorSet` deliberately asks
    ///   for keys a given Mac may not expose, and `SMCConnection.read(keys:)` answers a key a
    ///   completed walk never saw with `.keyNotFound` at zero round trips — so a subset that
    ///   this firmware simply lacks would otherwise reconnect the helper, on a connection that
    ///   is answering perfectly, once every 1.5 s for ever.
    /// - Anything else — no value anywhere, and at least one failure that is not
    ///   `.unknownKey` — is the connection failing to answer at all.
    ///
    /// An empty `outcomes` array reports success. It is unreachable through
    /// `SensorProvider`'s contract (one outcome per requested key, and `read(keys:at:)`
    /// returns early on an empty request), and inventing a connection failure out of a
    /// provider returning nothing would be claiming a fault that nothing observed.
    private static func blindnessDetail(in outcomes: [SensorReadOutcome]) -> String? {
        var firstFailure: SensorReadOutcome?
        for outcome in outcomes {
            switch outcome.result {
            case .success:
                return nil
            case .failure(.unknownKey):
                continue
            case .failure:
                if firstFailure == nil { firstFailure = outcome }
            }
        }

        guard let failed = firstFailure, case .failure(let reason) = failed.result else {
            return nil
        }
        return """
            no key in a \(outcomes.count)-key request produced a value: \(failed.key) \
            reported \(reason.readableDescription)
            """
    }

    // MARK: - Exclusive access

    /// Runs `body` with no read and no discovery walk touching the connection: an ordinary
    /// turn, plus mutual exclusion against the one occupation of the connection that takes no
    /// turn at all.
    ///
    /// It exists for exactly one caller — `SMCFanControlPlane.reconnect()`, which closes the
    /// `io_connect_t` and opens a new one — and the reason it must be a scheduler verb rather
    /// than something the plane does on its own is that **a close racing a read invalidates
    /// the handle the read is holding.** `SMCSensorProvider.read(keys:)` opens idempotently
    /// and then issues its round trips against whatever handle it found; a recycle landing in
    /// the middle of that is a read against a closed connection, reported as a firmware
    /// failure that nothing on this machine caused.
    ///
    /// ## What it does and does not serialise
    ///
    /// A **multi-turn read is not held off end to end**: a 46-turn snapshot yields between
    /// slices, and this may be admitted in one of those gaps. That is correct rather than a
    /// gap in the exclusion — the provider reopens on the next slice, and a snapshot's
    /// readings were never simultaneous anyway (see this type's documentation on splitting).
    /// What must never happen is a recycle *inside* one `provider.read(keys:)` call, and that
    /// is precisely what a turn prevents.
    ///
    /// **`readAll()` is the exception a turn cannot cover, so it is covered separately.**
    /// Discovery takes no turn by design — holding one would be a 2.2 s, 5.9 s cold, barrier
    /// against the safety cycle — so for one release of this file "an ordinary turn and
    /// nothing more" meant a recycle could close the handle in the middle of the walk. The
    /// walk skips every key that fails (`SMCSensorProvider.readAll()` is a chain of `try?`s)
    /// and `ReadOnlyFanAuthority` caches what it returns for the life of the daemon, so the
    /// visible result would have been a permanently truncated sensor set with nothing logged.
    /// #103's ruling D22 is the two waits below: this body waits for a walk that is already
    /// running, and `readAll()` waits for a body that is already running. Neither ever holds a
    /// turn while waiting for the other, which is what keeps reads flowing throughout and what
    /// makes the pair deadlock-free — a walk that is already counted never waits.
    ///
    /// `ConnectionRecoveryTests` scripts both directions against an ordered log the provider
    /// and the connection share: `aReconnectNeverLandsInsideAReadInFlight`,
    /// `aReconnectWaitsForADiscoveryWalkInFlight`, and `aDiscoveryWalkWaitsForARecycle`.
    ///
    /// - Important: `body` is run **while this actor is suspended and the turn is held**, so
    ///   it must not issue a read through this scheduler. It would queue behind a turn only
    ///   its own caller can release.
    func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        // Claimed *before* the wait, so a walk arriving while this one waits queues behind it
        // rather than joining the set being waited on — otherwise a machine discovering in a
        // loop could defer a recycle indefinitely.
        exclusiveClaims += 1
        defer { endExclusiveClaim() }

        // `while`, not `if`: being resumed only means the count was zero at the instant the
        // waiter was woken, and re-entering this actor is a second hop.
        while discoveryWalksInFlight > 0 {
            await withCheckedContinuation { waitingForDiscovery.append($0) }
        }

        // The turn is taken after the walk, never before it: holding one across a 5.9 s cold
        // walk would lock the safety cycle out for exactly the span this type exists to stop
        // anything holding.
        await takeTurn(at: .supervisor)
        defer { endTurn(at: .supervisor) }
        return try await body()
    }

    /// Discovery. **Takes no turn** — see this type's documentation for why holding one
    /// would be worse than the contention it would be trying to arbitrate.
    ///
    /// It is still excluded against `withExclusiveAccess(_:)`, which is a different claim from
    /// taking a turn and is the whole of ruling D22: a walk waits for a recycle that is
    /// already claimed, and is counted for as long as it runs so a recycle waits for it.
    func readAll() async throws -> [SensorReading] {
        while exclusiveClaims > 0 {
            await withCheckedContinuation { waitingForExclusive.append($0) }
        }

        discoveryWalksInFlight += 1
        // Holds on a throwing walk too, which is the path that matters: a walk that failed
        // and left the count raised would refuse every future recycle for the life of the
        // process, and #68 is exactly the case where walks are failing.
        defer { endDiscoveryWalk() }
        return try await provider.readAll()
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

    /// How many exclusive bodies are waiting for a discovery walk to finish.
    ///
    /// `queuedTurns(at:)`'s sibling and there for the same #109 reason: without it, "the
    /// recycle is waiting rather than barging in" is a fact a test can only infer from
    /// timing, and a regression then arrives as a killed CI job instead of a red line.
    var recyclesWaitingForDiscovery: Int { waitingForDiscovery.count }

    /// How many discovery walks are waiting for an exclusive body to finish. The mirror of
    /// `recyclesWaitingForDiscovery`, for the other direction of the same exclusion.
    var walksWaitingForARecycle: Int { waitingForExclusive.count }

    /// Ends this walk and, if it was the last, wakes everything waiting for one.
    private func endDiscoveryWalk() {
        discoveryWalksInFlight -= 1
        guard discoveryWalksInFlight == 0 else { return }
        let parked = waitingForDiscovery
        waitingForDiscovery.removeAll()
        for waiter in parked { waiter.resume() }
    }

    /// Ends this claim and, if it was the last, wakes every walk waiting for one.
    private func endExclusiveClaim() {
        exclusiveClaims -= 1
        guard exclusiveClaims == 0 else { return }
        let parked = waitingForExclusive
        waitingForExclusive.removeAll()
        for waiter in parked { waiter.resume() }
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
            // `queuedAt` is now, because this turn queued for nothing. A consumer computing
            // a wait therefore gets zero rather than a missing value, which is what lets
            // `turnGranted` be one case instead of two.
            report(.turnGranted(priority: priority, queuedAt: ContinuousClock.now))
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
        report(.turnEnded(priority: priority))
        await withCheckedContinuation { continuation in
            enqueue(continuation, at: priority)
            admitNext()
        }
    }

    /// Releases the connection at the end of a read, or of an exclusive body.
    private func endTurn(at priority: SMCReadPriority) {
        isTurnInFlight = false
        report(.turnEnded(priority: priority))
        admitNext()
    }

    private func enqueue(
        _ continuation: CheckedContinuation<Void, Never>, at priority: SMCReadPriority
    ) {
        let parked = ParkedTurn(
            continuation: continuation, priority: priority, queuedAt: ContinuousClock.now)
        switch priority {
        case .supervisor: supervisorWaiters.append(parked)
        case .snapshot: snapshotWaiters.append(parked)
        }
        report(.waiterParked(priority: priority, queuedAt: parked.queuedAt))
    }

    /// Hands the connection to whichever waiter the policy chooses, if any.
    private func admitNext() {
        guard !isTurnInFlight, let next = nextTurn() else { return }
        isTurnInFlight = true
        report(.turnGranted(priority: next.priority, queuedAt: next.queuedAt))
        next.continuation.resume()
    }

    /// The policy itself: strict supervisor priority, spent down by a quota.
    ///
    /// Deleting the middle branch is the mutation `SMCReadSchedulerTests` names — it leaves
    /// a plain two-queue FIFO that compiles, answers every key correctly, and orders the
    /// supervisor behind the snapshot again. Run: the three ordering tests go red and the
    /// read-correctness ones stay green, which is the split worth having.
    private func nextTurn() -> ParkedTurn? {
        // Nobody to starve: the quota has nothing to protect, so it does not run down.
        guard !snapshotWaiters.isEmpty else {
            consecutiveOvertakes = 0
            return supervisorWaiters.isEmpty ? nil : supervisorWaiters.removeFirst()
        }

        if !supervisorWaiters.isEmpty, consecutiveOvertakes < Self.maxConsecutiveOvertakes {
            consecutiveOvertakes += 1
            report(.overtakeTaken(consecutive: consecutiveOvertakes))
            return supervisorWaiters.removeFirst()
        }

        // Only when something was actually overtaken. A snapshot admitted with no supervisor
        // waiting has spent no quota, so reporting one here would make the event mean "a
        // snapshot went next" — which is every ordinary turn and therefore nothing.
        if !supervisorWaiters.isEmpty {
            report(.quotaExhausted(waitingSupervisorTurns: supervisorWaiters.count))
        }
        consecutiveOvertakes = 0
        return snapshotWaiters.removeFirst()
    }

    // MARK: - Reporting

    /// Tells the observer, if there is one.
    ///
    /// `nonisolated` because it touches no state of this actor: the observer is a
    /// `nonisolated let` and the call is synchronous, so a report costs neither a hop nor a
    /// task and cannot reorder against the state change it describes. See
    /// `SchedulerObserving` for the obligation that puts on a conformer.
    nonisolated private func report(_ event: SchedulerEvent) {
        observer?.schedulerDidObserve(event)
    }

    // MARK: - Values

    /// A turn waiting for the connection: who to resume, at what priority, and since when.
    ///
    /// The `queuedAt` instant is the whole reason this is a struct rather than the bare
    /// continuation it was: it travels with the waiter so `turnGranted` can report what the
    /// turn waited from, which is what [#135](https://github.com/blamechris/Aeolus/issues/135)
    /// needs and what no consumer could reconstruct from outside.
    ///
    /// `ContinuousClock` directly rather than the helper's `MonotonicClock` seam, because
    /// this value is carried and reported and **never compared against a deadline here**. A
    /// clock seam on the scheduler would be a knob on the one type whose subject is ordering,
    /// bought for a timestamp nothing in this file reads.
    private struct ParkedTurn {
        let continuation: CheckedContinuation<Void, Never>
        let priority: SMCReadPriority
        let queuedAt: ContinuousClock.Instant
    }
}
