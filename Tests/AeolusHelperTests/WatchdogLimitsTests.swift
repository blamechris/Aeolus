import Foundation
import Testing

@testable import AeolusHelper

/// The watchdog's bounds (ADR 0012, "The constants"): derived where they can be, constant
/// everywhere, and unable to be lengthened by anything a client or a configuration can reach
/// (I8).
@Suite("The watchdog's bounds are derived, and constant")
struct WatchdogLimitsTests {

    /// This machine's critical read: the size of the curated set (34 on `Mac16,5`), the one
    /// term of the allowance that differs per machine.
    private static var criticalReadKeys: Int { CriticalSensorSet.mac16x5.keys.count }

    /// The design point ADR 0012 sizes D_cycle at: supervisor-priority reads outstanding at
    /// once. Written here from the ADR and not read from the source, so that moving the point
    /// is a decision made in two places (and the amendment's prose, a third).
    private static let design = 12

    /// The longest turn an outstanding supervisor reader takes since ADR 0014 D7, written out:
    /// an engagement's first step on the force-key path — pre-state read, key info, mode write,
    /// the force key's key info and its write. Longer than a 3-key mode read.
    private static let readerTurn = 5

    /// The allowance, written out here from the named constants so that it is a second
    /// derivation of `allowanceRoundTrips` and not a copy of it.
    private static func expectedAllowance(_ reads: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let overtakes = SMCReadScheduler.maxConsecutiveOvertakes
        let critical = criticalReadKeys
        return turn + critical + readerTurn * (reads - 2) + turn * ((reads - 1) / overtakes + 1)
            + critical + 30
    }

    /// D is set from a measurement, with margin: at least a hundred times the slowest round
    /// trip ever measured. The allowance is computed from the **named** scheduler constants
    /// and the machine's own critical set — never from a literal.
    ///
    /// **Mutation:** write the allowance's `maxKeysPerTurn` term as `128` in
    /// `allowanceRoundTrips`. Run: red.
    @Test("D is a hundred times the measurement, and the allowance is derived, not quoted")
    func theAllowanceIsDerivedFromTheNamedConstants() {
        #expect(WatchdogLimits.roundTrip >= WatchdogLimits.measuredWorstRoundTrip * 100)
        #expect(WatchdogLimits.measuredWorstRoundTrip == .microseconds(11_453))

        for reads in 2...20 {
            #expect(
                WatchdogLimits.allowanceRoundTrips(
                    outstandingReads: reads, criticalReadKeys: Self.criticalReadKeys)
                    == Self.expectedAllowance(reads),
                "N = \(reads)")
        }
        // The figures the amendment quotes, so a change to a scheduler constant or to the
        // critical set fails here and forces the arithmetic to be re-run, not just re-passed.
        // Re-run for ADR 0014 D7's write turns: 576, 716 and 783 while every other reader was a
        // 3-key mode read.
        #expect(Self.criticalReadKeys == 34, "ADR 0012 quotes the Mac16,5 critical read as 34")
        #expect(WatchdogLimits.readerTurnRoundTrips == Self.readerTurn)
        #expect(Self.expectedAllowance(12) == 596)
        #expect(Self.expectedAllowance(16) == 744)
        #expect(Self.expectedAllowance(17) == 813)
    }

    /// D_cycle covers the interval, timer slop, D and the allowance at the design point of
    /// twelve outstanding supervisor reads. It holds up to sixteen and fails at seventeen;
    /// D_bringUp is the reconciliation budget plus two round trips; the tick and the two-tick
    /// rule are what the ADR says.
    ///
    /// **Mutation:** set `cycleBound` to `2·D`. Run: red — the design point needs 12.7 s.
    @Test("D_cycle clears the design point, holds to sixteen and fails at seventeen")
    func theBoundsAreDerivedAndConstant() {
        let roundTrip = WatchdogLimits.roundTrip
        let interval = ThermalSupervisor<SMCFanControlPlane>.defaultInterval
        let required = WatchdogLimits.requiredCycleBound(
            outstandingReads: Self.design, criticalReadKeys: Self.criticalReadKeys)
        #expect(
            WatchdogLimits.cycleBound
                >= interval + .milliseconds(100) + roundTrip
                + WatchdogLimits.measuredWorstRoundTrip * Self.expectedAllowance(Self.design))
        #expect(WatchdogLimits.cycleBound >= required)
        #expect(WatchdogLimits.cycleBound == roundTrip * 3)

        // Above the design point the cycle trigger firing is the correct outcome, and this is
        // where that starts.
        for reads in 0...16 {
            #expect(
                WatchdogLimits.requiredCycleBound(
                    outstandingReads: reads, criticalReadKeys: Self.criticalReadKeys)
                    <= WatchdogLimits.cycleBound,
                "D_cycle should hold for N = \(reads)")
        }
        #expect(
            WatchdogLimits.requiredCycleBound(
                outstandingReads: 17, criticalReadKeys: Self.criticalReadKeys)
                > WatchdogLimits.cycleBound,
            "D_cycle holds at N = 17: the amendment's \"N <= 16\" is stale")

        #expect(WatchdogLimits.bringUpBound == ReconciliationLimits.budget + roundTrip * 2)
        // D_bringUp re-checked against the write path's preparation step (ADR 0014 D7), which
        // runs before reconciliation: `FNum`, every mode key's key info, the force key's key info
        // and value, and its machine-wide restore — one write per mode key and one for the key —
        // for the most fans a key can address. It fits with a whole round trip to spare.
        let fans = 10
        let preparation = 1 + fans + 2 + (fans + 1)
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

    /// The longest legal **supervisor** wait at the gate with `reads` readers outstanding, written
    /// out here from the named scheduler constants and not read from the source: the longer of
    ///
    /// - a reader that arrived last, behind the turn in flight, **both** critical reads (the
    ///   grant path's and § 3's), the other `reads - 3` readers' turns and the snapshot turns the
    ///   overtake quota forces; and
    /// - § 3's own read, behind everything but its own keys: the turn in flight, the grant
    ///   path's read, `reads - 2` readers' turns and the forced snapshot turns.
    ///
    /// A firing cycle's writes follow § 3's read and are ahead of nobody.
    private static func expectedWorstGateWait(_ reads: Int, keys: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let forced = turn * ((reads - 1) / SMCReadScheduler.maxConsecutiveOvertakes + 1)
        let reader = turn + keys + keys + readerTurn * (reads - 3) + forced
        let sectionThree = turn + keys + readerTurn * (reads - 2) + forced
        return max(reader, sectionThree)
    }

    /// G is 2·D, and it has two sides. It must exceed the longest legal supervisor wait at the
    /// gate at the design point — a reader behind both critical reads, 561 round trips at the
    /// measured worst, 6.43 s (543 and 6.22 s before ADR 0014's write turns) — or a full,
    /// moving queue would be logged as a fault; and it
    /// must stay under D_cycle less the supervisor's interval and two ticks, 12 s, or the cycle
    /// trigger would end the helper before the fault explained it. The first draft set G = D,
    /// under the first side; the second counted § 3's own read as the worst waiter, 512 round
    /// trips and 5.86 s, which is 31 short on `Mac16,5`.
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip` (G = D). Run: red — 5 s is under the
    /// 6.43 s the design point needs.
    /// **Mutation:** set `gateWaiterAlarm` to `cycleBound`. Run: red — the cycle trigger would
    /// land before the fault.
    /// **Mutation:** write `gateWaitRoundTrips` as the allowance less `criticalReadKeys` and
    /// `firingCycleRoundTrips` (§ 3's read as the worst waiter). Run: red — 532 where it is 561.
    @Test("G clears the design point's wait and stays inside D_cycle's margin")
    func theGateBoundIsDerivedAndConstant() {
        let gate = WatchdogLimits.gateWaiterAlarm
        let design = Self.design
        let keys = Self.criticalReadKeys
        let required = WatchdogLimits.requiredGateBound(
            outstandingReads: design, criticalReadKeys: keys)

        #expect(gate == WatchdogLimits.roundTrip * 2)
        #expect(gate == .seconds(10), "ADR 0012 states G as 10 s")
        #expect(Self.expectedWorstGateWait(design, keys: keys) == 561)
        #expect(
            WatchdogLimits.gateWaitRoundTrips(outstandingReads: design, criticalReadKeys: keys)
                == 561)
        #expect(required > .milliseconds(6_425) && required < .milliseconds(6_426))
        #expect(gate > required, "a full, moving queue at the design point would fault")

        let interval = ThermalSupervisor<SMCFanControlPlane>.defaultInterval
        #expect(
            gate < WatchdogLimits.cycleBound - interval - WatchdogLimits.tick * 2,
            "the cycle trigger could land before the fault that explains it")
    }

    /// The wait is the longer of the two waiters, per machine: with a critical set shorter than a
    /// mode read it is § 3's read, which on a machine with no curated set is the allowance less the
    /// writes alone. It agrees with the independent derivation across outstanding reads and set
    /// sizes, so neither waiter is quietly the only one counted.
    ///
    /// **Mutation:** take only the reader's turn off the allowance (`- readerTurnRoundTrips`, no
    /// `min`). Run: red — 493 where a machine with no curated set waits 498.
    /// **Mutation:** write `max` for `min` in `gateWaitRoundTrips`. Run: red.
    @Test("The gate wait is the longer of the two waiters, for every set size")
    func theGateWaitIsTheLongerOfTheTwoWaiters() {
        #expect(Self.expectedWorstGateWait(Self.design, keys: 0) == 498)
        for reads in 3...25 {
            for keys in [0, 1, 2, 3, 10, Self.criticalReadKeys, SMCReadScheduler.maxKeysPerTurn] {
                #expect(
                    WatchdogLimits.gateWaitRoundTrips(
                        outstandingReads: reads, criticalReadKeys: keys)
                        == Self.expectedWorstGateWait(reads, keys: keys),
                    "N = \(reads), \(keys) critical keys")
            }
        }
    }

    /// G holds for every curated set at the design point, and for up to 20 outstanding reads on
    /// `Mac16,5` (at 21 the worst supervisor wait is 10.61 s). Past that the gate fault firing is
    /// the correct outcome, the same as D_cycle past sixteen. **The snapshot priority's waiter is
    /// not derived** (see `WatchdogLimits.gateWaiterAlarm`).
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip` (G = D). Run: red.
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip * 2 + .seconds(1)`. Run: red — G holds at
    /// 21 and the documented reach is stale.
    @Test("G holds the design point for every curated set, and to 20 outstanding reads")
    func theGateBoundHoldsForEveryCuratedSet() {
        for set in CriticalSensorSet.allCurated {
            let required = WatchdogLimits.requiredGateBound(
                outstandingReads: Self.design, criticalReadKeys: set.keys.count)
            #expect(
                required < WatchdogLimits.gateWaiterAlarm,
                "\(set.provenance): the design point's wait is \(required)")
        }
        for reads in 0...20 {
            #expect(
                WatchdogLimits.requiredGateBound(
                    outstandingReads: reads, criticalReadKeys: Self.criticalReadKeys)
                    < WatchdogLimits.gateWaiterAlarm,
                "G should hold for N = \(reads)")
        }
        let atTwentyOne = WatchdogLimits.requiredGateBound(
            outstandingReads: 21, criticalReadKeys: Self.criticalReadKeys)
        #expect(
            atTwentyOne >= WatchdogLimits.gateWaiterAlarm,
            "G holds at N = 21: the \"to 20\" in the docs is stale")
        #expect(atTwentyOne > .milliseconds(10_605) && atTwentyOne < .milliseconds(10_606))
    }

    /// G stands for one scheduler turn's whole slot, which is what the examination gate's
    /// `lawfulHold` counts its turns in (ADR 0014's A6 PR-2 amendment): at the design point, the
    /// longest legal supervisor wait plus the longest write turn, at the measured worst round trip,
    /// stays under G for every curated set. The wait alone is the test above; the turn is this.
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `.milliseconds(6_450)`. Run: red here: the wait
    /// alone, 6.43 s, still clears it, and the slot, 6.48 s, does not.
    @Test("G covers a turn's slot, its wait and its longest write, for every curated set")
    func theGateBoundCoversAWholeTurn() {
        let longestWriteTurn =
            WatchdogLimits.measuredWorstRoundTrip * WatchdogLimits.writeTurnRoundTrips
        for set in CriticalSensorSet.allCurated {
            let slot =
                WatchdogLimits.requiredGateBound(
                    outstandingReads: Self.design, criticalReadKeys: set.keys.count)
                + longestWriteTurn
            #expect(
                slot < WatchdogLimits.gateWaiterAlarm,
                "\(set.provenance): a turn's slot at the design point is \(slot)")
        }
    }

    // MARK: - Every curated set

    /// Every curated set fits in one scheduler turn. The allowance counts the grant path's
    /// critical read and § 3's own as **one turn each** — a set longer than `maxKeysPerTurn`
    /// would be several, the derivation would understate the queue a cycle waits behind, and
    /// D_cycle would be tight by an amount no test above would show.
    ///
    /// **Mutation:** add a 65th key to `CriticalSensorSet.mac16x5`. Run: red.
    /// **Mutation:** write `CriticalSensorSet.allCurated` as an empty array. Run: red.
    @Test("Every curated critical set is at most one scheduler turn")
    func everyCuratedSetFitsOneTurn() {
        #expect(!CriticalSensorSet.allCurated.isEmpty)
        for set in CriticalSensorSet.allCurated {
            #expect(
                set.keys.count <= SMCReadScheduler.maxKeysPerTurn,
                "\(set.provenance): \(set.keys.count) keys is more than one turn")
        }
    }

    /// D_cycle is checked against **every** curated set, not only the one this file's other
    /// tests were written around: the allowance has a term per critical key, so a family whose
    /// set is larger moves the bound under the watchdog without touching it.
    ///
    /// **Mutation:** lengthen a curated set past what 3·D covers at the design point. Run: red.
    /// **Mutation:** set `cycleBound` to `2·D`. Run: red.
    @Test("D_cycle holds the design point for every curated critical set")
    func theCycleBoundHoldsForEveryCuratedSet() {
        for set in CriticalSensorSet.allCurated {
            let required = WatchdogLimits.requiredCycleBound(
                outstandingReads: Self.design, criticalReadKeys: set.keys.count)
            #expect(
                required <= WatchdogLimits.cycleBound,
                """
                \(set.provenance): the design point needs \(required), \
                D_cycle is \(WatchdogLimits.cycleBound)
                """)
        }
    }

    /// A machine with no curated critical set reads none of them: its allowance is the smaller
    /// one, not a crash and not the Mac16,5 figure.
    ///
    /// **Mutation:** use `34` where `criticalReadKeys` is. Run: red.
    @Test("The critical read is the machine's own, not a constant")
    func theCriticalReadIsPerMachine() {
        let none = WatchdogLimits.allowanceRoundTrips(
            outstandingReads: Self.design, criticalReadKeys: 0)
        let mac = WatchdogLimits.allowanceRoundTrips(
            outstandingReads: Self.design, criticalReadKeys: Self.criticalReadKeys)
        #expect(mac - none == 2 * Self.criticalReadKeys, "the grant path's read and § 3's own")
        #expect(CriticalSensorSet.unidentifiedHardware.keys.isEmpty)
    }
}
