import Foundation
import Testing
import os

@testable import fanctl

/// How a signal reaches the hold loop: by ending the loop's sleep, and by nothing else.
///
/// Cancelling the whole task would also cancel the release that follows, and a release that
/// cannot run is a lease left to expire. These tests drive the interrupt on its own, with a clock
/// whose sleep parks until it is cancelled and records whether it was waited out, so a missing
/// wake-up is a failed assertion about *what ended the sleep* and never a bound on how long the
/// test took.
@Suite("The hold's interrupt", .timeLimit(.minutes(1)))
struct HoldInterruptTests {

    /// A clock whose sleep lasts until it is cancelled, and says whether it was cancelled.
    ///
    /// Twenty real seconds at the outside: only a cancellation ends it early, and a wake-up that
    /// never comes shows as `ranToCompletion` after that wait, not as a suite that never returns.
    private final class ParkedSleep: Sendable {
        private let finished = OSAllocatedUnfairLock(initialState: false)

        var ranToCompletion: Bool { finished.withLock { $0 } }

        var clock: SettleClock {
            SettleClock(
                now: { ContinuousClock.now },
                sleep: { [finished] _ in
                    try await Task.sleep(for: .seconds(20))
                    finished.withLock { $0 = true }
                })
        }
    }

    /// A clock whose sleep returns at once.
    private static let instant = SettleClock(now: { ContinuousClock.now }, sleep: { _ in })

    private struct Broken: Error {}

    private static let failing = SettleClock(
        now: { ContinuousClock.now }, sleep: { _ in throw Broken() })

    /// **Mutation:** make `HoldInterrupt.sleep` ignore a signal posted before it is called
    /// (delete the `alreadyPending` cancel). Run: red — the parked sleep is waited out.
    @Test("A signal posted before the sleep ends it at once")
    func postedBeforeTheSleep() async {
        let interrupt = HoldInterrupt()
        let parked = ParkedSleep()
        interrupt.post(.interrupt)

        #expect(await interrupt.sleep(for: .seconds(10), on: parked.clock) == .signal(.interrupt))
        #expect(!parked.ranToCompletion, "the sleep was waited out, not ended")
    }

    /// **Mutation:** make `post` record the signal and not cancel the sleeper. Run: red, same
    /// way.
    @Test("A signal posted during the sleep ends it")
    func postedDuringTheSleep() async {
        let interrupt = HoldInterrupt()
        let parked = ParkedSleep()
        let clock = parked.clock
        let sleeping = Task { await interrupt.sleep(for: .seconds(10), on: clock) }
        interrupt.post(.terminate)

        #expect(await sleeping.value == .signal(.terminate))
        #expect(!parked.ranToCompletion, "the sleep was waited out, not ended")
    }

    @Test("Without a signal the sleep runs its course")
    func noSignal() async {
        let interrupt = HoldInterrupt()
        #expect(await interrupt.sleep(for: .seconds(10), on: Self.instant) == .elapsed)
        #expect(interrupt.pending == nil)
    }

    /// A signal that arrives while the loop is busy with the helper is not lost: it is
    /// pending for the next look.
    @Test("A signal posted while nothing sleeps is pending")
    func pendingBetweenSleeps() {
        let interrupt = HoldInterrupt()
        interrupt.post(.hangup)
        #expect(interrupt.pending == .hangup)
    }

    /// The first signal is the one reported. A second Ctrl-C during the release is ignored, not
    /// a different reason.
    ///
    /// **Mutation:** record every signal, not only the first (`state.pending = signal` in
    /// `HoldInterrupt.post`). Run: red.
    @Test("The first signal wins")
    func firstSignalWins() {
        let interrupt = HoldInterrupt()
        interrupt.post(.interrupt)
        interrupt.post(.terminate)
        #expect(interrupt.pending == .interrupt)
    }

    /// A timer that fails with no signal behind it is not an elapsed sleep: treating it as one
    /// would turn a broken clock into a loop that renews as fast as it can.
    ///
    /// **Mutation:** return `.elapsed` from the `.failure` case in `HoldInterrupt.sleep`. Run:
    /// red.
    @Test("A sleep that fails for any other reason is reported as failed")
    func failedSleep() async {
        let interrupt = HoldInterrupt()
        #expect(await interrupt.sleep(for: .seconds(10), on: Self.failing) == .failed)
    }

    @Test("The signals have the names a user types")
    func names() {
        #expect(HoldSignal.interrupt.name == "SIGINT")
        #expect(HoldSignal.terminate.name == "SIGTERM")
        #expect(HoldSignal.hangup.name == "SIGHUP")
    }
}
