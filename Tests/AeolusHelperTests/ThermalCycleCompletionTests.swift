import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusHelper

/// What counts as a completed § 3 cycle for the liveness watchdog's progress trigger (ADR
/// 0012, "What a completed § 3 cycle is"): `ThermalEmergency.cycle()` returned `true`, which
/// it does on every exit after its reentrancy guard — the blind path and the firing path
/// included — and `ThermalSupervisor` records progress for that and for nothing else.
///
/// The real emergency and the real supervisor loop, with reads that park where a test needs
/// a cycle held open. Every test names the mutation that must turn it red.
@Suite("What counts as a completed safety cycle", .timeLimit(.minutes(1)))
struct ThermalCycleCompletionTests {

    /// `ThermalSupervisor.run` stamps progress for a cycle that ran.
    ///
    /// **Mutation:** delete `progress.recordCompletion()` from `ThermalSupervisor.run`. Run:
    /// red.
    @Test("Each cycle the supervisor completes is recorded")
    func aCompletedCycleIsStamped() async {
        let machine = ThermalMachine(stages: [.at(44)])
        let progress = ThermalCycleProgress()

        // Two sleeps and a third that throws: three cycles, then the loop ends.
        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: TestClock(sleepBudget: 2),
            interval: .seconds(1), progress: progress)

        #expect(progress.reading().completions == 3)
    }

    /// An entry the reentrancy guard drops is not a cycle. While one cycle sits parked,
    /// every entry of a replacement loop is dropped; counting those would advance the
    /// watchdog's progress every second over a § 3 that is not looking.
    ///
    /// **Mutation:** record the completion unconditionally in `ThermalSupervisor.run`
    /// (ignore what `cycle()` returned). Run: red — three completions where there were none.
    @Test("A cycle the reentrancy guard dropped is not progress")
    func aCycleTheReentrancyGuardDroppedIsNotProgress() async throws {
        let machine = ThermalMachine(stages: [.at(44)])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        await machine.emergencyTelemetry.interfere {
            await entered.signal()
            try? await release.wait()
        }
        let progress = ThermalCycleProgress()

        // The outgoing cycle, parked in an await that is not a round trip.
        let outgoing = Task { await machine.emergency.cycle() }
        try await entered.wait()

        // The replacement loop: three entries, every one dropped.
        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: TestClock(sleepBudget: 2),
            interval: .seconds(1), progress: progress)

        #expect(progress.reading().completions == 0, "a dropped entry counted as a cycle")
        #expect(await machine.emergency.cycle() == false, "the guard no longer drops the entry")

        await release.signal()
        #expect(await outgoing.value == true, "the cycle that did run is a completed one")
    }

    /// A cycle that could read nothing still ran to its end. § 3 handles a blind cycle on its
    /// own path, and the trigger watches for a cycle that does not finish, not for one that
    /// finishes blind — so a blind SMC, which is the machine the watchdog exists for, is not
    /// reported twice.
    ///
    /// **Mutation:** return `false` from the blind path of `ThermalEmergency.cycle()`. Run:
    /// red.
    @Test("A cycle that could read nothing is still a completed cycle")
    func aBlindCycleIsProgress() async {
        let machine = ThermalMachine(stages: [.blind()])
        let progress = ThermalCycleProgress()

        #expect(await machine.emergency.cycle() == true)
        await ThermalSupervisor.run(
            emergency: machine.emergency, clock: TestClock(sleepBudget: 1),
            interval: .seconds(1), progress: progress)
        #expect(progress.reading().completions == 2, "a blind cycle was not counted")
    }

    /// `true` on **every** exit after the guard, not only the two named above: a cycle that
    /// fired, held, released, found its view degraded, or found the episode had moved is a
    /// cycle that ran. Each scenario reaches a different `return` in `cycle()`.
    ///
    /// **Mutation:** return `false` from any one of them (each was run in turn). Run: red,
    /// naming the scenario.
    @Test("Every exit after the guard reports a finished cycle")
    func everyExitAfterTheGuardIsAFinishedCycle() async throws {
        var unfinished: [String] = []
        func check(_ name: String, _ result: Bool) {
            if !result { unfinished.append(name) }
        }

        // Nothing wrong, and then a machine over its ceiling.
        let nominal = ThermalMachine(stages: [.at(44)])
        check("nominal", await nominal.emergency.cycle())
        let firing = ThermalMachine(stages: [.at(97)])
        check("fires", await firing.emergency.cycle())

        // Latched and still hot.
        let hot = ThermalMachine(stages: [.at(97)])
        await hot.emergency.cycle()
        check("holds while hot", await hot.emergency.cycle())

        // Latched, and cool enough to let go.
        let cooling = ThermalMachine(stages: [.at(97), .at(44)])
        await cooling.emergency.cycle()
        await cooling.plane.advance()
        check("releases", await cooling.emergency.cycle())

        // Latched, and the view has shrunk: held through a degraded cycle.
        let degraded = ThermalMachine(stages: [.at(97), .partial(answering: 8, at: 60)])
        await degraded.emergency.cycle()
        await degraded.plane.advance()
        check("holds through a degraded view", await degraded.emergency.cycle())

        // An episode that began during the read.
        let boundary = ThermalMachine(stages: [.at(44), .at(60)])
        await boundary.plane.advance()
        let everyCuratedKey = Set(CriticalSensorSet.mac16x5.keys)
        await boundary.emergencyTelemetry.interfere { [latch = boundary.latch] in
            _ = await latch.engage(
                by: CriticalTemperature(key: smcKey("Tp01"), celsius: 99),
                answering: everyCuratedKey)
        }
        check("declines across an episode boundary", await boundary.emergency.cycle())
        #expect(
            await boundary.emergencyTelemetry.didFire,
            "the scenario never arranged the episode boundary")

        // Blind.
        let blind = ThermalMachine(stages: [.blind()])
        check("blind", await blind.emergency.cycle())

        #expect(unfinished.isEmpty, "these exits returned false: \(unfinished)")
    }
}
