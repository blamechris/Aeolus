import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The bounded wait `fanctl auto` ends on (`SafeState.settle`): ten seconds, once a second, on an
/// injectable clock. What one snapshot makes of a fan is `SafeStateTests`, whose fixtures and
/// doubles this suite shares. Pure — a scripted reader and a virtual clock stand in for the
/// helper and for time, so the whole window is walked without waiting for it.
@Suite("The safe-state wait")
struct SafeStateSettleTests {

    typealias Fixtures = SafeStateTests

    // MARK: - The window

    @Test("The window is ten seconds, polled every second, and a whole number of polls")
    func theWindowIsTenSecondsAtOneSecond() {
        #expect(SafeState.window == .seconds(10))
        #expect(SafeState.pollInterval == .seconds(1))
        #expect(
            SafeState.window.components.seconds % SafeState.pollInterval.components.seconds == 0)
        #expect(SafeState.window.components.attoseconds == 0)
    }

    /// Already safe on the first read: no wait at all.
    ///
    /// **Mutation:** delete the early `return` on `.automatic` in `SafeState.settle`. Run: red —
    /// it sleeps and reads eleven times.
    @Test("A first read that is safe returns at once, without sleeping")
    func settlesImmediately() async {
        let script = Script([.read(Fixtures.automatic)])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .automatic)
        #expect(settlement.polls == 1)
        #expect(settlement.interruption == nil)
        #expect(settlement.snapshot == Fixtures.automatic)
        #expect(time.sleeps.isEmpty)
    }

    /// Polled every second, and stopped the moment it reads safe.
    ///
    /// **Mutation:** change `pollInterval` to `.seconds(2)`. Run: red on the sleeps.
    @Test("It polls once a second and stops at the first safe reading")
    func settlesAfterThreePolls() async {
        let script = Script([
            .read(Fixtures.leasedManual), .read(Fixtures.leasedManual),
            .read(Fixtures.leasedManual),
            .read(Fixtures.automatic),
        ])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .automatic)
        #expect(settlement.polls == 4)
        #expect(settlement.snapshot == Fixtures.automatic)
        #expect(time.sleeps == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(script.reads == 4, "it read past the first safe snapshot")
    }

    /// Exactly the window: eleven reads at 0, 1, … 10 s, ten one-second sleeps, and then it
    /// stops. Both off-by-one neighbours fail here: a tenth-second short and a poll too many.
    ///
    /// **Mutation:** change `clock.now() >= deadline` to `clock.now() > deadline` in
    /// `SafeState.settle` (twelve reads), and separately change `window` to `.seconds(5)` or
    /// `.seconds(20)`. Run: red on the counts and on the elapsed time.
    @Test("A fan that never settles is read for exactly ten seconds, then reported")
    func neverSettles() async {
        let script = Script([.read(Fixtures.leasedManual)], repeating: true)
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 11)
        #expect(script.reads == 11)
        #expect(time.sleeps == Array(repeating: .seconds(1), count: 10))
        #expect(time.elapsed == .seconds(10))
        #expect(settlement.snapshot == Fixtures.leasedManual)
        #expect(settlement.interruption == nil)
    }

    /// The pin is classified from the last reading, at the end — a transient reason that
    /// clears to a durable one is judged by what it ended as.
    @Test("The verdict at the end of the window is the last reading's")
    func theLastReadingDecides() async {
        let pinned = Fixtures.snapshot([
            Fixtures.fan(
                0, mode: .manualFixed, availability: .unavailable(.restoreToAutomaticFailed))
        ])
        let script = Script([.read(Fixtures.leasedManual), .read(pinned)], repeating: true)
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .cannotReturn(fans: [0]))
        #expect(settlement.snapshot == pinned)
    }

    // MARK: - When the helper stops answering

    /// A read that fails ends the wait with what was last read, and never reports safe: the
    /// helper stopped answering, and that is not an observation of automatic.
    ///
    /// **Mutation:** return `.automatic` from the `catch` around the read in
    /// `SafeState.settle`. Run: red on the verdict.
    @Test("A read that fails stops the wait, keeps the last snapshot, and is never safe")
    func aFailedReadIsAnInterruption() async {
        let script = Script([
            .read(Fixtures.leasedManual), .read(Fixtures.leasedManual),
            .fail(HelperClientTestError.gone),
        ])
        let time = VirtualTime()

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 2)
        #expect(settlement.snapshot == Fixtures.leasedManual)
        #expect(settlement.interruption as? HelperClientTestError == .gone)
        #expect(time.sleeps.count == 2, "it kept polling after the helper stopped answering")
    }

    @Test("A failure on the very first read leaves no snapshot to show")
    func aFirstReadFailureHasNoSnapshot() async {
        let script = Script([.fail(HelperClientTestError.gone)])
        let settlement = await SafeState.settle(reading: script.next, clock: VirtualTime().clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.polls == 0)
        #expect(settlement.snapshot == nil)
        #expect(settlement.interruption != nil)
    }

    /// A cancelled wait is not a settled one.
    ///
    /// **Mutation:** `try?` the `clock.sleep` call in `SafeState.settle`. Run: red — the
    /// cancelled sleep is ignored and the loop runs on.
    @Test("A wait that is cancelled stops, and is never safe")
    func aCancelledSleepIsAnInterruption() async {
        let script = Script([.read(Fixtures.leasedManual)], repeating: true)
        let time = VirtualTime(failingSleepWith: CancellationError())

        let settlement = await SafeState.settle(reading: script.next, clock: time.clock)

        #expect(settlement.verdict == .notConfirmed)
        #expect(settlement.interruption is CancellationError)
        #expect(script.reads == 1)
    }

    // MARK: - The production clock

    /// The shipping clock is monotonic and really waits; the virtual one above proves nothing
    /// about either.
    ///
    /// **A lower bound only.** A sleep cannot return early, so "at least this long" holds on
    /// any machine; "no more than" does not. This test once also asserted an upper bound of
    /// five seconds and failed on CI at 7.4 s, because 60 ms of sleep is queued behind
    /// everything else the runner is doing — the wall-clock-upper-bound defect of
    /// [#97](https://github.com/blamechris/Aeolus/issues/97) and
    /// [#250](https://github.com/blamechris/Aeolus/issues/250). What the upper bound would have
    /// caught, a `sleep` that waits forever, hangs this test instead of passing it.
    @Test("The production clock waits for the duration it is given, on ContinuousClock")
    func productionClockWaits() async throws {
        let clock = SettleClock.production
        let before = clock.now()
        try await clock.sleep(.milliseconds(60))
        let elapsed = clock.now() - before
        #expect(elapsed >= .milliseconds(55), "slept \(elapsed)")
    }
}
