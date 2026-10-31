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
    /// which runs before reconciliation (ADR 0014 D5): at most 34 round trips for ten fans — each
    /// fan's mode and target key info, the force key's info and value, `FNum`, and the restore —
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
    ///   other readers' turns, at most one per fan of them the engaged step at rest
    ///   (`readerTurns`), and behind § 3's lane turns as well — one firing cycle and the latched
    ///   cycles after it, or a quiet cycle with every fan's read-back each second (ADR 0012's
    ///   2026-10-18 amendment). On `Mac16,5` the longer case is 829 round trips, 9.49 s at the
    ///   measured worst round trip; it fits up to N = 12 and not at 13 (10.67 s). **Modelled
    ///   cases, not a bound over every history**: a firing cycle, its release and the read-backs
    ///   after it can fall in one window, and a latched cycle can take fans back. Counted for
    ///   those histories by the scripts in `scripts/gate-wait-model/` — `engaged_step.py` gives
    ///   this branch's figures, the rest ADR 0012's, which take every reader at five — they are
    ///   795–839 round trips (9.11–9.61 s) counted correctly and at most 619 (7.09 s) in an event
    ///   model of the shipped policy, all under G. Two families stay open (ADR 0012's 2026-10-31
    ///   amendment). How many take-backs with writes can follow one firing: if one recurred every
    ///   cycle the count would be 927 (10.62 s), over G. And a refused revocation recurring every
    ///   latched cycle: 867–877 (9.93–10.04 s), whose upper end passes G as a wait; that member's
    ///   slot was over G before the engaged step existed (874, 10.01 s). The gate fault itself
    ///   ends nothing, but **G is also the slot ADR 0014's examination gate counts its lawful hold
    ///   in**: in the take-back history a slot is 10.72 s, and three slots and
    ///   `FanExaminationGate.stepWait` 33.16 s, so § 5's 32 s `examinationWait` could run out
    ///   inside a lawful hold, at an expiry's cost (ADR 0014: a `.fault`, an examination without
    ///   the gate, possibly a false divergence and a spent attempt); in the refused-revocation
    ///   history they are 10.15 s and 31.44 s, inside it. Taking every reader at the engaged
    ///   step, four of the histories counted correctly passed G already at eight (874–892,
    ///   10.01–10.22 s), which is why the queue counts the long turn once per fan. (G held to
    ///   N = 20 before the lane, when § 3's turns were in the FIFO.) **The snapshot priority's
    ///   waiter is not
    ///   derived:** it waits behind the other snapshot clients' turns as well (64 round trips
    ///   each), so enough concurrent snapshot clients can outlast G with a queue that is full and
    ///   moving. **A lane waiter waits for one turn in flight**, and one past G is a turn that was
    ///   not given back.
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
    /// allows **other than the engaged step**, the step that reads back `1`
    /// (`engagedStepRoundTrips`), and § 3's bridge job, whose length D_cycle counts: a command and
    /// a `.fan` restore, three and at most two. An engagement's first step on the force-key path
    /// is five too — a fresh key info, the raw `F<n>Md` pre-state, the mode write, the force key's
    /// key info and its write. A waiting step is three, and a `commandTarget` three (key info,
    /// write, read-back); a restore issues no read and is one write per key, three on `Mac16,5` for
    /// the machine-wide one and five for four fans.
    ///
    /// **One engagement in progress is one outstanding supervisor reader while it waits for a
    /// turn, and none while it sleeps between steps**, so D7's writes enter N as readers whose
    /// turn is this long rather than as new readers.
    static let writeTurnRoundTrips = 5

    /// The engaged step: **the step that reads back `1`, whatever it writes and whatever the
    /// key-info cache holds** (ADR 0014's P1′ amendment, decision 4, and its "Cost"; ADR 0012's
    /// 2026-10-31 amendment, which records the architect's ruling on
    /// [#465](https://github.com/blamechris/Aeolus/pull/465)'s review). Built in `SMCWriteTurns`
    /// on `e4/bring-up`, the one turn on this branch longer than `writeTurnRoundTrips`.
    ///
    /// - **It raises** the fan to its floor at rest in eight round trips with `F<n>Tg`'s key info
    ///   cached — key info, the raw pre-state, the mode write, its read-back of `1`, the target's
    ///   read (`0` at rest), the target's fresh key info, the floor's write and its read-back —
    ///   and in **nine** without, when the target's read takes the key info itself.
    /// - **It holds** under load, where the target is already at or above the floor, in five, and
    ///   six without.
    ///
    /// **Why the cold case counts.** Two places prime the key, and both carry a failure rather
    /// than throw it: the preparation step (`SMCWriteTurns.survey`), and every grant's
    /// control-state read (`SMCFanControlPlane.readControlState`, which carries a failed `F<n>Tg`
    /// read). A grant can therefore succeed with the key still cold, and the first engaged turn
    /// pays its key info. The floor's read-back is never cold: `freshKeyInfo` replaces the cache
    /// entry, so the read after the floor's write finds it — the premise this rests on, since a
    /// `freshKeyInfo` that did not replace it would make the turn ten. A cold key in any other read
    /// stays where ADR 0012's #332 amendment put it, inside the margin, once per key per process.
    ///
    /// **At most one per fan is ever queued**: one engagement per fan at a time is enforced by the
    /// examination gate (ADR 0014's assumptions), an engagement's steps are sequential, and only
    /// the step that reads back `1` is long. G's arithmetic counts it so (`readerTurns`).
    static let engagedStepRoundTrips = 9

    /// A `.fan(n)` restore's round trips: its mode write, and the force key's when no engaged fan
    /// is left after it (ADR 0014 D5). No read.
    static let fanRestoreRoundTrips = 2

    /// The longest turn any outstanding supervisor reader takes: a mode read, a write turn, or the
    /// engaged step at rest — the larger of the bounds, as ADR 0014's P1′ amendment asks. It is
    /// the longest single turn, and so the turn G's slot adds to the wait
    /// (`WatchdogLimitsTests.theGateBoundCoversAWholeTurn`).
    static let readerTurnRoundTrips = max(modeReadKeys, writeTurnRoundTrips, engagedStepRoundTrips)

    /// The longest turn an outstanding supervisor reader takes **other than an engaged step**: a
    /// mode read, or any other write turn. The gate's queue takes every reader at this but the at
    /// most one engaged step per fan (`readerTurns`), which is the change ADR 0014 D7, and then
    /// its P1′ amendment, asked ADR 0012's arithmetic to re-run for.
    static let otherReaderTurnRoundTrips = max(modeReadKeys, writeTurnRoundTrips)

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
    /// measured worst read: the longest any turn occupies the connection while the longest write
    /// turn, the engaged step's nine round trips, stays under it, which it does up to about
    /// 81.4 ms a round trip (64 × 11.453 / 9; 91.6 ms at eight). That is below the 86.98 ms
    /// break-even of § 3's own writes, so between 81.4 and 86.98 ms the engaged step in flight,
    /// not § 3's own writes, would be the binding term (ADR 0012's 2026-10-31 amendment). Both are
    /// far above the about 20.5 ms at which G's modelled slot breaks, which makes the difference
    /// moot below it (`scripts/gate-wait-model/engaged_step.py`).
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
    /// `outstandingReads` readers outstanding on a machine of `fans` fans, § 3's lane aside: the
    /// longer of two waiters, each behind the turn in flight and the snapshot turns the overtake
    /// quota forces, 64·(⌊(N − 1)/2⌋ + 1) —
    ///
    /// - a **reader** that arrived last, behind the grant path's critical read and the other
    ///   N − 3 readers' turns: 64 + K + R(N − 3) + forced;
    /// - the **grant path's read**, behind all N − 2 readers: 64 + R(N − 2) + forced,
    ///
    /// where R(n) is `readerTurns(_:fans:)`: at most one engaged step per fan at
    /// `engagedStepRoundTrips`, and every other reader at `otherReaderTurnRoundTrips`. The waiter
    /// is worst taken as an ordinary reader, with the engaged steps ahead of it. With a critical
    /// set longer than a reader's turn the reader is the worst, and with a shorter one the grant
    /// path's read. N counts § 3's own read, which is no longer in this queue: it is in the lane,
    /// counted by `gateWaitRoundTrips(outstandingReads:criticalReadKeys:fans:)`. So the supervisor
    /// queue holds N − 1 waiters, the grant path's read and N − 2 readers.
    ///
    /// On `Mac16,5` at N = 12 that is 64 + 34 + (9·2 + 5·7) + 384 = 535; with every reader at the
    /// engaged step's nine it would be 563, and already at eight (554) four of ADR 0012's closed
    /// histories pass G (ADR 0012's 2026-10-31 amendment; the b2 amendment of ADR 0014, as settled
    /// by P1′).
    static func supervisorQueueRoundTrips(
        outstandingReads: Int, criticalReadKeys: Int, fans: Int
    ) -> Int {
        let readers = max(outstandingReads - 2, 0)
        let turnInFlight = maxKeysPerTurn
        let forcedSnapshotTurns =
            maxKeysPerTurn * (max(outstandingReads - 1, 0) / maxConsecutiveOvertakes + 1)
        let lastReader =
            readers > 0
            ? turnInFlight + criticalReadKeys + readerTurns(readers - 1, fans: fans)
                + forcedSnapshotTurns
            : 0
        let grantPathRead = turnInFlight + readerTurns(readers, fans: fans) + forcedSnapshotTurns
        return max(lastReader, grantPathRead)
    }

    /// The round trips of `readers` queued supervisor readers' turns on a machine of `fans` fans:
    /// at most one engaged step per fan, at `engagedStepRoundTrips` (one engagement per fan at a
    /// time, its steps sequential), and every other reader at `otherReaderTurnRoundTrips`.
    static func readerTurns(_ readers: Int, fans: Int) -> Int {
        let engaged = min(readers, max(fans, 0))
        return engaged * engagedStepRoundTrips + (readers - engaged) * otherReaderTurnRoundTrips
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
    /// (`takeBackAnythingEngagedSinceFiring`). Those histories are counted by the scripts, not
    /// here (`scripts/gate-wait-model/engaged_step.py`, with the engaged step once per fan):
    /// 795–839 round trips with the firing head counted once, at most 619 in an event model of the
    /// shipped policy, both under G; 927 if a take-back with writes recurred every cycle, and
    /// 867–877 if a refused revocation did, the two families still open. The refused-revocation
    /// family is bounded in its fully refused form: a fan whose revocation is refused on every
    /// attempt is abandoned and refused at insertion, so at most F such revocations follow a
    /// firing, 819–863 round trips, under G (ADR 0012's 2026-10-31 amendment, read from
    /// the code, not tested). The open cases cost more than a fault line: ADR 0014's examination
    /// gate takes each turn's slot at G, so in the take-back history § 5's examination wait could
    /// run out inside a lawful hold (`gateWaiterAlarm`).
    static func gateWaitRoundTrips(outstandingReads: Int, criticalReadKeys: Int, fans: Int) -> Int {
        let queue = supervisorQueueRoundTrips(
            outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys, fans: fans)
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
