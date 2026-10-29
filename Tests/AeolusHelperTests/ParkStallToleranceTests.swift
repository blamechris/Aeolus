import Foundation
import Testing

@testable import AeolusHelper

/// A park's ceiling does not spend a runner stall
/// ([#549](https://github.com/blamechris/Aeolus/issues/549)), and still gives up on a park nobody
/// releases.
///
/// `AsyncSignal.wait(atMost:)` used to expire on one wall-clock sleep, so a test process stopped
/// for longer than the 10 s `parkCeiling` woke with the timer already due and abandoned a park its
/// test was about to release. It is a `StallTolerantWait` poll now. Each test here runs it on a
/// `VirtualWaitClock`, for the reason `OutwaitStallToleranceTests` gives: a 30 s stall costs
/// microseconds and blocks no thread, where the `kill -STOP` that shows the fix end to end is run
/// by hand, against a `swift test` process started for the purpose.
///
/// `wait(atMost:clock:)` is one function with the real clock as its default, so the body these
/// tests drive is the body the four doubles run, and a reversion of it to one wall-clock sleep
/// turns them red. What the real clock adds is covered where it already was: `ParkingCeilingTests`
/// gives each double a park nobody releases, which gives up at its ceiling there.
@Suite("A park's ceiling does not spend a runner stall", .timeLimit(.minutes(1)))
struct ParkStallToleranceTests {

    /// A park released after a stall longer than its whole ceiling is let through by the release,
    /// not by the ceiling.
    ///
    /// The stall lands on the third sleep and is 30 s; the clock sends the signal on the fifth.
    /// A ceiling that spent the stall would give up at the third sleep, signal on the park's
    /// behalf, and have `wait(atMost:)` answer `false`.
    ///
    /// **Mutation:** in `wait(atMost:clock:)`, pass `budget: .wallTime` to the poll, so a late
    /// sleep is spent from the ceiling and not added to it. Run: red on `released`, which is
    /// `false`.
    @Test("A park released after a stall longer than its ceiling is not abandoned")
    func aParkRidesOutAStall() async throws {
        let signal = AsyncSignal()
        let base = VirtualWaitClock(lateness: { $0 == 3 ? .seconds(30) : .zero })

        let released = try await signal.wait(
            atMost: parkCeiling, clock: ReleasingWaitClock(base, releasing: signal, atSleep: 5))

        #expect(released, "the ceiling expired on a stall, with a release five sleeps away")
        #expect(await base.elapsed > .seconds(30), "the stall really happened on the clock")
    }

    /// A park nobody releases gives up inside the smallest `.timeLimit` however late its sleeps
    /// come back.
    ///
    /// Every sleep here is a second late, so each is a stall and each is added to the deadline,
    /// and the ceiling never arrives by itself. The 50 s cap is what ends the wait, and it ends it
    /// before the parking suites' one minute: a park that outlasted that would be the hang
    /// ([#451](https://github.com/blamechris/Aeolus/issues/451)) the ceiling exists to prevent.
    ///
    /// **Mutation:** in `wait(atMost:clock:)`, pass `ceiling: .seconds(3600)` to the poll. Run:
    /// red on the second expectation, the clock having moved by about 17 minutes.
    @Test("A park nobody releases gives up at the cap, inside the smallest time limit")
    func aParkNobodyReleasesGivesUpAtTheCap() async throws {
        let signal = AsyncSignal()
        let clock = VirtualWaitClock(lateness: { _ in .seconds(1) })

        let released = try await signal.wait(atMost: parkCeiling, clock: clock)

        #expect(released == false, "the ceiling never expired on a park nobody released")
        let elapsed = await clock.elapsed
        #expect(
            elapsed >= StallTolerantWait.ceiling && elapsed < .seconds(60),
            "it gave up after \(elapsed), and not at the \(StallTolerantWait.ceiling) cap")
    }
}

/// A `VirtualWaitClock` that sends `signal` once `count` sleeps have been asked for, and then
/// sleeps for real until it is cancelled: the park released at an instant the test chose on the
/// clock, and not whenever the scheduler gets to it, with no way for the ceiling to expire
/// between the release and the end of the wait.
struct ReleasingWaitClock: WaitClock {

    private let base: VirtualWaitClock
    private let signal: AsyncSignal
    private let count: Int

    init(_ base: VirtualWaitClock, releasing signal: AsyncSignal, atSleep count: Int) {
        self.base = base
        self.signal = signal
        self.count = count
    }

    func now() async -> ContinuousClock.Instant { await base.now() }

    func sleep(for interval: Duration) async throws {
        try await base.sleep(for: interval)
        guard await base.sleeps >= count else { return }
        await signal.signal()
        // A sleeping task and not a spin: the wait returning cancels the timer, which ends it.
        try await ContinuousClock().sleep(for: .seconds(3600))
    }
}
