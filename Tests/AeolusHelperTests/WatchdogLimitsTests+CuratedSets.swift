import Foundation
import Testing

@testable import AeolusHelper

// Every curated set against the bounds, in a file of its own so `WatchdogLimitsTests.swift` stays
// inside `file_length` now that G counts the engaged step at rest.
extension WatchdogLimitsTests {

    // MARK: - Every curated set

    /// Every curated set fits in one scheduler turn. The allowance counts § 3's own read as **one
    /// lane turn** and G the grant path's as one supervisor turn — a set longer than
    /// `maxKeysPerTurn` would be several. § 3's would then yield back into its own lane and run
    /// its slices back to back while others wait (`SMCReadSchedulerLaneTests`), so the lane's
    /// one-turn-in-flight bound would hold per request and not per turn, and D_cycle would be
    /// tight by an amount no other test of the bounds would show.
    ///
    /// **Mutation:** widen `CriticalSensorSet.mac16x5`'s die-cluster prefixes to `TPD`, `TRD`,
    /// `TPE` and `TRE`, 68 keys. Run: red.
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

    /// D_cycle is checked against **every** curated set, not only the one the suite's other
    /// tests were written around: the allowance has a term per critical key and terms per fan, so
    /// a family whose set is larger, or whose machine has more fans, moves the bound under the
    /// watchdog without touching it. A curated set with no recorded fan count fails here.
    ///
    /// **Mutation:** lengthen a curated set past what 3·D covers. Run: red.
    /// **Mutation:** set `cycleBound` to `2·D`. Run: red.
    /// **Mutation:** record `mac16x5`'s fan count as `nil`. Run: red.
    @Test("D_cycle holds for every curated critical set, from its own fan count")
    func theCycleBoundHoldsForEveryCuratedSet() throws {
        for set in CriticalSensorSet.allCurated {
            let required = try #require(
                WatchdogLimits.requiredCycleBound(for: set),
                "\(set.provenance) records no fan count, so no bound is checked for it")
            #expect(
                required <= WatchdogLimits.cycleBound,
                """
                \(set.provenance): § 3's longest cycle needs \(required), \
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
        let none = WatchdogLimits.allowanceRoundTrips(criticalReadKeys: 0, fans: Self.fans)
        let mac = WatchdogLimits.allowanceRoundTrips(
            criticalReadKeys: Self.criticalReadKeys, fans: Self.fans)
        #expect(mac - none == Self.criticalReadKeys, "§ 3's own read, and nothing else")
        #expect(CriticalSensorSet.unidentifiedHardware.keys.isEmpty)
        #expect(CriticalSensorSet.unidentifiedHardware.fanCount == nil)
    }
}
