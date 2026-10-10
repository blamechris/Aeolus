import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The liveness watchdog's progress triggers (ADR 0012 I4 and its amendment): D_bringUp, from
/// arming to the supervisor starting, and D_cycle, from the supervisor starting to its being
/// stopped.
///
/// The cycle tests drive the **real** `ThermalSupervisor` and the **real** `ThermalEmergency`,
/// with a read that parks in the middle of a cycle: a cycle that never completes is what a § 3
/// stall looks like, and a test that stamped the progress object by hand would prove the
/// watchdog and leave the supervisor's `start()`, `stop()` and `run` — the three places the
/// phase and the count are actually set — unexamined.
@Suite("The liveness watchdog's progress triggers", .timeLimit(.minutes(1)))
struct LivenessWatchdogProgressTests {

    /// A § 3 machine whose first critical read parks until released, with the supervisor over
    /// it already started.
    private struct StalledSupervisor {
        let machine: ThermalMachine
        let supervisor: ThermalSupervisor<ScriptedControlPlane>
        let entered: AsyncSignal
        let release: AsyncSignal

        init(progress: ThermalCycleProgress) async {
            machine = ThermalMachine(stages: [.at(44)])
            entered = AsyncSignal()
            release = AsyncSignal()
            let (entered, release) = (self.entered, self.release)
            await machine.emergencyTelemetry.interfere {
                await entered.signal()
                try? await release.wait()
            }
            supervisor = ThermalSupervisor(
                emergency: machine.emergency, clock: TestClock(), interval: .seconds(1),
                progress: progress)
        }

        /// Starts the loop and waits until its first cycle is parked inside the read.
        func startAndWaitUntilParked() async throws {
            await supervisor.start()
            try await entered.wait()
        }

        func finish() async {
            await supervisor.stop()
            await release.signal()
        }
    }

    // MARK: - D_cycle

    /// A cycle that never completes ends the process, and the line names the trigger, the
    /// phase, the age since the last completion, the completion count, and that no stamp is in
    /// flight.
    ///
    /// **Mutation:** delete the `.cycling` arm of `LivenessWatchdog.suspects(flight:reading:)`
    /// (the progress trigger). Run: red.
    /// **Mutation:** delete `progress.beginCycling()` from `ThermalSupervisor.start()`. Run: red
    /// — the watchdog here was never armed, so the phase stays disarmed and nothing is
    /// watching the cycle. (With bring-up in force it names the wrong trigger instead; see
    /// `startingTheSupervisorMovesTheBound`.)
    @Test("A safety cycle that does not complete ends the process")
    func aStalledSafetyCycleEndsTheProcess() async throws {
        let rig = WatchdogRig()
        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        // Fourteen seconds without a completed cycle is inside D_cycle (15 s).
        rig.timeline.advance(by: .seconds(14))
        rig.tickTwice()
        #expect(rig.log.faults.isEmpty, "the bound was not yet crossed")

        rig.timeline.advance(by: .seconds(2))
        rig.tickTwice()

        let line = try #require(rig.log.faults.first)
        #expect(rig.log.faults.count == 1)
        #expect(line.contains("safety-cycle trigger fired in the cycling phase"), "\(line)")
        #expect(line.contains("16.000 s"), "\(line)")
        #expect(line.contains("bound of 15.000 s"), "\(line)")
        #expect(line.contains("0 completion(s)"), "\(line)")
        #expect(line.contains("No stamp is in flight."), "\(line)")
        #expect(rig.exitsNow == [.blind])
        await stalled.finish()
    }

    /// Whether a stamp is in flight is evidence either way, and the line says which: a stalled
    /// cycle with a call out is a different diagnosis from one with none.
    ///
    /// **Mutation:** omit the stamp from the cycle verdict. Run: red.
    @Test("A stalled cycle's line says whether a round trip is in flight, and what it is")
    func aStalledCycleNamesTheStampInFlight() async throws {
        let rig = WatchdogRig()
        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        // A round trip that began two seconds ago — younger than D, so it is evidence and not
        // a verdict of its own — while no cycle has completed for sixteen.
        rig.timeline.advance(by: .seconds(14))
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(2))
            rig.tickTwice()
        }

        let line = try #require(rig.log.faults.first)
        #expect(rig.log.faults.count == 1)
        #expect(line.contains("safety-cycle trigger"), "\(line)")
        #expect(line.contains("A stamp is in flight: an SMC call"), "\(line)")
        #expect(line.contains("'TPD0' (0x54504430)"), "\(line)")
        await stalled.finish()
    }

    /// A cycle that completes every second and a half never trips it, however long the helper
    /// has run: the age is from the **last completion**, not from the start of the phase.
    ///
    /// Completions are *slower than the tick*, on purpose. With one completion per tick the
    /// completion count differs on every look, so the "same count on two ticks" rule alone
    /// would hide a progress object that never moved its anchor; with a gap longer than a
    /// tick, two consecutive ticks see the same count, and only the anchor stands between a
    /// healthy helper and a verdict.
    ///
    /// **Mutation:** do not move the anchor in `ThermalCycleProgress.recordCompletion()`. Run:
    /// red — the sixteenth second of a perfectly healthy run ends the process.
    @Test("Cycles that keep completing never trip the cycle trigger")
    func aHealthyCycleNeverTrips() async {
        let rig = WatchdogRig()
        rig.progress.beginCycling()

        // A tick every half second and a completion every third: 1.5 s between completions.
        for step in 0..<400 {
            rig.timeline.advance(by: .milliseconds(500))
            if step % 3 == 2 { rig.progress.recordCompletion() }
            rig.watchdog.tick()
        }

        #expect(rig.log.faults.isEmpty)
        #expect(rig.exitsNow.isEmpty)
    }

    /// A stopped supervisor is not a stall. Teardown stops § 3 on purpose, and the watchdog
    /// stays armed through it for the round-trip trigger alone.
    ///
    /// Driven through the real `ThermalSupervisor.stop()`, because that is the line that
    /// disarms the trigger.
    ///
    /// **Mutation:** delete `progress.endCycling()` from `ThermalSupervisor.stop()`. Run: red
    /// — an hour after teardown stopped § 3, the helper ends `.blind`.
    @Test("A supervisor that was stopped is not a stall")
    func aStoppedSupervisorIsNotAStall() async throws {
        let rig = WatchdogRig()
        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        await stalled.supervisor.stop()
        rig.timeline.advance(by: .seconds(3_600))
        for _ in 0..<5 { rig.watchdog.tick() }

        #expect(rig.log.faults.isEmpty)
        #expect(rig.exitsNow.isEmpty)
        await stalled.finish()
    }

    /// The ordinary shape of a stop: `stop()` cancels without awaiting, the cycle in flight
    /// finishes and returns `true`, and `run` records it. That late completion counts — and it
    /// must not re-arm the cycle trigger over a loop that is dead, or an hour after teardown
    /// stopped § 3 the helper ends `.blind`.
    ///
    /// **Mutation:** set the phase to `.cycling` in `ThermalCycleProgress.recordCompletion()`.
    /// Run: red.
    @Test("A completion that arrives after stop() does not re-arm the cycle trigger")
    func aLateCompletionAfterStopDoesNotReArm() async throws {
        let rig = WatchdogRig()
        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        await stalled.supervisor.stop()
        await stalled.release.signal()
        #expect(
            await pollUntil { rig.progress.reading().completions > 0 },
            "the outgoing cycle never completed")
        rig.timeline.advance(by: .seconds(3_600))
        for _ in 0..<5 { rig.watchdog.tick() }

        #expect(rig.log.faults.isEmpty, "\(rig.log.faults)")
        #expect(rig.exitsNow.isEmpty)
        #expect(rig.progress.reading().phase == .disarmed)
    }

    /// A loop that ends **on its own** — not because anyone called `stop()` — is a § 3 that
    /// stopped looking, and the cycle trigger firing over it is deliberate (the
    /// `ThermalSupervisor.stop()` doc says so). Nothing told the watchdog to stand down.
    ///
    /// **Mutation:** also call `progress.endCycling()` in `ThermalSupervisor.loopEnded`. Run:
    /// red.
    @Test("A loop that ends on its own is a stall")
    func aLoopThatEndsOnItsOwnIsAStall() async {
        let rig = WatchdogRig()
        let machine = ThermalMachine(stages: [.at(44)])
        let supervisor = ThermalSupervisor(
            emergency: machine.emergency, clock: TestClock(sleepBudget: 0),
            interval: .seconds(1), progress: rig.progress)

        await supervisor.start()
        let ended = await pollUntil { await supervisor.isRunning == false }
        #expect(ended, "the loop never ended on its own")

        rig.timeline.advance(by: .seconds(16))
        rig.tickTwice()

        #expect(rig.log.faults.first?.contains("safety-cycle trigger") == true)
        #expect(rig.exitsNow == [.blind])
    }

    /// Stopping a supervisor that was **never started** does not silence the bring-up bound:
    /// a bring-up that has not yet started the supervisors has not stopped them, it has
    /// stalled.
    ///
    /// **Mutation:** make `ThermalCycleProgress.endCycling()` disarm unconditionally. Run: red.
    @Test("Stopping a supervisor that never started leaves the bring-up bound in force")
    func aStopBeforeAnyStartDoesNotSilenceTheBringUp() async {
        let rig = WatchdogRig()
        let machine = ThermalMachine(stages: [.at(44)])
        let supervisor = ThermalSupervisor(
            emergency: machine.emergency, clock: TestClock(), interval: .seconds(1),
            progress: rig.progress)
        await rig.watchdog.arm()

        await supervisor.stop()
        rig.timeline.advance(by: .seconds(16))
        rig.tickTwice()

        #expect(rig.log.faults.count == 1)
    }

    /// A trigger that went away and came back is not the same streak. The same stall — the
    /// same completion count — seen, then lost for a tick (the supervisor was stopped), then
    /// seen again after a restart, is one sighting and then one more, not two in a row.
    ///
    /// **Mutation:** keep the streak entries a tick did not see (do not rebuild `streaks` from
    /// `found`). Run: red.
    @Test("A streak a tick did not see starts again from one")
    func aBrokenStreakStartsOver() async {
        let rig = WatchdogRig()
        rig.progress.beginCycling()

        rig.timeline.advance(by: .seconds(16))
        rig.watchdog.tick()  // seen: the cycle stalled at 0 completions, streak of one.

        rig.progress.endCycling()
        rig.watchdog.tick()  // not seen: nothing is armed, so nothing is suspect.

        rig.progress.beginCycling()  // the same count, 0, and a fresh anchor.
        rig.timeline.advance(by: .seconds(16))
        rig.watchdog.tick()  // seen again: a streak of one, not two.

        #expect(rig.log.faults.isEmpty, "a tick that did not see the stall left its streak alive")
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1, "and two in a row are still a verdict")
    }

    // MARK: - D_bringUp

    /// A bring-up that never starts the supervisors ends the process, at D_bringUp (15 s) and
    /// not before.
    ///
    /// **Mutation:** delete `progress.beginBringUp()` from `LivenessWatchdog.arm()`. Run:
    /// red — the phase stays disarmed, and a bring-up that never finishes is watched by
    /// nothing.
    @Test("A bring-up that never starts the supervisors ends the process")
    func aBringUpThatNeverStartsTheSupervisorsEnds() async throws {
        let rig = WatchdogRig()
        await rig.watchdog.arm()

        rig.timeline.advance(by: .seconds(14))
        rig.tickTwice()
        #expect(rig.log.faults.isEmpty, "the bring-up bound is 15 s")

        rig.timeline.advance(by: .seconds(2))
        rig.tickTwice()

        let line = try #require(rig.log.faults.first)
        #expect(line.contains("bring-up trigger fired in the bring-up phase"), "\(line)")
        #expect(line.contains("16.000 s"), "\(line)")
        #expect(line.contains("bound of 15.000 s"), "\(line)")
        #expect(line.contains("No stamp is in flight."), "\(line)")
        #expect(rig.exitsNow == [.blind])
    }

    /// A stalled bring-up names a round trip in flight when there is one, as a stalled cycle
    /// does: evidence, younger than D, and not a verdict of its own.
    ///
    /// **Mutation:** omit the stamp from the bring-up verdict. Run: red.
    @Test("A stalled bring-up's line says what round trip is in flight")
    func aStalledBringUpNamesTheStampInFlight() async throws {
        let rig = WatchdogRig()
        await rig.watchdog.arm()

        rig.timeline.advance(by: .seconds(14))
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(2))
            rig.tickTwice()
        }

        let line = try #require(rig.log.faults.first)
        #expect(line.contains("bring-up trigger fired in the bring-up phase"), "\(line)")
        #expect(line.contains("A stamp is in flight: an SMC call"), "\(line)")
        #expect(line.contains("'TPD0' (0x54504430)"), "\(line)")
    }

    /// Starting the supervisor ends the bring-up bound and begins D_cycle from that moment:
    /// the first cycle is held to the same bound as every later one, measured from when it
    /// could begin — not from arming, and not to 15 s of bring-up that no longer applies.
    ///
    /// **Mutation:** delete the `anchor` assignment in `ThermalCycleProgress.beginCycling()`.
    /// Run: red — the cycle bound is measured from arming and trips early.
    @Test("Starting the supervisor begins D_cycle from that moment")
    func startingTheSupervisorMovesTheBound() async throws {
        let rig = WatchdogRig()
        await rig.watchdog.arm()
        rig.timeline.advance(by: .seconds(10))

        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        // Twenty-four seconds since arming, fourteen since the supervisor started.
        rig.timeline.advance(by: .seconds(14))
        rig.tickTwice()
        #expect(rig.log.faults.isEmpty, "D_cycle runs from start(), not from arming")

        rig.timeline.advance(by: .seconds(2))
        rig.tickTwice()
        #expect(rig.log.faults.first?.contains("safety-cycle trigger") == true)
        await stalled.finish()
    }

    /// A `start()` that finds the loop already running changes nothing, and in particular does
    /// not give a stalled cycle a fresh fifteen seconds: only a call that actually starts a loop
    /// begins the phase.
    ///
    /// **Mutation:** move `progress.beginCycling()` above the `guard task == nil` in
    /// `ThermalSupervisor.start()`. Run: red.
    @Test("A start() that finds the loop running does not reset the stall's clock")
    func aRedundantStartDoesNotResetTheClock() async throws {
        let rig = WatchdogRig()
        let stalled = await StalledSupervisor(progress: rig.progress)
        try await stalled.startAndWaitUntilParked()

        rig.timeline.advance(by: .seconds(14))
        #expect(await stalled.supervisor.start() == false, "the loop was already running")
        rig.timeline.advance(by: .seconds(2))
        rig.tickTwice()

        #expect(rig.log.faults.first?.contains("safety-cycle trigger") == true)
        await stalled.finish()
    }
}
