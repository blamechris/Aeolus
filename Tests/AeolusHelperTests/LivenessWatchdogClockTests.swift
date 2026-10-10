import Foundation
import Testing
import os

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

    /// "Now" is read **inside** the lock that stores it, so a late completion cannot leave the
    /// anchor earlier than a phase change that happened after it began.
    ///
    /// The ordinary shape of a stop is that the outgoing loop's last completion arrives while
    /// the replacement is starting. If that completion read the clock *before* it took the lock,
    /// it could read t1, lose the lock to `beginCycling()` (t2 > t1), and then store t1 last:
    /// an anchor from before the phase it claims to belong to, and an age that includes time the
    /// phase never had. Here the completion is parked inside the clock read with the phase
    /// change starting behind it, and the order of the instants is scripted, so the answer does
    /// not depend on a race going one way.
    ///
    /// The wait for the phase change to have had its chance is a floor on how long the absence
    /// of a result was observed. It is never a bound on how long anything takes: a correct
    /// object cannot fail on a slow machine, only a mutant can survive one.
    ///
    /// **Mutation:** read `now()` before `state.withLock` in `recordCompletion()`. Run: red —
    /// the age is two seconds, not one.
    @Test("A late completion cannot move the anchor behind a phase change")
    func aLateCompletionCannotPassAPhaseChange() async {
        let clock = ScriptedProgressClock()
        let progress = clock.makeProgress()
        let finished = OSAllocatedUnfairLock(initialState: 0)
        let phaseChangeStarted = OSAllocatedUnfairLock(initialState: false)

        Thread {
            progress.recordCompletion()
            finished.withLock { $0 += 1 }
        }.start()
        guard await pollUntil({ clock.isParked }) else {
            clock.release()
            Issue.record("the completion never reached the clock")
            return
        }
        Thread {
            phaseChangeStarted.withLock { $0 = true }
            progress.beginCycling()
            finished.withLock { $0 += 1 }
        }.start()
        _ = await pollUntil { phaseChangeStarted.withLock { $0 } }
        await settle()
        clock.release()
        let both = await pollUntil { finished.withLock { $0 } == 2 }

        let reading = progress.reading()
        #expect(both, "the completion and the phase change did not both finish")
        #expect(reading.phase == .cycling)
        #expect(
            reading.sinceLastCompletion == .seconds(1),
            """
            the anchor is \(reading.sinceLastCompletion) behind the reading; a phase change at \
            two seconds and a reading at three leave one. A completion that read its instant \
            before taking the lock stored an earlier one over the phase change's.
            """)
    }
}

/// A clock for a `ThermalCycleProgress` whose instants are scripted by the order of the calls:
/// the initialiser reads t+0, the second call (a late completion) parks inside the clock until
/// released and then reads t+1, the third (the phase change behind it) reads t+2, and every
/// later one (the reading) t+3.
private final class ScriptedProgressClock: Sendable {
    private let base = ThermalCycleProgress.MeasuringClock.now
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let parked = OSAllocatedUnfairLock(initialState: false)
    private let proceed = DispatchSemaphore(value: 0)

    /// Whether a caller is parked inside the clock read.
    var isParked: Bool { parked.withLock { $0 } }

    /// Lets the parked caller's read return. The wait is bounded, so a test that never gets here
    /// frees the thread anyway.
    func release() { proceed.signal() }

    func makeProgress() -> ThermalCycleProgress {
        ThermalCycleProgress(now: { [self] in instant(forCall: nextCall()) })
    }

    private func nextCall() -> Int {
        calls.withLock {
            $0 += 1
            return $0
        }
    }

    private func instant(forCall call: Int) -> ThermalCycleProgress.Instant {
        switch call {
        case 1:
            return base
        case 2:
            parked.withLock { $0 = true }
            _ = proceed.wait(timeout: .now() + .seconds(30))
            return base.advanced(by: .seconds(1))
        case 3:
            return base.advanced(by: .seconds(2))
        default:
            return base.advanced(by: .seconds(3))
        }
    }
}
