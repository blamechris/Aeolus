import Testing

@testable import AeolusHelper

/// A supervisor whose loop ended on its own must be startable again.
///
/// All three loops — § 1's TTL, § 3's ceiling, § 5's watchdog — are near-copies of one
/// shape, and they shared one defect
/// ([#131](https://github.com/blamechris/Aeolus/issues/131)): the handle `isRunning` and
/// `start()`'s guard both read was cleared in `stop()` and nowhere else, while the loop had
/// a **second** exit — the `break` taken when `sleep(until:)` throws. A loop that ended any
/// other way left the handle behind, so `isRunning` described a loop that was over and
/// `start()` refused to replace it for the life of the process.
///
/// ## Why a suite of its own, and why all three
///
/// One property, stated once, checked identically against each supervisor. Each of the
/// three files already has a suite about *its* mechanism; this one is about the shape they
/// share, and a reader who fixes one copy and not the others should be told by a test
/// rather than by a wedged daemon.
///
/// `TestClock(sleepBudget: 0)` is what makes the second exit reachable without cancelling
/// anything: the first `sleep` throws, the loop breaks, `run` returns and the loop is over
/// with `stop()` never called. That is precisely the state #131 describes.
@Suite("A self-terminated supervisor loop can be restarted")
struct SupervisorRestartTests {

    /// **Kills:** clearing `task` only in `stop()` — the shape on `main` — in
    /// `ThermalSupervisor`. With the handle left behind, `isRunning` stays `true` after the
    /// loop has ended and `start()` returns `false` forever.
    ///
    /// The thermal one matters most. `ThermalEmergency.cycle()` is the only caller of the
    /// latch's `release()` anywhere in `Sources/`, so a § 3 supervisor that stops while
    /// latched and can never be restarted strands the latch engaged: every snapshot reports
    /// an emergency that is over and `acquireLease` refuses `.thermalEmergencyActive` until
    /// the process dies.
    @Test("The thermal supervisor restarts after its loop ends on its own")
    func theThermalSupervisorRestarts() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let supervisor = ThermalSupervisor(
            emergency: machine.emergency,
            clock: TestClock(sleepBudget: 0),
            interval: .seconds(1))

        #expect(await supervisor.start())
        let ended = await yieldUntil("the loop to end on its own") {
            await supervisor.isRunning == false
        }
        #expect(ended, "isRunning still describes the handle rather than the loop")

        #expect(await supervisor.start(), "a loop that ended on its own could not be restarted")
    }

    /// **Kills:** the same mutation in `ReclamationSupervisor`.
    ///
    /// While § 5's loop is not running nothing watches for the firmware taking a fan back:
    /// the snapshot keeps reporting Aeolus's target and the lease TTL is the only surviving
    /// backstop. A supervisor that cannot be restarted makes that permanent.
    @Test("The reclamation supervisor restarts after its loop ends on its own")
    func theReclamationSupervisorRestarts() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let supervisor = ReclamationSupervisor(
            watchdog: machine.watchdog,
            clock: TestClock(sleepBudget: 0),
            interval: .seconds(1))

        #expect(await supervisor.start())
        let ended = await yieldUntil("the loop to end on its own") {
            await supervisor.isRunning == false
        }
        #expect(ended, "isRunning still describes the handle rather than the loop")

        #expect(await supervisor.start(), "a loop that ended on its own could not be restarted")
    }

    /// **Kills:** the same mutation in `LeaseExpirySupervisor`, where the shape originated.
    ///
    /// The TTL is the lease's independent path back to automatic control. A supervisor that
    /// silently refuses to restart leaves connection death as the only one, which is exactly
    /// the single-mechanism state ADR 0005 has two for.
    @Test("The lease expiry supervisor restarts after its loop ends on its own")
    func theLeaseExpirySupervisorRestarts() async {
        let supervisor = LeaseExpirySupervisor(
            authority: LeaseFixture.authority(),
            clock: TestClock(sleepBudget: 0),
            idleInterval: .seconds(1))

        #expect(await supervisor.start())
        let ended = await yieldUntil("the loop to end on its own") {
            await supervisor.isRunning == false
        }
        #expect(ended, "isRunning still describes the handle rather than the loop")

        #expect(await supervisor.start(), "a loop that ended on its own could not be restarted")
    }

    /// A **superseded** loop must not clear its successor's handle on the way out.
    ///
    /// The reason the exit is generation-checked rather than an unconditional `task = nil`:
    /// `stop()` cancels without awaiting, so an outgoing loop routinely finishes *after* a
    /// new one has started — which is precisely what a sleep/wake cycle does. Clearing the
    /// handle from there would report `isRunning == false` for a loop that is running, and
    /// the next `start()` would then run two supervisors against one mechanism: the exact
    /// state `start()`'s guard exists to prevent, arrived at through the fix for #131.
    ///
    /// `GatedClock` is what makes the ordering a scenario rather than a hope: the outgoing
    /// loop is held inside its sleep until the successor is running and also asleep.
    ///
    /// **Kills:** dropping the generation check — `loopEnded` nilling `task` unconditionally.
    @Test("A superseded loop does not clear its successor's handle")
    func aSupersededLoopDoesNotClearItsSuccessor() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let clock = GatedClock()
        let record = RecordedLog()
        let supervisor = ThermalSupervisor(
            emergency: machine.emergency,
            clock: clock,
            interval: .seconds(1),
            log: SafetyLog(recording: { record.append($0, $1) }))

        #expect(await supervisor.start())
        #expect(await yieldUntil("the first loop to reach its sleep") { await clock.waiting == 1 })

        // Cancelled and abandoned: nothing awaits it, and it is still parked in its sleep.
        await supervisor.stop()
        #expect(await supervisor.start(), "the supervisor could not be restarted")
        #expect(await yieldUntil("both loops to be asleep") { await clock.waiting == 2 })

        await clock.release()
        #expect(
            await yieldUntil("the superseded loop to run its exit") {
                record.lines(containing: "Thermal emergency supervisor stopped").isEmpty == false
            })
        // And every chance to reach the handle after that.
        for _ in 0..<500 { await Task.yield() }

        #expect(await supervisor.isRunning, "a superseded loop cleared a running loop's handle")
        #expect(
            await supervisor.start() == false,
            "two supervisors could now run against one mechanism")

        await supervisor.stop()
        await clock.release()
    }
}

/// A clock whose every sleep waits until the test lets it go.
///
/// `TestClock` cannot express the ordering `aSupersededLoopDoesNotClearItsSuccessor` needs
/// — one loop parked inside a sleep while its replacement starts and reaches a sleep of its
/// own — because its `sleep` returns as soon as it is called. `release()` resumes only the
/// sleepers waiting at that moment, so a loop that goes straight back to sleep is parked
/// again rather than left spinning a test's cooperative pool.
actor GatedClock: MonotonicClock {

    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var now: ContinuousClock.Instant { ContinuousClock.now }

    /// How many sleeps are parked right now.
    var waiting: Int { waiters.count }

    /// Lets every currently parked sleep return. Later sleeps park again.
    func release() {
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }

    func sleep(until deadline: ContinuousClock.Instant) async {
        await withCheckedContinuation { waiters.append($0) }
    }
}
