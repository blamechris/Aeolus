import Testing

@testable import AeolusHelper

/// The loop that makes `docs/SAFETY.md` § 3's *"samples critical sensors every cycle"* a
/// mechanism rather than a method somebody could call.
///
/// Driven against `TestClock`, whose `sleep` returns instantly and throws once its budget is
/// spent — so the **real** loop runs here, not a paraphrase of it against wall time. That is
/// `LeaseExpirySupervisorTests`' approach and the reason is the same: a supervisor tested
/// through a re-implementation is a supervisor nobody tested.
@Suite("The thermal supervisor")
struct ThermalSupervisorTests {

    /// One cycle per pass, and the loop keeps going until it is cancelled. A sleep budget of
    /// two allows three passes: cycle, sleep, cycle, sleep, cycle, sleep-throws.
    @Test("Each pass runs exactly one cycle, until cancellation")
    func eachPassRunsOneCycle() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let clock = TestClock(sleepBudget: 2)

        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: clock, interval: .seconds(1))

        let reads = await machine.plane.attempts.filter {
            if case .readCriticalTemperatures = $0 { return true }
            return false
        }
        #expect(reads.count == 3)
        #expect(clock.sleeps.count == 3)
    }

    /// The cadence is honoured rather than spun. Without the interval this loop would busy-
    /// wait a core in a root daemon.
    @Test("The loop sleeps for its interval between cycles")
    func theLoopSleepsForItsInterval() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)

        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: clock, interval: .seconds(1))

        #expect(clock.sleeps.first == start.advanced(by: .seconds(1)))
    }

    /// A misconfigured interval must not spin a core. The floor applies whatever was asked
    /// for, exactly as `LeaseExpirySupervisor.minimumWake` does.
    @Test("A zero interval still waits the minimum")
    func aZeroIntervalStillWaits() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let start = ContinuousClock.now
        let clock = TestClock(start: start, sleepBudget: 1)

        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: clock, interval: .zero)

        #expect(
            clock.sleeps.first
                == start.advanced(by: ThermalSupervisor<ScriptedControlPlane>.minimumWake))
    }

    /// The loop actually fires the mechanism, rather than only calling it. A scenario that
    /// climbs past the ceiling between passes must produce a latch without the test driving
    /// `cycle()` by hand.
    @Test("A scenario that climbs past the ceiling latches through the loop")
    func theLoopFiresTheEmergency() async throws {
        let machine = ThermalMachine(stages: [.at(44), .at(97)])
        try await machine.lease(fans: [0])
        let clock = TestClock(sleepBudget: 1)
        await machine.plane.advance()

        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: clock, interval: .seconds(1))

        #expect(await machine.latch.isActive)
        #expect(await machine.leases.leaseCount == 0)
    }

    @Test("Starting twice runs one supervisor, and stopping ends it")
    func startingTwiceRunsOneSupervisor() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let supervisor = ThermalSupervisor(
            emergency: machine.emergency, clock: TestClock(), interval: .seconds(1))

        #expect(await supervisor.start())
        #expect(await supervisor.start() == false)
        #expect(await supervisor.isRunning)

        await supervisor.stop()
        #expect(await supervisor.isRunning == false)
    }

    /// Stopping the loop does not release § 3. A supervisor that cleared the latch on its
    /// way out would hand the fans back on a machine nobody has read since it was above its
    /// ceiling — the failure asymmetry reached through a lifecycle event.
    @Test("Stopping the supervisor does not clear the latch")
    func stoppingDoesNotClearTheLatch() async throws {
        let machine = ThermalMachine(stages: [.at(97)])
        await machine.emergency.cycle()
        #expect(await machine.latch.isActive)

        let supervisor = ThermalSupervisor(
            emergency: machine.emergency, clock: TestClock(), interval: .seconds(1))
        await supervisor.start()
        await supervisor.stop()

        #expect(await machine.latch.isActive)
    }
}
