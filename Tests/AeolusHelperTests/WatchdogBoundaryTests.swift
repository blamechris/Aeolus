import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The watchdog's edges: exactly at a bound, which side a tie falls on, which trigger a verdict
/// names when two are over, and where a phase's clock starts.
///
/// The other suites sit comfortably either side of a bound (6 s against 5, 16 against 15),
/// which is correct and leaves every comparison free to be `>` or `>=` and every ordering free
/// to be reversed. These sit on the line. The timeline is exact, so "exactly D" is exactly D.
@Suite("The watchdog's bounds, at the edge", .timeLimit(.minutes(1)))
struct WatchdogBoundaryTests {

    // MARK: - A bound is a bound only past it

    /// A round trip that has been out for exactly D is not past D, and one nanosecond more is.
    ///
    /// **Mutation:** `>=` for `>` against `WatchdogLimits.roundTrip` in
    /// `LivenessWatchdog.suspects`. Run: red.
    @Test("A round trip is past D only after D")
    func aRoundTripAtExactlyDIsNotPastIt() {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: WatchdogLimits.roundTrip)
            rig.tickTwice()
            #expect(rig.log.faults.isEmpty, "exactly D is a verdict: \(rig.log.faults)")

            rig.timeline.advance(by: .nanoseconds(1))
            rig.tickTwice()
        }
        #expect(rig.log.faults.count == 1, "one nanosecond past D is not a verdict")
        #expect(rig.exitsNow == [.blind])
    }

    /// The same for D_cycle, measured from the supervisor starting.
    ///
    /// **Mutation:** `>=` for `>` against `WatchdogLimits.cycleBound`. Run: red.
    @Test("A stalled cycle is past D_cycle only after D_cycle")
    func aCycleAtExactlyDCycleIsNotPastIt() {
        let rig = WatchdogRig()
        rig.progress.beginCycling()

        rig.timeline.advance(by: WatchdogLimits.cycleBound)
        rig.tickTwice()
        #expect(rig.log.faults.isEmpty, "exactly D_cycle is a verdict: \(rig.log.faults)")

        rig.timeline.advance(by: .nanoseconds(1))
        rig.tickTwice()
        #expect(rig.log.faults.first?.contains("safety-cycle trigger") == true)
        #expect(rig.exitsNow == [.blind])
    }

    /// The same for D_bringUp, measured from arming.
    ///
    /// **Mutation:** `>=` for `>` against `WatchdogLimits.bringUpBound`. Run: red.
    @Test("A stalled bring-up is past D_bringUp only after D_bringUp")
    func aBringUpAtExactlyDBringUpIsNotPastIt() async {
        let rig = WatchdogRig()
        await rig.watchdog.arm()

        rig.timeline.advance(by: WatchdogLimits.bringUpBound)
        rig.tickTwice()
        #expect(rig.log.faults.isEmpty, "exactly D_bringUp is a verdict: \(rig.log.faults)")

        rig.timeline.advance(by: .nanoseconds(1))
        rig.tickTwice()
        #expect(rig.log.faults.first?.contains("bring-up trigger") == true)
        #expect(rig.exitsNow == [.blind])
    }

    // MARK: - Where a phase's clock starts

    /// Bring-up is measured from **arming**, not from when the progress object was made: a
    /// helper that was constructed ten seconds before it was armed still gets the whole of
    /// D_bringUp.
    ///
    /// **Mutation:** make `ThermalCycleProgress.beginBringUp()` keep the construction-time
    /// anchor. Run: red.
    @Test("The bring-up bound runs from arming")
    func beginBringUpTakesAFreshAnchor() async {
        let rig = WatchdogRig()
        rig.timeline.advance(by: .seconds(10))

        await rig.watchdog.arm()
        rig.timeline.advance(by: .seconds(6))
        rig.tickTwice()

        #expect(rig.log.faults.isEmpty, "the bound ran from construction: \(rig.log.faults)")
    }

    // MARK: - Which trigger a verdict names

    /// A round trip is the better diagnosis than a stalled bring-up or cycle, and a verdict
    /// names it when both are over bound: it says which call, with which key.
    ///
    /// **Mutation:** append the cycle / bring-up suspect ahead of the round trip in
    /// `LivenessWatchdog.suspects`. Run: red.
    @Test("A round trip outranks a stalled bring-up in the verdict")
    func aRoundTripOutranksAStalledBringUp() async {
        let rig = WatchdogRig()
        await rig.watchdog.arm()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(16))
            rig.tickTwice()
        }

        let line = rig.log.faults.first ?? ""
        #expect(rig.log.faults.count == 1)
        #expect(line.contains("an SMC round trip has not returned"), "\(line)")
        #expect(!line.contains("bring-up trigger"), "\(line)")
    }

    /// The same against a stalled cycle.
    ///
    /// **Mutation:** the same. Run: red.
    @Test("A round trip outranks a stalled cycle in the verdict")
    func aRoundTripOutranksAStalledCycle() {
        let rig = WatchdogRig()
        rig.progress.beginCycling()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(16))
            rig.tickTwice()
        }

        let line = rig.log.faults.first ?? ""
        #expect(line.contains("an SMC round trip has not returned"), "\(line)")
        #expect(!line.contains("safety-cycle trigger"), "\(line)")
    }
}
