import Foundation
import Testing
import os

@testable import AeolusHelper

/// The daemon's tick source, run for real: a `.strict` `DispatchSourceTimer` on a queue of its
/// own (ADR 0012 I2).
///
/// Everything else in the watchdog's suites drives ticks by hand, which leaves the timer wiring
/// itself — scheduled, resumed, repeating, retained — examined by nothing. A source nobody
/// resumes never fires, and a source nobody holds is cancelled by ARC; both leave a watchdog
/// that looks armed and never looks. The timer has no side effect a test could trip over, so
/// unlike the signal sources it is exercised here for real.
///
/// There is no bound on how *fast* it ticks: the test waits, with a failsafe, for two ticks to
/// arrive and asserts what they were and where they ran.
@Suite("The daemon's tick source", .serialized, .timeLimit(.minutes(1)))
struct DispatchWatchdogTicksTests {

    private struct Observed: Sendable {
        var ticks = 0
        var queueLabels: Set<String> = []
        var onMainThread = false
    }

    /// Starts a real tick source and returns what its first handler saw once `count` ticks have
    /// arrived, or whatever it had seen when the failsafe ran out.
    private func observe(ticks count: Int, startingTwice: Bool = false) async -> Observed {
        let seen = OSAllocatedUnfairLock(initialState: Observed())
        let source = DispatchWatchdogTicks()
        await source.start {
            let label = String(cString: __dispatch_queue_get_label(nil))
            seen.withLock {
                $0.ticks += 1
                $0.queueLabels.insert(label)
                if Thread.isMainThread { $0.onMainThread = true }
            }
        }
        if startingTwice {
            // The second handler must be ignored: one timer, the first handler.
            await source.start { seen.withLock { $0.ticks += 1_000 } }
        }
        _ = await pollUntil { seen.withLock { $0.ticks >= count } }
        return seen.withLock { $0 }
    }

    /// **Mutation:** delete `source.resume()` from `DispatchWatchdogTicks.start`. Run: red —
    /// a source that was never resumed never fires. **Mutation:** do not store the source in
    /// `timer`. Run: red — ARC cancels it when `start` returns.
    @Test("The timer ticks repeatedly, on a queue of its own")
    func theTimerTicksOnItsOwnQueue() async {
        let observed = await observe(ticks: 2)

        #expect(observed.ticks >= 2, "the timer delivered \(observed.ticks) ticks")
        #expect(
            observed.queueLabels == ["dev.aeolus.AeolusHelper.watchdog"],
            "the tick ran on \(observed.queueLabels), not on the watchdog's own queue")
        #expect(!observed.onMainThread)
    }

    /// A second `start` keeps the first handler and starts no second timer.
    ///
    /// **Mutation:** delete the `guard timer == nil` in `DispatchWatchdogTicks.start`. Run:
    /// red — the second handler's thousand ticks are counted.
    @Test("Starting twice keeps one timer and the first handler")
    func startingTwiceKeepsTheFirstHandler() async {
        let observed = await observe(ticks: 2, startingTwice: true)

        #expect(observed.ticks >= 2)
        #expect(observed.ticks < 1_000, "a second timer's handler ran")
    }

    /// The period is what the ADR says and the leeway is the slop D_cycle allows for, converted
    /// to the dispatch timer's units without losing the fraction.
    ///
    /// **Mutation:** convert the attoseconds with the wrong divisor in `dispatchInterval`.
    /// Run: red.
    @Test("The timer's period and leeway are the watchdog's constants")
    func theTimerIsGivenTheWatchdogsConstants() {
        #expect(WatchdogLimits.tickInterval == .seconds(1))
        #expect(WatchdogLimits.timerLeeway == .milliseconds(100))
    }
}
