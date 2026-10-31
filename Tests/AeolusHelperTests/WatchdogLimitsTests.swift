import Foundation
import Testing

@testable import AeolusHelper

/// The watchdog's bounds (ADR 0012, "The constants"): derived where they can be, constant
/// everywhere, and unable to be lengthened by anything a client or a configuration can reach
/// (I8).
@Suite("The watchdog's bounds are derived, and constant")
struct WatchdogLimitsTests {

    /// This machine's critical read: the size of the curated set (34 on `Mac16,5`), one of the
    /// two terms of the allowance that differ per machine.
    static var criticalReadKeys: Int { CriticalSensorSet.mac16x5.keys.count }

    /// This machine's recorded fan count (2 on `Mac16,5`), the other.
    static var fans: Int { CriticalSensorSet.mac16x5.fanCount ?? 0 }

    /// The design point ADR 0012 sizes G at: supervisor-priority reads outstanding at once.
    /// Written here from the ADR and not read from the source, so that moving the point is a
    /// decision made in two places (and the amendment's prose, a third). D_cycle has no design
    /// point since the 2026-10-18 amendment: it does not depend on N.
    private static let design = 12

    /// The longest write turn but the engaged step at rest, written out: an engagement's first
    /// step on the force-key path — pre-state read, key info, mode write, the force key's key info
    /// and its write. Longer than a 3-key mode read. § 3's bridge job, a command (3) and a `.fan`
    /// restore (at most 2), is the same five.
    private static let writeTurn = 5

    /// The engaged step at rest (ADR 0014's P1′ amendment; ADR 0012's 2026-10-31 amendment),
    /// written out: key info, pre-state, the mode write, its read-back, the target's read and the
    /// key info that read takes when `F<n>Tg`'s is not cached, the target's fresh key info, the
    /// floor's write and its read-back. The longest turn any reader takes, and at most one per fan
    /// is queued.
    private static let engagedStep = 9

    /// `count` queued readers' turns, written out: at most one engaged step per fan, the rest at
    /// the longer of a mode read and `writeTurn`.
    private static func readerTurns(_ count: Int, fans: Int) -> Int {
        let engaged = min(count, fans)
        return engaged * engagedStep + (count - engaged) * max(3, writeTurn)
    }

    /// A `.fan(n)` restore, written out: its mode write and at most the force key's.
    private static let fanRestore = 2

    /// D_cycle's allowance with § 3's lane (ADR 0012's 2026-10-18 amendment), written out here
    /// from the named constants so that it is a second derivation of `allowanceRoundTrips` and
    /// not a copy of it: one turn in flight ahead of each of § 3's turns — its read, a bridge job
    /// per fan and `attemptBudget` refused restores per fan — then its own read, its bridge jobs
    /// and its restores.
    private static func expectedAllowance(keys: Int, fans: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let attempts = RestoreLimits.attemptBudget
        let turns = 1 + fans + fans * attempts
        return turns * turn + keys + fans * writeTurn + fans * attempts * fanRestore
    }

    /// D is set from a measurement, with margin: at least a hundred times the slowest round
    /// trip ever measured. The allowance is computed from the **named** scheduler and restore
    /// constants, the machine's own critical set and its own fan count — never from a literal.
    ///
    /// **Mutation:** write the allowance's `maxKeysPerTurn` term as `128` in
    /// `allowanceRoundTrips`. Run: red.
    /// **Mutation:** return `632` from `allowanceRoundTrips` (a literal allowance). Run: red — at
    /// every other set size and fan count.
    /// **Mutation:** count § 3's critical read as one round trip (`+ 1` for `+ criticalReadKeys`).
    /// Run: red.
    @Test("D is a hundred times the measurement, and the allowance is derived, not quoted")
    func theAllowanceIsDerivedFromTheNamedConstants() {
        #expect(WatchdogLimits.roundTrip >= WatchdogLimits.measuredWorstRoundTrip * 100)
        #expect(WatchdogLimits.measuredWorstRoundTrip == .microseconds(11_453))
        #expect(WatchdogLimits.writeTurnRoundTrips == Self.writeTurn)
        #expect(WatchdogLimits.fanRestoreRoundTrips == Self.fanRestore)
        #expect(WatchdogLimits.engagedStepRoundTrips == Self.engagedStep)
        #expect(WatchdogLimits.readerTurnRoundTrips == Self.engagedStep)
        #expect(WatchdogLimits.otherReaderTurnRoundTrips == Self.writeTurn)

        for fans in 0...4 {
            for keys in [0, 1, 6, Self.criticalReadKeys, SMCReadScheduler.maxKeysPerTurn] {
                #expect(
                    WatchdogLimits.allowanceRoundTrips(criticalReadKeys: keys, fans: fans)
                        == Self.expectedAllowance(keys: keys, fans: fans),
                    "\(keys) keys, \(fans) fans")
            }
        }
        // The figures the amendment quotes, so a change to a scheduler constant, the restore
        // budget, the critical set or the fan count fails here and forces the arithmetic to be
        // re-run, not just re-passed.
        #expect(Self.criticalReadKeys == 34, "ADR 0012 quotes the Mac16,5 critical read as 34")
        #expect(Self.fans == 2, "ADR 0012 quotes Mac16,5 as two fans")
        #expect(Self.expectedAllowance(keys: 34, fans: 2) == 632)
        #expect(Self.expectedAllowance(keys: 34, fans: 3) == 899)
    }

    /// D_cycle covers the interval, timer slop, D and the allowance of § 3's longest cycle — a
    /// firing cycle with every restore refused — whatever N is: 632 round trips on `Mac16,5`,
    /// 13.34 s, and 14.19 s with § 3's write turns at 50 ms a round trip. The negative controls
    /// are the bound's two limits: a third fan breaks it (16.40 s), and a curated set with no
    /// recorded fan count has no bound to check. D_bringUp is the reconciliation budget plus two
    /// round trips; the tick and the two-tick rule are what the ADR says.
    ///
    /// **Mutation:** set `cycleBound` to `2·D`. Run: red — Mac16,5 needs 13.34 s.
    /// **Mutation:** drop the revocation's attempts from `thermalCycleTurns(fans:)`
    /// (`1 + fans`). Run: red — 13.34 s becomes 10.28 s.
    /// **Mutation:** in `requiredCycleBound(for:)`, pass `fans: 1`. Run: red — Mac16,5's set
    /// reads as one fan, 10.28 s.
    @Test("D_cycle clears § 3's longest cycle with no N, and a third fan breaks it")
    func theBoundsAreDerivedAndConstant() throws {
        let roundTrip = WatchdogLimits.roundTrip
        let interval = ThermalSupervisor<SMCFanControlPlane>.defaultInterval
        let required = try #require(WatchdogLimits.requiredCycleBound(for: .mac16x5))
        #expect(
            required
                == interval + .milliseconds(100) + roundTrip
                + WatchdogLimits.measuredWorstRoundTrip
                * Self.expectedAllowance(keys: Self.criticalReadKeys, fans: Self.fans))
        #expect(required > .milliseconds(13_338) && required < .milliseconds(13_339))
        #expect(WatchdogLimits.cycleBound >= required)
        #expect(WatchdogLimits.cycleBound == roundTrip * 3)

        // § 3's write turns at 50 ms each: 14.19 s, still inside. The break-even is 86.98 ms.
        let atFifty = WatchdogLimits.requiredCycleBound(
            criticalReadKeys: Self.criticalReadKeys, fans: Self.fans,
            worstWriteRoundTrip: .milliseconds(50))
        #expect(atFifty > .milliseconds(14_186) && atFifty < .milliseconds(14_187))
        #expect(atFifty <= WatchdogLimits.cycleBound)
        let breakEven = { (write: Duration) in
            WatchdogLimits.requiredCycleBound(
                criticalReadKeys: Self.criticalReadKeys, fans: Self.fans,
                worstWriteRoundTrip: write)
        }
        #expect(breakEven(.microseconds(86_980)) <= WatchdogLimits.cycleBound)
        #expect(breakEven(.microseconds(86_990)) > WatchdogLimits.cycleBound)

        // The negative controls. A curated machine with a third fan would need 16.40 s, and a
        // set with no recorded fan count answers no bound at all.
        let threeFans = WatchdogLimits.requiredCycleBound(
            criticalReadKeys: Self.criticalReadKeys, fans: 3)
        #expect(threeFans > WatchdogLimits.cycleBound, "D_cycle holds at three fans")
        #expect(threeFans > .milliseconds(16_396) && threeFans < .milliseconds(16_397))
        #expect(WatchdogLimits.requiredCycleBound(for: .unidentifiedHardware) == nil)

        #expect(WatchdogLimits.bringUpBound == ReconciliationLimits.budget + roundTrip * 2)
        // D_bringUp re-checked against the write path's preparation step (ADR 0014 D7), which
        // runs before reconciliation: `FNum`, every fan's mode and target key info (b2 takes the
        // target's so the engaged step's logged read is one round trip), the force key's key info
        // and value, and its machine-wide restore — one write per mode key and one for the key —
        // for the most fans a key can address: 34. It fits with a whole round trip to spare.
        let fans = 10
        let preparation = 1 + 2 * fans + 2 + (fans + 1)
        #expect(preparation == 34)
        #expect(
            WatchdogLimits.bringUpBound
                >= ReconciliationLimits.budget + roundTrip
                + WatchdogLimits.measuredWorstRoundTrip * preparation)
        #expect(WatchdogLimits.tick == .seconds(1))
        #expect(WatchdogLimits.ticksPerVerdict == 2)
        #expect(
            WatchdogLimits.cycleBound > interval + WatchdogLimits.tick * 2,
            "a verdict could land before a healthy cycle could")

        // The values the ADR states, pinned: changing a bound is a decision recorded in ADR
        // 0012 and made in the same change as these lines.
        #expect(roundTrip == .seconds(5))
        #expect(WatchdogLimits.cycleBound == .seconds(15))
        #expect(WatchdogLimits.bringUpBound == .seconds(15))
    }

    // MARK: - G, the gate bound

    /// The supervisor queue ahead of the worst supervisor waiter with `reads` readers
    /// outstanding on `fans` fans, § 3's lane aside, written out from the named scheduler
    /// constants: the longer of a reader that arrived last — behind the turn in flight, the grant
    /// path's read, the other `reads - 3` readers' turns and the forced snapshot turns — and the
    /// grant path's read itself, behind the turn in flight, `reads - 2` readers' turns and the
    /// forced snapshot turns. At most one reader per fan is the engaged step at rest.
    private static func expectedQueue(_ reads: Int, keys: Int, fans: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let forced = turn * ((reads - 1) / SMCReadScheduler.maxConsecutiveOvertakes + 1)
        let reader = turn + keys + readerTurns(reads - 3, fans: fans) + forced
        let grantPath = turn + readerTurns(reads - 2, fans: fans) + forced
        return max(reader, grantPath)
    }

    /// The worst supervisor waiter's wait with § 3's lane in it, in the two **modelled cases**,
    /// written out: the queue, plus § 3's own turns in the longer of two windows — (a) one firing
    /// cycle's read, bridge jobs and refused restores, then a latched cycle's read per cycle; (b) a
    /// quiet cycle's read and a read-back of every fan per cycle — at one cycle per interval plus
    /// § 3's read. Solved by iteration from below, in microseconds. Mixed histories — a release and
    /// read-backs inside a firing's window, a latched cycle's take-back — are not these cases; ADR
    /// 0012's 2026-10-18 amendment counts them.
    private static func expectedGateWait(_ reads: Int, keys: Int, fans: Int) -> Int {
        let roundTrip = 11_453
        let period = 1_000_000 + roundTrip * keys
        func settle(_ base: Int, _ per: Int) -> Int {
            var wait = base
            while true {
                let next = base + (roundTrip * wait + period - 1) / period * per
                if next == wait { return wait }
                wait = next
            }
        }
        let queue = expectedQueue(reads, keys: keys, fans: fans)
        let attempts = RestoreLimits.attemptBudget
        let firing = keys + fans * writeTurn + fans * attempts * fanRestore
        return max(settle(queue + firing, keys), settle(queue, keys + fans * 3))
    }

    /// G is 2·D, and it has two sides. It must exceed the supervisor wait at the gate in the two
    /// modelled cases at the design point — a reader behind the grant path's read, the other
    /// readers, two of them engaged steps at rest, and § 3's lane turns, 829 round trips at the
    /// measured worst, 9.49 s on `Mac16,5` — or a full, moving queue would be logged as a fault;
    /// and it must stay under D_cycle less the supervisor's interval and two ticks, 12 s, or the
    /// cycle trigger would end the helper before the fault explained it. It holds to N = 12 and not
    /// to 13 (10.67 s), N counting § 3's read.
    ///
    /// **Modelled cases, not a bound over every history.** What this pins is the two windows'
    /// arithmetic. The histories § 3 really produces — a firing, its release and the read-backs
    /// after it in one window; a latched cycle taking fans back — are counted outside this suite
    /// by `scripts/gate-wait-model/engaged_step.py`: 795–839 round trips (9.11–9.61 s) with the
    /// firing head counted once, and at most 619 (7.09 s) in an event model of the shipped policy,
    /// both under G. Open, as in ADR 0012's 2026-10-18 and 2026-10-31 amendments: a take-back with
    /// writes recurring every cycle, 927 (10.62 s), and a refused revocation recurring every
    /// latched cycle, 867–877 (9.93–10.04 s), each over G at its upper end; the take-back's would
    /// also stretch ADR 0014's lawful hold past `examinationWait`. Counting every reader as an
    /// engaged step instead, four of the histories counted correctly pass G already at eight; that
    /// is why the long turn is once per fan.
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip` (G = D). Run: red.
    /// **Mutation:** set `gateWaiterAlarm` to `cycleBound`. Run: red — the cycle trigger would
    /// land before the fault.
    /// **Mutation:** omit the lane: return `queue` from `gateWaitRoundTrips`. Run: red — 535
    /// where it is 829, and G holds past 12.
    /// **Mutation:** omit the firing cycle from window (a): `laneWindow(base: queue, perCycle:
    /// criticalReadKeys, …)`. Run: red — 815 where it is 829.
    /// **Mutation:** in `WatchdogLimits.readerTurns`, count no engaged step (`let engaged = 0`).
    /// Run: red — 821 where it is 829.
    /// **Mutation:** set `engagedStepRoundTrips` to 8. Run: red — 827 where it is 829.
    @Test("G clears the design point's wait with the lane in it, to N = 12 and not 13")
    func theGateBoundIsDerivedAndConstant() {
        let gate = WatchdogLimits.gateWaiterAlarm
        let design = Self.design
        let keys = Self.criticalReadKeys
        let fans = Self.fans
        let required = WatchdogLimits.requiredGateBound(
            outstandingReads: design, criticalReadKeys: keys, fans: fans)

        #expect(gate == WatchdogLimits.roundTrip * 2)
        #expect(gate == .seconds(10), "ADR 0012 states G as 10 s")
        #expect(Self.expectedGateWait(design, keys: keys, fans: fans) == 829)
        let wait = WatchdogLimits.gateWaitRoundTrips(
            outstandingReads: design, criticalReadKeys: keys, fans: fans)
        #expect(wait == 829, "the design point's wait is \(wait) round trips")
        #expect(required > .milliseconds(9_494) && required < .milliseconds(9_495), "\(required)")
        #expect(gate > required, "a full, moving queue at the design point would fault")

        let atThirteen = WatchdogLimits.requiredGateBound(
            outstandingReads: design + 1, criticalReadKeys: keys, fans: fans)
        #expect(atThirteen >= gate, "G holds at N = 13: the \"to 12\" in the docs is stale")
        #expect(
            atThirteen > .milliseconds(10_674) && atThirteen < .milliseconds(10_675),
            "\(atThirteen)")

        let interval = ThermalSupervisor<SMCFanControlPlane>.defaultInterval
        #expect(
            gate < WatchdogLimits.cycleBound - interval - WatchdogLimits.tick * 2,
            "the cycle trigger could land before the fault that explains it")
    }

    /// The wait agrees with the independent derivation across outstanding reads, set sizes and
    /// fan counts, so neither queue waiter, neither lane window and neither kind of reader turn is
    /// quietly the only one counted.
    ///
    /// **Mutation:** return `lastReader` alone from `supervisorQueueRoundTrips`. Run: red at a set
    /// shorter than a reader's turn.
    /// **Mutation:** write `min` for `max` in `gateWaitRoundTrips`. Run: red.
    /// **Mutation:** in `WatchdogLimits.readerTurns`, take every reader at `engagedStepRoundTrips`.
    /// Run: red.
    @Test("The gate wait is the longer of the two waiters and the two lane windows")
    func theGateWaitIsTheLongerOfTheTwoWaiters() {
        #expect(Self.expectedQueue(Self.design, keys: 0, fans: 0) == 498)
        #expect(Self.expectedQueue(Self.design, keys: 0, fans: 2) == 506)
        for reads in 3...25 {
            for keys in [0, 1, 2, 3, 10, Self.criticalReadKeys, SMCReadScheduler.maxKeysPerTurn] {
                for fans in [0, 1, 2, 3] {
                    #expect(
                        WatchdogLimits.supervisorQueueRoundTrips(
                            outstandingReads: reads, criticalReadKeys: keys, fans: fans)
                            == Self.expectedQueue(reads, keys: keys, fans: fans),
                        "N = \(reads), \(keys) critical keys, \(fans) fans")
                }
                for fans in [0, 1, 2, 3] {
                    #expect(
                        WatchdogLimits.gateWaitRoundTrips(
                            outstandingReads: reads, criticalReadKeys: keys, fans: fans)
                            == Self.expectedGateWait(reads, keys: keys, fans: fans),
                        "N = \(reads), \(keys) critical keys, \(fans) fans")
                }
            }
        }
    }

    /// G holds for every curated set at the design point, and for up to 12 outstanding reads on
    /// `Mac16,5`. Past that the gate fault firing for a queue that is moving is the documented
    /// cost, and it ends nothing. **The snapshot priority's waiter is not derived** (see
    /// `WatchdogLimits.gateWaiterAlarm`).
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip` (G = D). Run: red.
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip * 2 + .seconds(1)`. Run: red — G holds
    /// at 13 and the documented reach is stale.
    @Test("G holds the design point for every curated set, and to 12 outstanding reads")
    func theGateBoundHoldsForEveryCuratedSet() throws {
        for set in CriticalSensorSet.allCurated {
            let fans = try #require(set.fanCount, "\(set.provenance) records no fan count")
            let required = WatchdogLimits.requiredGateBound(
                outstandingReads: Self.design, criticalReadKeys: set.keys.count, fans: fans)
            #expect(
                required < WatchdogLimits.gateWaiterAlarm,
                "\(set.provenance): the design point's wait is \(required)")
        }
        for reads in 0...12 {
            #expect(
                WatchdogLimits.requiredGateBound(
                    outstandingReads: reads, criticalReadKeys: Self.criticalReadKeys,
                    fans: Self.fans) < WatchdogLimits.gateWaiterAlarm,
                "G should hold for N = \(reads)")
        }
        #expect(
            WatchdogLimits.requiredGateBound(
                outstandingReads: 13, criticalReadKeys: Self.criticalReadKeys, fans: Self.fans)
                >= WatchdogLimits.gateWaiterAlarm,
            "G holds at N = 13: the \"to 12\" in the docs is stale")
    }

    /// G stands for one scheduler turn's whole slot, which is what the examination gate's
    /// `lawfulHold` counts its turns in (ADR 0014's A6 PR-2 amendment): at the design point, the
    /// longest legal supervisor wait plus the longest turn a reader takes — the engaged step at
    /// rest, nine round trips — at the measured worst round trip, stays under G for every curated
    /// set: on `Mac16,5`, 838 round trips, 9.60 s. The wait alone is the test above; the turn is
    /// this.
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `.milliseconds(9_500)`. Run: red here: the wait
    /// alone, 9.49 s, still clears it, and the slot, 9.60 s, does not.
    @Test("G covers a turn's slot, its wait and its longest write, for every curated set")
    func theGateBoundCoversAWholeTurn() throws {
        #expect(WatchdogLimits.readerTurnRoundTrips == Self.engagedStep)
        let longestWriteTurn =
            WatchdogLimits.measuredWorstRoundTrip * WatchdogLimits.readerTurnRoundTrips
        for set in CriticalSensorSet.allCurated {
            let fans = try #require(set.fanCount, "\(set.provenance) records no fan count")
            let slot =
                WatchdogLimits.requiredGateBound(
                    outstandingReads: Self.design, criticalReadKeys: set.keys.count, fans: fans)
                + longestWriteTurn
            #expect(
                slot < WatchdogLimits.gateWaiterAlarm,
                "\(set.provenance): a turn's slot at the design point is \(slot)")
        }
    }
}
