import Testing

@testable import AeolusHelper

/// The loop that makes `docs/SAFETY.md` § 5's watchdog a mechanism rather than a method
/// somebody could call.
///
/// `ThermalSupervisorTests`' shape, deliberately, because the two loops are near-copies and
/// a reader comparing them should be comparing like with like. Driven against `TestClock`,
/// whose `sleep` returns instantly and throws once its budget is spent, so the **real** loop
/// runs here rather than a paraphrase of it against wall time.
///
/// ## This file exists because it did not
///
/// The supervisor shipped with 143 lines of loop and **zero** tests, while its own `start()`
/// doc asserted that its idempotence guard was *"a fact a test can check rather than a guard
/// whose deletion nothing would notice"*. No such test existed. An adversarial review found
/// it, and listed the mutations that all survived a green suite: deleting the `cycle()` call
/// so the loop only sleeps and logs, replacing `while !Task.isCancelled` with `while true`,
/// deleting `task?.cancel()`, deleting the `guard task == nil`, and dropping the
/// `minimumWake` floor so a zero interval spins a core in a root daemon.
///
/// Each test below names the mutation it kills, and each was run.
@Suite("The reclamation supervisor")
struct ReclamationSupervisorTests {

    /// One cycle per pass, until cancellation.
    ///
    /// **Kills:** deleting `await watchdog.cycle()` from `run(watchdog:clock:interval:log:)`,
    /// which leaves § 5 a loop that sleeps and logs while a reclaimed fan goes unnoticed.
    /// A sleep budget of two allows three passes.
    @Test("Each pass runs exactly one cycle, until cancellation")
    func eachPassRunsOneCycle() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let clock = TestClock(sleepBudget: 2)

        await ReclamationSupervisor.run(
            watchdog: machine.watchdog, clock: clock, interval: .seconds(1))

        let reads = await machine.attempts.filter {
            if case .readControlState = $0 { return true }
            return false
        }
        #expect(reads.count == 3)
        #expect(clock.sleeps.count == 3)
    }

    /// The cadence is honoured rather than spun.
    @Test("The loop sleeps for its interval between cycles")
    func theLoopSleepsForItsInterval() async {
        let machine = ReclamationMachine()
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)

        await ReclamationSupervisor.run(
            watchdog: machine.watchdog, clock: clock, interval: .seconds(1))

        #expect(clock.sleeps.first == start.advanced(by: .seconds(1)))
    }

    /// **Kills:** dropping the `minimumWake` floor. A misconfigured interval must not spin a
    /// core in a root daemon, exactly as `LeaseExpirySupervisor.minimumWake` requires.
    @Test("A zero interval still waits the minimum")
    func aZeroIntervalStillWaits() async {
        let machine = ReclamationMachine()
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)

        await ReclamationSupervisor.run(
            watchdog: machine.watchdog, clock: clock, interval: .zero)

        #expect(
            clock.sleeps.first
                == start.advanced(by: ReclamationSupervisor<ScriptedControlPlane>.minimumWake))
    }

    /// The loop actually drives the mechanism, rather than only calling into it.
    ///
    /// A fan diverged before the loop starts — the firmware holds 1,800 where 2,400 was
    /// commanded — must be re-asserted **through the loop**, with the test never calling
    /// `cycle()` by hand. This is the difference between "the supervisor invokes something"
    /// and "the supervisor runs § 5".
    @Test("A divergence present before the loop starts is acted on by it")
    func theLoopDrivesTheWatchdog() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let clock = TestClock(sleepBudget: 1)

        await ReclamationSupervisor.run(
            watchdog: machine.watchdog, clock: clock, interval: .seconds(1))

        #expect(await machine.ledger.isReclaimed(fanAt: 0))
        #expect(await machine.commandedRPMs.contains(2_400))
    }

    /// **`stop()` must stop the loop, not just the bookkeeping.**
    ///
    /// **Kills:** deleting `task?.cancel()`, and replacing `while !Task.isCancelled` with
    /// `while true`. Both leave `startingTwiceRunsOneSupervisor` below green, because that
    /// one asserts `isRunning`, which is a `task != nil` flag.
    ///
    /// Bounded by yields rather than by awaiting the task, deliberately: awaiting a loop that
    /// no longer honours cancellation would hang, and a regression that arrives as a CI
    /// timeout instead of a red assertion is the anti-pattern
    /// [#109](https://github.com/blamechris/Aeolus/issues/109) is open about. With the
    /// cancellation removed the read count keeps climbing across the settle window and this
    /// fails in milliseconds.
    @Test("Stopping the supervisor stops the cycling, not just the flag")
    func stoppingStopsTheCycling() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        // A budget the loop cannot exhaust, so the only way out is cancellation.
        let supervisor = ReclamationSupervisor(
            watchdog: machine.watchdog, clock: TestClock(), interval: .seconds(1))

        await supervisor.start()
        while await machine.plane.attempts.count < 3 { await Task.yield() }
        await supervisor.stop()

        // Let any cycle already in flight finish.
        for _ in 0..<200 { await Task.yield() }
        let settled = await machine.plane.attempts.count

        for _ in 0..<2_000 { await Task.yield() }
        #expect(
            await machine.plane.attempts.count == settled,
            "the loop kept cycling after stop()")
    }

    /// **Kills:** deleting `guard task == nil else { return false }` from `start()`, which
    /// would run two watchdog loops against one registry — two sweeps interleaving on the
    /// same fans, which is the concurrency the mechanism's own re-fetch guards exist for and
    /// which nothing should be creating deliberately.
    @Test("Starting twice runs one supervisor, and stopping ends it")
    func startingTwiceRunsOneSupervisor() async {
        let machine = ReclamationMachine()
        let supervisor = ReclamationSupervisor(
            watchdog: machine.watchdog, clock: TestClock(), interval: .seconds(1))

        #expect(await supervisor.start())
        #expect(await supervisor.start() == false)
        #expect(await supervisor.isRunning)

        await supervisor.stop()
        #expect(await supervisor.isRunning == false)
    }

    /// Stopping does **not** restore the fans, and that asymmetry against
    /// `ThermalSupervisor.stop()` is deliberate.
    ///
    /// § 3 leaves its latch engaged on the way out because releasing it would hand fans back
    /// on a machine nobody has read. § 5 does the opposite and leaves the fans *held*,
    /// because they are held by a client with a live lease and a running TTL — restoring
    /// them from a stopping supervisor would take working manual control away from a user
    /// because a loop was cancelled.
    ///
    /// **What this proves is narrow, and worth stating.** `ReclamationSupervisor` holds no
    /// writer and no plane, so today the property is structural and no single-line edit to
    /// that file can break it. This is a tripwire against the two-part change that could:
    /// giving the supervisor a writer and restoring in `stop()`.
    @Test("Stopping the supervisor restores nothing and keeps watching nothing")
    func stoppingRestoresNothing() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)

        let supervisor = ReclamationSupervisor(
            watchdog: machine.watchdog, clock: TestClock(), interval: .seconds(1))
        await supervisor.start()
        await supervisor.stop()

        #expect(await machine.didRestore(fan: 0) == false)
        #expect(await machine.watchdog.fansUnderManualControl == [0])
    }

    /// The loop says so on its way out, and says how much is at stake.
    ///
    /// A supervisor that went quiet without a word would be the worst silent failure here:
    /// while it is stopped nothing watches for the firmware taking a fan back, the snapshot
    /// keeps reporting Aeolus's target, and the lease TTL is the only surviving backstop.
    /// The level carries that — `.fault` when fans are still held, `.notice` when none are.
    @Test("The loop reports its own stop, at a level that reflects what is held")
    func theLoopReportsItsOwnStop() async throws {
        let held = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await held.hold(fan: 0, commanding: 2_400)
        await ReclamationSupervisor.run(
            watchdog: held.watchdog,
            clock: TestClock(sleepBudget: 0),
            interval: .seconds(1),
            log: SafetyLog(recording: { [log = held.safetyLog] in log.append($0, $1) }))

        #expect(held.safetyLog.levels(containing: "supervisor stopped") == [.fault])

        let idle = ReclamationMachine(fans: [:])
        await ReclamationSupervisor.run(
            watchdog: idle.watchdog,
            clock: TestClock(sleepBudget: 0),
            interval: .seconds(1),
            log: SafetyLog(recording: { [log = idle.safetyLog] in log.append($0, $1) }))

        #expect(idle.safetyLog.levels(containing: "supervisor stopped") == [.notice])
    }
}
