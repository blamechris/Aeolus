import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The one claim on ending the process, from the watchdog's side (ADR 0012 I5, correction 3):
/// the terminate seam is called **once**, by whoever asks first, synchronously, and the line
/// the watchdog writes says which of the two it was.
///
/// None of this waits for anything. The ending happens inside `tick()`, on the thread that
/// called it, so a test reads the answer the instant the call returns — which is the point of
/// the change that made it so, and the reason none of these tests can depend on the width of
/// the cooperative pool.
@Suite("The watchdog and the one ending", .timeLimit(.minutes(1)))
struct WatchdogEndingTests {

    /// A wedge the watchdog will call a verdict on in two ticks.
    private static func wedged(_ rig: WatchdogRig) {
        rig.timeline.advance(by: .seconds(6))
    }

    // MARK: - Who ends it

    /// The seam is called exactly once, however many ticks follow and whoever else asks: the
    /// watchdog first, the teardown after.
    ///
    /// **Mutation:** remove the first-wins `return` in `ProcessTermination.end`. Run: red.
    /// **Mutation:** never set `fired`. Run: red.
    @Test("The terminate seam is called exactly once: the watchdog first, the teardown after")
    func theWatchdogEndsItAndTheTeardownIsRefused() {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            Self.wedged(rig)
            for _ in 0..<4 { rig.watchdog.tick() }
        }
        rig.termination.end(.restored)

        #expect(rig.exitsNow == [.blind], "the seam was called \(rig.exitsNow.count) times")
        let refusals = rig.log.lines(containing: "already ending as blind")
        #expect(refusals.count == 1, "\(rig.log.lines)")
        #expect(refusals.first?.level == .notice)
    }

    /// The other order: the orderly teardown reached its last step first. The verdict is as
    /// real as it was and is still a `.fault`, but it **does not say the helper is ending
    /// because of it**, promises no restart, and the seam is not called again.
    ///
    /// **Mutation:** write the verdict line before taking the claim (always the "Ending the
    /// helper now" form). Run: red. **Mutation:** call the seam whether or not the claim was
    /// granted. Run: red.
    @Test("A teardown that claimed first is not overruled, and the verdict does not pretend")
    func theTeardownEndsItAndTheVerdictSaysSo() {
        let rig = WatchdogRig()
        rig.termination.end(.restored)

        rig.monitor.bracket(tpd0) {
            Self.wedged(rig)
            rig.tickTwice()
        }

        #expect(rig.exitsNow == [.restored], "the seam was called \(rig.exitsNow.count) times")
        let faults = rig.log.faults
        #expect(faults.count == 1, "one verdict, one fault: \(faults)")
        let line = faults.first ?? ""
        #expect(line.contains("an SMC round trip has not returned"), "\(line)")
        #expect(line.contains("already ending as restored"), "\(line)")
        #expect(line.contains("promises no restart"), "\(line)")
        #expect(!line.contains("Ending the helper now"), "the line claims an ending: \(line)")
        #expect(!line.contains("exit code 2"), "the line claims a code that was not used: \(line)")
    }

    /// The refusal names who holds the claim, whichever it is: with `.restored` first it says
    /// so, and with `.blind` first it says that.
    ///
    /// **Mutation:** store a fixed outcome in the claim (`held = .restored`). Run: red.
    /// **Mutation:** delete the `log.terminationAlreadyClaimed(…)` call. Run: red.
    @Test("A refused request is logged, and the line names the holder")
    func aSecondRequestToEndTheProcessIsRefused() {
        let first = WatchdogRig()
        first.termination.end(.restored)
        first.termination.end(.blind)
        #expect(first.exitsNow == [.restored])
        let refusal = first.log.lines(containing: "already ending as restored")
        #expect(refusal.count == 1)
        #expect(refusal.first?.level == .notice)
        #expect(refusal.first?.message.contains("blind") == true)

        let other = WatchdogRig()
        other.termination.end(.blind)
        other.termination.end(.restored)
        #expect(other.exitsNow == [.blind])
        #expect(other.log.lines(containing: "already ending as blind").count == 1)
    }

    // MARK: - Under contention

    /// Both enders at once, thousands of times: the seam is called once every time, and which
    /// of the two it was is whichever got the claim.
    ///
    /// **What it can and cannot show.** A claim taken in two locked steps (check, then set) has
    /// a window of a few instructions. The two threads are held on a spin barrier and released
    /// within nanoseconds of each other, round after round, because a thread started per round
    /// reaches the lock microseconds apart and never inside the window. Whether a given run
    /// lands one inside is still chance, so a run that kills the two-step mutant proves the
    /// mutant is catchable and a run that does not proves nothing about the real claim; the
    /// deterministic tests above carry the first-wins mutations, and this one carries the
    /// claim's atomicity on the best evidence a test can have without a hook in the lock.
    ///
    /// Threads, not tasks: the race is between two threads reaching one lock, and nothing here
    /// asks anything of the cooperative pool.
    ///
    /// **Mutation:** take the claim in two locked steps (read `held`, then set it in a second
    /// `withLock`). Run: see the pull request for how often.
    @Test("The watchdog and the teardown racing end the process once")
    func theClaimHoldsUnderContention() async {
        let rig = WatchdogRig()
        let wedge = WedgedRoundTrip(rig.monitor, tpd0)
        defer { wedge.finish() }
        guard await wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            return
        }
        rig.timeline.advance(by: .seconds(6))

        let rounds = 2_000
        let calls = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: rounds))
        let quiet = WatchdogLog(recording: { _, _ in })
        // Everything is built before either thread starts, and each watchdog has already seen
        // the wedge once: its next tick is the one that reaches the claim.
        let terminations = (0..<rounds).map { round in
            ProcessTermination(terminate: { _ in calls.withLock { $0[round] += 1 } }, log: quiet)
        }
        let watchdogs = terminations.map {
            LivenessWatchdog(
                roundTrips: rig.monitor, progress: rig.progress, termination: $0,
                ticks: rig.ticks, log: quiet)
        }
        for watchdog in watchdogs { watchdog.tick() }

        let barrier = RoundBarrier()
        let finished = OSAllocatedUnfairLock(initialState: 0)
        Thread {
            for round in 0..<rounds {
                barrier.arrive(round: round)
                watchdogs[round].tick()
            }
            finished.withLock { $0 += 1 }
        }.start()
        Thread {
            for round in 0..<rounds {
                barrier.arrive(round: round)
                terminations[round].end(.restored)
            }
            finished.withLock { $0 += 1 }
        }.start()

        #expect(
            await pollUntil({ finished.withLock { $0 } == 2 }), "the racing threads never ended")
        let wrong = calls.withLock { counts in
            counts.enumerated().filter { $0.element != 1 }.map {
                "round \($0.offset): \($0.element)"
            }
        }
        #expect(
            wrong.isEmpty,
            "the terminate seam was not called exactly once in \(wrong.count) rounds: \(wrong.prefix(5))"
        )
    }
}

/// Holds two threads at the same point of a round until both have arrived, spinning rather than
/// blocking: a semaphore wake-up is microseconds, and the window it is used to reach is
/// nanoseconds. Gives up after twenty seconds of spinning, so a thread that died cannot leave
/// its partner spinning for the life of the process.
final class RoundBarrier: Sendable {
    private let arrivals = OSAllocatedUnfairLock(initialState: 0)

    func arrive(round: Int) {
        arrivals.withLock { $0 += 1 }
        let target = 2 * (round + 1)
        let giveUp = DispatchTime.now() + .seconds(20)
        while arrivals.withLock({ $0 }) < target, DispatchTime.now() < giveUp {
            sched_yield()
        }
    }
}
