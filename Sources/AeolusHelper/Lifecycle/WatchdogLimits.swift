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
    /// `requiredCycleBound(outstandingReads:criticalReadKeys:)` is the derivation, at a design
    /// point of 12 supervisor-priority reads outstanding at once (today's build is 3; nothing
    /// bounds the count, [#332](https://github.com/blamechris/Aeolus/issues/332)). 15 s holds for
    /// up to 16 of them and not for 17, **for a critical set of at most `maxKeysPerTurn` keys**
    /// (`WatchdogLimitsTests` checks every curated set).
    static let cycleBound: Duration = roundTrip * 3

    /// **D_bringUp**: from arming to `ThermalSupervisor.start()`. The reconciliation budget
    /// plus 2·D, and independent of how many reads are outstanding: no client can reach the
    /// helper before `listener.resume()`.
    static let bringUpBound: Duration = ReconciliationLimits.budget + roundTrip * 2

    /// **G**, 2·D: a scheduler waiter parked at the gate for longer than this, with no stamped
    /// round trip older than one tick to explain it, is logged at `.fault` and **nothing more**
    /// ([#135](https://github.com/blamechris/Aeolus/issues/135)). It ends nothing: the gate is
    /// not cancellable, so there is no wait to abandon, and the action on a gate that never turns
    /// is D_cycle's, because § 3 reads through the same gate and starves behind a leaked turn.
    ///
    /// **Derived, with two sides** (`requiredGateBound(outstandingReads:criticalReadKeys:)` and
    /// `WatchdogLimitsTests`):
    ///
    /// - *Above* the longest legal **supervisor** wait at the design point of 12 supervisor reads
    ///   outstanding, 6.22 s at the measured worst round trip: a 3-key mode read that arrived
    ///   last, behind both 34-key critical reads, 543 round trips (see `gateWaitRoundTrips`). A
    ///   gate fault below that would be logged for a queue that is full and moving. (The first
    ///   draft set G = D = 5 s, under it.) It holds for up to 20 outstanding reads and fails at 21
    ///   (10.19 s). **The snapshot priority's waiter is not derived:** it waits behind the other
    ///   snapshot clients' turns as well (64 round trips each), so enough concurrent snapshot
    ///   clients can outlast G with a queue that is full and moving.
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
    /// `acquireLease` or `restoreAllToAutomatic`.
    static let modeReadKeys = 3

    /// A firing cycle's writes and read-backs on two fans (ADR 0012, "Outstanding reads, and
    /// why D_cycle is 15 s"): the last term of the allowance, taken at the same worst case.
    static let firingCycleRoundTrips = 30

    /// The round trips a § 3 cycle may have to wait behind, with `outstandingReads` readers
    /// outstanding (ADR 0012, "Outstanding reads, and why D_cycle is 15 s"):
    ///
    /// > 64 + 34 + 3·(N − 2) + 64·(⌊(N − 1)/2⌋ + 1) + 34 + 30
    ///
    /// the turn already in flight; the grant path's curated critical read; the other readers'
    /// mode reads; the snapshot turns the overtake quota forces; § 3's own read; and a firing
    /// cycle's writes and read-backs.
    ///
    /// `criticalReadKeys` is the size of the machine's curated critical set
    /// (`CriticalSensorSet.keys.count`: 34 on `Mac16,5`). It is a parameter and not a literal
    /// because it differs per machine, and a machine with no curated set has none to read.
    static func allowanceRoundTrips(outstandingReads: Int, criticalReadKeys: Int) -> Int {
        let turnInFlight = maxKeysPerTurn
        let grantPathRead = criticalReadKeys
        let otherModeReads = modeReadKeys * max(outstandingReads - 2, 0)
        let forcedSnapshotTurns =
            maxKeysPerTurn * (max(outstandingReads - 1, 0) / maxConsecutiveOvertakes + 1)
        let ownRead = criticalReadKeys
        return turnInFlight + grantPathRead + otherModeReads + forcedSnapshotTurns + ownRead
            + firingCycleRoundTrips
    }

    /// The round trips the **worst supervisor waiter** at the gate may legally have to wait
    /// behind, with `outstandingReads` readers outstanding: D_cycle's allowance, less the terms
    /// that are not ahead of that waiter. A firing cycle's writes follow § 3's read, so they are
    /// ahead of nobody. The waiter's own read is not ahead of itself, and which waiter is worst
    /// depends on the machine:
    ///
    /// - a **mode read** that arrived last (`modeReadKeys` round trips) is behind *both* critical
    ///   reads, the grant path's and § 3's, so only its own keys come off the allowance;
    /// - **§ 3's own read** (`criticalReadKeys` round trips) is behind the grant path's but not
    ///   its own, so its own keys come off.
    ///
    /// On `Mac16,5` (34 keys) the mode read is 31 round trips longer; on a machine with a
    /// shorter set than a mode read, § 3's read is. The longer of the two is the bound.
    static func gateWaitRoundTrips(outstandingReads: Int, criticalReadKeys: Int) -> Int {
        let allowance = allowanceRoundTrips(
            outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys)
        return allowance - firingCycleRoundTrips - min(modeReadKeys, criticalReadKeys)
    }

    /// What G must be more than: the longest legal wait at the gate, at the measured worst round
    /// trip. `gateWaiterAlarm` must exceed this at the design point, or a gate fault would be
    /// logged for a queue that is full and moving.
    static func requiredGateBound(outstandingReads: Int, criticalReadKeys: Int) -> Duration {
        measuredWorstRoundTrip
            * gateWaitRoundTrips(
                outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys)
    }

    /// What D_cycle must be at least: the supervisor's interval, plus timer slop, plus D, plus
    /// the allowance at the measured worst round trip. `cycleBound` must not be less than this
    /// at the design point, or a legal slow round trip trips the cycle trigger first and D_cycle
    /// silently becomes the per-round-trip bound.
    static func requiredCycleBound(outstandingReads: Int, criticalReadKeys: Int) -> Duration {
        ThermalSupervisor<SMCFanControlPlane>.defaultInterval + timerSlop + roundTrip
            + measuredWorstRoundTrip
            * allowanceRoundTrips(
                outstandingReads: outstandingReads, criticalReadKeys: criticalReadKeys)
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
