import Foundation

/// Every bound the liveness watchdog applies, in one place, constant, and derived where it can
/// be (ADR 0012 I8).
///
/// **No XPC message and no configuration can disarm or lengthen any of these.** Lengthening the
/// tick lengthens every verdict (at a 60 s tick, "two ticks" is two minutes); lengthening D
/// lengthens a wedge. They are `static let`, `LivenessWatchdog`'s initialiser takes no
/// `Duration`, and `WatchdogLimitsTests` holds both lines.
///
/// D is **provisional**: it is confirmed for reads only, on `Mac16,5`. It is not confirmed for
/// write selectors (the first supervised E4 write records its own per-round-trip latency
/// before D is trusted for writes), nor for dark wake or the first read after a wake
/// ([#296](https://github.com/blamechris/Aeolus/issues/296) conditions 3 and 4). See ADR 0012.
enum WatchdogLimits {

    // MARK: - The bounds

    /// **D.** One stamped round trip. About 437 times the worst of the 912,000 reads measured on
    /// `Mac16,5` (`measuredWorstRoundTrip`).
    static let roundTrip: Duration = .seconds(5)

    /// **D_cycle**, 3·D: no completed § 3 cycle for this long, while the supervisor runs.
    ///
    /// `requiredCycleBound(criticalReadKeys:fans:worstWriteRoundTrip:)` is the derivation, and
    /// since ADR 0012's 2026-10-18 amendment it has **no N**: § 3's cycle takes its own admission
    /// class, so each of its turns waits for one turn in flight however many supervisor reads are
    /// outstanding (#332 bounds nothing else and stays open for the other readers). On `Mac16,5`
    /// a firing cycle with every restore refused is 632 round trips, 13.34 s with every round
    /// trip at the measured worst and 14.19 s with § 3's write turns at 50 ms; 15 s holds while a
    /// write round trip is under 86.98 ms, and for a curated machine of at most two fans
    /// (`WatchdogLimitsTests` checks every curated set, from its recorded fan count).
    static let cycleBound: Duration = roundTrip * 3

    /// **D_bringUp**: from arming to `ThermalSupervisor.start()`. The reconciliation budget
    /// plus 2·D, and independent of how many reads are outstanding: no client can reach the
    /// helper before `listener.resume()`. It also covers the write path's preparation step,
    /// which runs before reconciliation (ADR 0014 D5): at most 24 round trips for ten fans,
    /// checked in `WatchdogLimitsTests` against the margin with a whole D to spare.
    static let bringUpBound: Duration = ReconciliationLimits.budget + roundTrip * 2

    /// **G**, 2·D: a scheduler waiter parked at the gate for longer than this, with no stamped
    /// round trip older than one tick to explain it, is logged at `.fault` and **nothing more**
    /// ([#135](https://github.com/blamechris/Aeolus/issues/135)). It ends nothing: the gate is
    /// not cancellable, so there is no wait to abandon, and the action on a gate that never turns
    /// is D_cycle's, because § 3 reads through the same gate and starves behind a leaked turn.
    ///
    /// **Derived, with two sides** (`requiredGateBound(outstandingReads:criticalReadKeys:fans:)`
    /// and `WatchdogLimitsTests`):
    ///
    /// - *Above* the **supervisor** wait in two modelled cases at the design point of N = 12
    ///   reads outstanding — N counts § 3's own read, so with § 3 in its lane the supervisor queue
    ///   holds N − 1: a reader that arrived last, behind the grant path's critical read and the
    ///   other readers' turns, and behind § 3's lane turns as well — one firing cycle and the
    ///   latched cycles after it, or a quiet cycle with every fan's read-back each second (ADR
    ///   0012's 2026-10-18 amendment). On `Mac16,5` the longer case is 821 round trips, 9.40 s at
    ///   the measured worst round trip; it fits up to N = 12 and not at 13 (10.58 s). **Modelled
    ///   cases, not a bound over every history**: a firing cycle, its release and the read-backs
    ///   after it can fall in one window, and a latched cycle can take fans back. The amendment
    ///   records the counts for those histories — 817–831 round trips (9.36–9.52 s) counted
    ///   correctly, at most 611 (7.00 s) in an event model of the shipped policy, from the scripts
    ///   in `scripts/gate-wait-model/` — all under G, and the one still open: how many take-backs
    ///   with writes can follow one firing. If one recurred every cycle the count would be 919
    ///   (10.53 s), over G. The gate fault itself ends nothing, but **G is also the slot ADR 0014's
    ///   examination gate counts its lawful hold in**: in that history a slot is 10.58 s, the three
    ///   slots of `FanExaminationGate.lawfulHold` 31.75 s against the 30 s derived, and § 5's 32 s
    ///   `examinationWait` could run out inside a lawful hold, at an expiry's cost (ADR 0014: a
    ///   `.fault`, an examination without the gate, possibly a false divergence and a spent
    ///   attempt). (G held to N = 20 before the lane, when § 3's turns were in the FIFO.) **The
    ///   snapshot priority's waiter is not derived:** it waits behind the other snapshot clients'
    ///   turns as well (64 round trips each), so enough concurrent snapshot clients can outlast G
    ///   with a queue that is full and moving. **A lane waiter waits for one turn in flight**, and
    ///   one past G is a turn that was not given back.
    /// - *Below* D_cycle less the supervisor's interval and two ticks, 12 s: the fault has to be
    ///   in the log before the cycle trigger ends the helper, or it explains nothing.
    ///
    /// Where D_cycle fires first, as it does for a gate that never turns, the fault is the
    /// diagnosis and the cycle trigger is the action.
    static let gateWaiterAlarm: Duration = roundTrip * 2

    /// The watchdog's timer period.
    static let tick: Duration = .seconds(1)

    /// Timer slop the cycle bound allows for, and the leeway the timer is given: a `.strict`
    /// source fires within this of its deadline.
    static let timerSlop: Duration = .milliseconds(100)

    /// How many consecutive ticks must find the same trigger over its bound before the
    /// watchdog acts. One over-bound observation is not a verdict.
    static let ticksPerVerdict = 2

    // MARK: - What the allowance is made of

    /// The slowest single SMC round trip measured on `Mac16,5`, 11.453 ms
    /// (`docs/SMC-RESEARCH.md`, "Per-round-trip SMC latency on Mac16,5 — idle and contended
    /// (issue #296)": idle, paced at 50 ms, 12,000 reads). Every round trip in the allowance
    /// below is taken at this worst, as everywhere in ADR 0012.
    static let measuredWorstRoundTrip: Duration = .microseconds(11_453)

    /// The most keys one scheduler turn covers: the turn already in flight when a read queues.
    static let maxKeysPerTurn = SMCReadScheduler.maxKeysPerTurn

    /// How many supervisor turns may overtake a waiting snapshot before the scheduler forces a
    /// snapshot turn.
    static let maxConsecutiveOvertakes = SMCReadScheduler.maxConsecutiveOvertakes

    /// The keys one `readControlState(ofFan:)` reads: `F<n>Md`, `F<n>Tg` and `F<n>Ac`, in one
    /// turn (`SMCFanControlPlane.readControlState`). One mode read per outstanding
    /// `acquireLease` or `restoreAllToAutomatic`, and one per fan § 3 owes a read-back.
    static let modeReadKeys = 3

    /// The longest write turn [ADR 0014](../../../docs/ADR/0014-apple-silicon-unlock.md) D7
    /// allows: an engagement's first step on the force-key path — the raw `F<n>Md` pre-state,
    /// a fresh key info, the mode write, the force key's key info and its write. A Y-write or a
    /// `commandTarget` is three (key info, write, read-back); a restore issues no read and is
    /// one write per key, three on `Mac16,5` for the machine-wide one and five for four fans.
    /// § 3's bridge job is a command and a `.fan` restore, three and at most two, so five too.
    ///
    /// **One engagement in progress is one outstanding supervisor reader while it waits for a
    /// turn, and none while it sleeps between steps**, so D7's writes enter N as readers whose
    /// turn is this long rather than as new readers.
    static let writeTurnRoundTrips = 5

    /// A `.fan(n)` restore's round trips: its mode write, and the force key's when no engaged fan
    /// is left after it (ADR 0014 D5). No read.
    static let fanRestoreRoundTrips = 2

    /// The longest turn any outstanding supervisor reader takes: a mode read, or a write turn.
    /// The gate's queue takes every other reader at this, which is the change ADR 0014 D7 asked
    /// ADR 0012's arithmetic to re-run for.
    static let readerTurnRoundTrips = max(modeReadKeys, writeTurnRoundTrips)

    // MARK: - D_cycle's allowance, with § 3's lane

    /// § 3's turns in its longest cycle (ADR 0012's 2026-10-18 amendment): a firing cycle on
    /// `fans` held fans, every restore refused — its critical read, one bridge job per fan, and
    /// `RestoreLimits.attemptBudget` restore attempts per fan from the revocation that follows.
    /// The revocation does not skip a fan § 3 has just restored: its restore is the idempotent
    /// second one.
    static func thermalCycleTurns(fans: Int) -> Int {
        1 + fans + fans * RestoreLimits.attemptBudget
    }

    /// The round trips of § 3's own write turns in that cycle: each bridge job, and each restore
    /// attempt.
    static func thermalCycleWriteRoundTrips(fans: Int) -> Int {
        fans * writeTurnRoundTrips + fans * RestoreLimits.attemptBudget * fanRestoreRoundTrips
    }

    /// The round trips a § 3 cycle may take, wait included, on a machine whose curated set is
    /// `criticalReadKeys` keys and whose recorded fan count is `fans`:
    ///
    /// > (1 + F + F·attemptBudget)·64 + K + F·5 + F·attemptBudget·2
    ///
    /// term by term: **one turn in flight ahead of each of § 3's turns** — the lane admits § 3
    /// behind only the turn in flight, its queue holds one waiter, and § 3 re-queues only after its
    /// turn was handed on, so no turn waits for more, and the longest a turn occupies the
    /// connection is `maxKeysPerTurn`; § 3's own critical read; its bridge jobs; and its
    /// revocation's restore attempts.
    ///
    /// **There is no N.** How many other readers are outstanding no longer moves § 3's wait, which
    /// is the whole of the amendment, and the parameter list is what says so. A firing cycle with
    /// every restore accepted is 1 + 2F turns (the read, a bridge job per fan, a restore per fan),
    /// and a quiet cycle with every owed read-back 1 + F. A latched cycle is 1 when nothing was
    /// engaged since the firing; one that takes a fan back (`takeBackAnythingEngagedSinceFiring`)
    /// is up to 1 + F + F·attemptBudget, the firing cycle's own shape. None is longer than this.
    static func allowanceRoundTrips(criticalReadKeys: Int, fans: Int) -> Int {
        maxKeysPerTurn * thermalCycleTurns(fans: fans) + criticalReadKeys
            + thermalCycleWriteRoundTrips(fans: fans)
    }

    /// What D_cycle must be at least: the supervisor's interval, plus timer slop, plus D, plus the
    /// allowance — its reads at the measured worst round trip, and § 3's write turns at
    /// `worstWriteRoundTrip`, the measured worst read unless a caller asks what a slower write
    /// costs. Write round trips are unmeasured (ADR 0012's U8, ADR 0014 H6). `cycleBound` must
    /// not be less than this, or a legal slow round trip trips the cycle trigger first and
    /// D_cycle silently becomes the per-round-trip bound.
    ///
    /// The turn in flight ahead of each of § 3's turns is taken as a 64-key read slice at the
    /// measured worst read: the longest any turn occupies the connection while a write turn of
    /// five round trips stays under it, which it does up to about 146 ms a write.
    static func requiredCycleBound(
        criticalReadKeys: Int, fans: Int, worstWriteRoundTrip: Duration = measuredWorstRoundTrip
    ) -> Duration {
        let writes = thermalCycleWriteRoundTrips(fans: fans)
        let reads = allowanceRoundTrips(criticalReadKeys: criticalReadKeys, fans: fans) - writes
        return ThermalSupervisor<SMCFanControlPlane>.defaultInterval + timerSlop + roundTrip
            + measuredWorstRoundTrip * reads + worstWriteRoundTrip * writes
    }

    /// `requiredCycleBound` for a curated set: its key count and its recorded fan count. `nil`
    /// for a set that records no fan count, which is a bound nothing can check — so a curated set
    /// without one fails `WatchdogLimitsTests`, and `unidentifiedHardware` has none.
    static func requiredCycleBound(for set: CriticalSensorSet) -> Duration? {
        guard let fans = set.fanCount else { return nil }
        return requiredCycleBound(criticalReadKeys: set.keys.count, fans: fans)
    }

    // MARK: - G's lower side, with § 3's lane

    /// The supervisor turns the worst supervisor waiter at the gate may be behind with
    /// `outstandingReads` readers outstanding, § 3's lane aside:
    ///
    /// > 64 + K + 5·(N − 2) + 64·(⌊(N − 1)/2⌋ + 1) − min(5, K)
    ///
    /// the turn in flight, the grant path's critical read, the other readers' turns at the longest
    /// a reader takes, and the snapshot turns the overtake quota forces — less the waiter's own
    /// turn. Which waiter is worst depends on the machine: a **reader** that arrived last
    /// (`readerTurnRoundTrips`) is behind the grant path's read, so its own turn comes off; with a
    /// critical set shorter than a reader's turn the **grant path's read** is the worst, behind the
    /// N − 2 readers, and its own keys come off. N counts § 3's own read, which is no longer in
    /// this queue: it is in the lane, counted by
    /// `gateWaitRoundTrips(outstandingReads:criticalReadKeys:fans:)`. So the supervisor queue
    /// holds N − 1 waiters, the grant path's read and N − 2 readers.
    static func supervisorQueueRoundTrips(outstandingReads: Int, criticalReadKeys: Int) -> Int {
        let turnInFlight = maxKeysPerTurn
        let grantPathRead = criticalReadKeys
        let otherReaders = readerTurnRoundTrips * max(outstandingReads - 2, 0)
        let forcedSnapshotTurns =
            maxKeysPerTurn * (max(outstandingReads - 1, 0) / maxConsecutiveOvertakes + 1)
        return turnInFlight + grantPathRead + otherReaders + forcedSnapshotTurns
            - min(readerTurnRoundTrips, criticalReadKeys)
    }

    /// The round trips the worst supervisor waiter waits in two **modelled cases**: the queue ahead
    /// of it, plus § 3's lane turns that can be admitted ahead of it while it waits (ADR 0012's
    /// 2026-10-18 amendment), in the longer of two windows —
    ///
    /// - **(a)** one firing cycle's turns, its read, bridge jobs and refused restores, then a
    ///   latched cycle's read for every cycle that can start during the wait;
    /// - **(b)** a quiet cycle's turns for every cycle that can start during the wait, each its
    ///   read and a read-back of every fan.
    ///
    /// Two windows because owed read-backs run only on a clear cycle that did not fire
    /// (`ThermalEmergency.readBackAcceptedHandbacks()`), and a firing cycle is followed by latched
    /// ones. At most one § 3 cycle starts per interval plus its own read, so the count is a fixed
    /// point (`laneWindow(base:perCycle:criticalReadKeys:)`).
    ///
    /// **Not a bound over every history.** The latch releases, and read-backs follow a firing in
    /// the same window; a latched cycle can take a fan back
    /// (`takeBackAnythingEngagedSinceFiring`). Those histories are counted in the amendment, not
    /// here: 817–831 round trips with the firing head counted once, at most 611 in an event model
    /// of the shipped policy, both under G; and 919 if a take-back with writes recurred every
    /// cycle, which is the one bound still open. The open case costs more than a fault line:
    /// ADR 0014's examination gate takes each turn's slot at G, so in that history § 5's
    /// examination wait could run out inside a lawful hold (`gateWaiterAlarm`).
    static func gateWaitRoundTrips(outstandingReads: Int, criticalReadKeys: Int, fans: Int) -> Int {
        let queue = supervisorQueueRoundTrips(
            outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys)
        let firing = criticalReadKeys + thermalCycleWriteRoundTrips(fans: fans)
        let quiet = criticalReadKeys + fans * modeReadKeys
        let afterFiring = laneWindow(
            base: queue + firing, perCycle: criticalReadKeys, criticalReadKeys: criticalReadKeys)
        let quietOnly = laneWindow(
            base: queue, perCycle: quiet, criticalReadKeys: criticalReadKeys)
        return max(afterFiring, quietOnly)
    }

    /// The least wait `w` with `w = base + ⌈w·RT / (interval + K·RT)⌉ · perCycle`: `base`, plus
    /// `perCycle` round trips for every § 3 cycle that can start within `w`, one per supervisor
    /// interval and § 3's own read. In whole microseconds, so the ceiling is exact. A wait that
    /// does not settle is `unsettled`, which no curated machine reaches and which fails every
    /// bound it is compared with.
    static func laneWindow(base: Int, perCycle: Int, criticalReadKeys: Int) -> Int {
        let roundTrip = microseconds(measuredWorstRoundTrip)
        let period =
            microseconds(ThermalSupervisor<SMCFanControlPlane>.defaultInterval)
            + roundTrip * Int64(criticalReadKeys)
        // The wait grows by `perCycle` round trips per period, so it settles only while that is
        // less than the period itself.
        guard roundTrip * Int64(perCycle) < period else { return unsettled }
        var wait = base
        for _ in 0..<1_000 {
            let span = roundTrip * Int64(wait)
            let cycles = Int((span + period - 1) / period)
            let next = base + cycles * perCycle
            if next == wait { return wait }
            wait = next
        }
        return unsettled
    }

    /// The wait `laneWindow` answers when it does not settle: about 284 days at the measured
    /// worst round trip, which no bound here can clear and no arithmetic here overflows on.
    private static let unsettled = Int(Int32.max)

    /// What G must be more than: the longest legal supervisor wait at the gate, at the measured
    /// worst round trip. `gateWaiterAlarm` must exceed this at the design point, or a gate fault
    /// would be logged for a queue that is full and moving.
    static func requiredGateBound(
        outstandingReads: Int, criticalReadKeys: Int, fans: Int
    ) -> Duration {
        let wait = gateWaitRoundTrips(
            outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys, fans: fans)
        return measuredWorstRoundTrip * wait
    }

    /// `duration` in whole microseconds, truncated.
    private static func microseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000
    }

    // MARK: - Timer

    /// `tick` as the dispatch timer takes it.
    static var tickInterval: DispatchTimeInterval { dispatchInterval(tick) }

    /// `timerSlop` as the dispatch timer takes it.
    static var timerLeeway: DispatchTimeInterval { dispatchInterval(timerSlop) }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let parts = duration.components
        return .nanoseconds(
            Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000))
    }
}
