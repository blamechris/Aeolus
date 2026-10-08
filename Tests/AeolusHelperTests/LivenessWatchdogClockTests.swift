import Foundation
import Testing

@testable import AeolusHelper

/// Which clock the progress and bring-up triggers age on (ADR 0012, "Which clock the progress
/// and bring-up triggers age on"), and that the clock the daemon is built with actually moves.
///
/// Every other test of the progress triggers injects a `WatchdogTimeline`, which is how they stay
/// free of wall-clock bounds and also why none of them runs the default. These are the ones that
/// do not.
@Suite("The progress triggers' clock", .timeLimit(.minutes(1)))
struct LivenessWatchdogClockTests {

    /// The progress triggers age on the suspending clock — a property of one `typealias`,
    /// asserted as a property of the type. The composition's `MonotonicClock` is
    /// `ContinuousClock`, which keeps counting through a sleep, and on it the first two ticks
    /// after an hour-long lid close would both see an hour since the last cycle.
    ///
    /// **Mutation:** `typealias MeasuringClock = ContinuousClock` in `ThermalCycleProgress`.
    /// Run: red.
    @Test("The progress triggers read the suspending clock")
    func theProgressTriggerReadsTheSuspendingClock() {
        #expect(
            ThermalCycleProgress.Instant.self == SuspendingClock.Instant.self,
            "ADR 0012: a cycle in flight across a sleep must not age")
        #expect(ThermalCycleProgress.MeasuringClock.self == SuspendingClock.self)
    }

    /// The clock the **shipping** progress object is built with actually moves.
    ///
    /// Every other test that reads an age injects a `WatchdogTimeline`, so none of them runs the
    /// default. A default that was an instant captured once —
    /// `now: = { [t = MeasuringClock.now] in t }` — still has the right type, still compiles,
    /// and reads an age of zero for ever: D_cycle and D_bringUp could never fire in the daemon,
    /// and the round-trip trigger alone would be left watching. Only a lower bound is asserted:
    /// it waits, by sleeping, until the age is not zero, and says nothing of how soon.
    ///
    /// **Mutation:** default the `now:` parameter of `ThermalCycleProgress.init` to an instant
    /// captured once. Run: red.
    @Test("The shipping progress object's clock ages")
    func theDefaultClockAges() async {
        let progress = ThermalCycleProgress()
        progress.beginCycling()

        let aged = await pollUntil { progress.reading().sinceLastCompletion > .zero }

        #expect(aged, "the default clock never moved: D_cycle and D_bringUp could never fire")
    }

    /// The age is read from the progress object's own clock when it is asked for, from the
    /// moment of the last completion: the comparer mints the instant, so a caller cannot hand
    /// it one that makes the comparison a no-op.
    ///
    /// **Mutation:** take the age against the anchor's own instant (a stored "now").
    /// Run: red.
    @Test("The age is minted when it is read, from the last completion")
    func theAgeIsMintedWhenRead() {
        let rig = WatchdogRig()
        rig.progress.beginCycling()
        rig.timeline.advance(by: .seconds(4))
        rig.progress.recordCompletion()
        rig.timeline.advance(by: .seconds(3))

        let reading = rig.progress.reading()
        #expect(reading.sinceLastCompletion == .seconds(3))
        #expect(reading.completions == 1)
        #expect(reading.phase == .cycling)

        rig.timeline.advance(by: .seconds(2))
        #expect(rig.progress.reading().sinceLastCompletion == .seconds(5))
    }
}
