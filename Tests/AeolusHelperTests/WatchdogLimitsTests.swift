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

    private static let design = WatchdogLimits.designPointOutstandingReads

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
