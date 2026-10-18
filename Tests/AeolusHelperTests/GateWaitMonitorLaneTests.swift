import SMCCore
import Testing

@testable import AeolusHelper

/// The two scheduler observers see § 3's lane as they see the supervisor's queue (ADR 0012's
/// 2026-10-18 amendment): `GateWaitMonitor` mirrors a lane waiter, so one parked past G faults,
/// and `ConnectionHealth` counts a lane read that answers nothing towards the reconnect, as it
/// counts a supervisor read.
///
/// Both are driven through the real scheduler, so the events are the ones it emits for the lane
/// rather than ones a test spelled.
@Suite("The scheduler's observers see § 3's lane", .timeLimit(.minutes(1)))
struct GateWaitMonitorLaneTests {

    private static let pastTheBound = WatchdogLimits.gateWaiterAlarm + .seconds(1)

    /// A lane waiter parked behind a turn that is never given back faults once, naming the lane,
    /// and the mirror forgets it once it is served. A lane waiter waits for one turn in flight, so
    /// one past G is a turn that did not come back.
    ///
    /// **Mutation:** in `GateWaitMonitor.schedulerDidObserve(_:)`, skip `.waiterParked` when the
    /// priority is `.thermalCycle`. Run: red — no fault.
    @Test("A lane waiter parked past G faults once")
    func aLaneWaiterPastGFaultsOnce() async throws {
        let rig = WatchdogRig()
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider, observer: rig.gate)

        let stuck = observing { try await scheduler.read(keys: ["S0"], at: .snapshot) }
        await yieldUntil("the first read to reach the provider") {
            await provider.turns.count == 1
        }
        let lane = observing { try await scheduler.read(keys: ["T0"], at: .thermalCycle) }
        await yieldUntil("the lane read to be queued behind it") {
            await scheduler.queuedTurns(at: .thermalCycle) == 1
        }
        #expect(rig.gate.depth(at: .thermalCycle) == 1, "the mirror does not hold the lane")

        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        rig.timeline.advance(by: .seconds(1))
        rig.watchdog.tick()

        #expect(rig.log.faults.count == 1, "\(rig.log.faults)")
        let line = rig.log.faults.first ?? ""
        #expect(line.contains("priority thermalCycle"), "\(line)")
        #expect(rig.exitsNow.isEmpty, "a parked waiter ended the process")

        await provider.releaseEveryTurn()
        _ = try await finished("the read that held the turn", stuck)
        _ = try await finished("the lane read", lane)
        #expect(rig.gate.oldestParked().isEmpty, "a served lane waiter is still in the mirror")
    }

    /// Three lane reads that answer nothing are a run of three, and reconnect once; lane and
    /// supervisor failures in one run are one run.
    ///
    /// **Mutation:** in `ConnectionHealth.schedulerDidObserve(_:)`, drop
    /// `.wholeReadFailed(priority: .thermalCycle, …)` before it is numbered. Run: red — no
    /// reconnect from the lane's run, and none from the mixed one.
    @Test("A lane read failing every key counts towards the reconnect")
    func aFailingLaneReadCountsTowardsTheReconnect() async throws {
        for script in [
            [SMCReadPriority.thermalCycle, .thermalCycle, .thermalCycle],
            [.thermalCycle, .supervisor, .thermalCycle],
        ] {
            let recovery = RecordingReconnector()
            let health = ConnectionHealth(
                clock: TestClock(), log: SafetyLog(recording: { _, _ in }))
            await health.start(recovering: recovery)
            let scheduler = SMCReadScheduler(
                provider: OutcomeScriptedProvider {
                    .failure(.readFailed(reason: "the SMC did not answer \($0)"))
                },
                observer: health)

            for priority in script {
                _ = try await scheduler.read(keys: ["TPD0", "TPD1"], at: priority)
            }
            await yieldUntil("every outcome to be handled") {
                await health.observedOutcomes == script.count
            }

            let attempts = await recovery.attempts
            #expect(attempts == 1, "\(script) reconnected \(attempts) times")
            await health.stop()
        }
    }
}
