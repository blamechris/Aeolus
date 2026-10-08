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

    /// The allowance, written out here from the named constants so that it is a second
    /// derivation of `allowanceRoundTrips` and not a copy of it.
    private static func expectedAllowance(_ reads: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let overtakes = SMCReadScheduler.maxConsecutiveOvertakes
        let critical = criticalReadKeys
        return turn + critical + 3 * (reads - 2) + turn * ((reads - 1) / overtakes + 1) + critical
            + 30
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
        #expect(Self.criticalReadKeys == 34, "ADR 0012 quotes the Mac16,5 critical read as 34")
        #expect(Self.expectedAllowance(12) == 576)
        #expect(Self.expectedAllowance(16) == 716)
        #expect(Self.expectedAllowance(17) == 783)
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
    /// - a 3-key mode read that arrived last, behind the turn in flight, **both** critical reads
    ///   (the grant path's and § 3's), the other `reads - 3` mode reads and the snapshot turns the
    ///   overtake quota forces; and
    /// - § 3's own read, behind everything but its own keys: the turn in flight, the grant
    ///   path's read, `reads - 2` mode reads and the forced snapshot turns.
    ///
    /// A firing cycle's writes follow § 3's read and are ahead of nobody.
    private static func expectedWorstGateWait(_ reads: Int, keys: Int) -> Int {
        let turn = SMCReadScheduler.maxKeysPerTurn
        let forced = turn * ((reads - 1) / SMCReadScheduler.maxConsecutiveOvertakes + 1)
        let modeRead = turn + keys + keys + 3 * (reads - 3) + forced
        let sectionThree = turn + keys + 3 * (reads - 2) + forced
        return max(modeRead, sectionThree)
    }

    /// G is 2·D, and it has two sides. It must exceed the longest legal supervisor wait at the
    /// gate at the design point — a 3-key mode read behind both critical reads, 543 round trips at
    /// the measured worst, 6.22 s — or a full, moving queue would be logged as a fault; and it
    /// must stay under D_cycle less the supervisor's interval and two ticks, 12 s, or the cycle
    /// trigger would end the helper before the fault explained it. The first draft set G = D,
    /// under the first side; the second counted § 3's own read as the worst waiter, 512 round
    /// trips and 5.86 s, which is 31 short on `Mac16,5`.
    ///
    /// **Mutation:** set `gateWaiterAlarm` to `roundTrip` (G = D). Run: red — 5 s is under the
    /// 6.22 s the design point needs.
    /// **Mutation:** set `gateWaiterAlarm` to `cycleBound`. Run: red — the cycle trigger would
    /// land before the fault.
    /// **Mutation:** write `gateWaitRoundTrips` as the allowance less `criticalReadKeys` and
    /// `firingCycleRoundTrips` (§ 3's read as the worst waiter). Run: red — 512 where it is 543.
    @Test("G clears the design point's wait and stays inside D_cycle's margin")
    func theGateBoundIsDerivedAndConstant() {
        let gate = WatchdogLimits.gateWaiterAlarm
        let design = Self.design
        let keys = Self.criticalReadKeys
        let required = WatchdogLimits.requiredGateBound(
            outstandingReads: design, criticalReadKeys: keys)

        #expect(gate == WatchdogLimits.roundTrip * 2)
        #expect(gate == .seconds(10), "ADR 0012 states G as 10 s")
        #expect(Self.expectedWorstGateWait(design, keys: keys) == 543)
        #expect(
            WatchdogLimits.gateWaitRoundTrips(outstandingReads: design, criticalReadKeys: keys)
                == 543)
        #expect(required > .milliseconds(6_218) && required < .milliseconds(6_220))
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
    /// **Mutation:** take only the mode read off the allowance (`- modeReadKeys`, no `min`). Run:
    /// red — 475 where a machine with no curated set waits 478.
    /// **Mutation:** write `max` for `min` in `gateWaitRoundTrips`. Run: red.
    @Test("The gate wait is the longer of the two waiters, for every set size")
    func theGateWaitIsTheLongerOfTheTwoWaiters() {
        #expect(Self.expectedWorstGateWait(Self.design, keys: 0) == 478)
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
    /// `Mac16,5` (at 21 the worst supervisor wait is 10.19 s). Past that the gate fault firing is
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
        #expect(atTwentyOne > .milliseconds(10_190) && atTwentyOne < .milliseconds(10_195))
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
