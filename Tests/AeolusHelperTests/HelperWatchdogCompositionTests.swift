import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The watchdog as `HelperComposition` wires it (ADR 0012 I2, I5, I6).
///
/// What the unit suites cannot say is whether the watchdog in the **composed** helper holds the
/// monitor the connection stamps, the progress the supervisor reports into, and the same
/// termination claim the signal teardown ends the process through. A watchdog over a private
/// copy of any of the three compiles, passes every test of the watchdog alone, and watches
/// nothing — the failure shape `HelperComposition` documents for a defaulted latch.
@Suite("The liveness watchdog, composed", .timeLimit(.minutes(1)))
struct HelperWatchdogCompositionTests {

    private static let helperLog = HelperLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Watchdog")
    private static let safetyLog = SafetyLog(
        subsystem: "dev.aeolus.AeolusHelperTests", category: "Safety")

    /// A graph over `plane`, ending the process into `journal` and ticking when the test says.
    private static func composed<Plane: FanControlPlane>(
        over plane: Plane,
        provider: some SensorProvider = fanProvider(fanCount: 1),
        roundTrips: SMCRoundTripMonitor,
        ticks: ManualWatchdogTicks,
        journal: TeardownJournal
    ) -> HelperComposition<Plane> {
        HelperComposition(
            plane: plane,
            snapshotProvider: provider,
            criticalSensors: .mac16x5,
            roundTrips: roundTrips,
            watchdogTicks: ticks,
            log: helperLog,
            leaseLog: LeaseFixture.log,
            safetyLog: safetyLog,
            teardown: TeardownSeams(
                sources: RecordingSignalSources(),
                terminate: { outcome in await journal.record(.exited(outcome)) }))
    }

    private static func scriptedPlane() -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
    }

    // MARK: - Armed first

    /// The watchdog is armed before reconciliation's first read — and "first read" is read at
    /// the provider the snapshot's fan enumeration uses as well as at the plane, because the
    /// enumeration is the first thing reconciliation asks.
    ///
    /// A watchdog armed after the pass would be armed too late to see the one wedge that
    /// matters most: the first.
    ///
    /// **Mutation:** move `await watchdog.arm()` below `await reconcileFans()` in
    /// `bringUp()`. Run: red.
    @Test("The watchdog is armed before the first read bring-up makes")
    func theWatchdogIsArmedBeforeReconciliationReads() async {
        let ticks = ManualWatchdogTicks()
        let probe = ArmProbe(ticks: ticks)
        let helper = Self.composed(
            over: ArmProbingPlane(probe: probe, wrapping: Self.scriptedPlane()),
            provider: ArmProbingProvider(probe: probe, wrapping: fanProvider(fanCount: 1)),
            roundTrips: idleRoundTrips(), ticks: ticks, journal: TeardownJournal())

        await helper.bringUp()
        await helper.shutDown()

        #expect(probe.readCount > 0, "bring-up read nothing, so this proved nothing")
        #expect(
            probe.firstReadFoundTheWatchdogArmed == true,
            "the first read of bring-up was made before the watchdog was armed")
        #expect(ticks.startCount == 1)
    }

    // MARK: - The right monitor, the right progress

    /// The composed watchdog reads the monitor it was **given** — the one a connection
    /// stamps — and not a private one. A round trip stamped on that monitor, past the bound on
    /// two ticks, ends the process.
    ///
    /// **Mutation:** build the watchdog over `SMCConnection().roundTrips` — a different
    /// connection's monitor — instead of the `roundTrips` parameter. Run: red.
    @Test("The composed watchdog watches the monitor the connection stamps")
    func theWatchdogWatchesTheConnectionThePlaneReadsThrough() async {
        let timeline = WatchdogTimeline()
        let monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
        let journal = TeardownJournal()
        let helper = Self.composed(
            over: Self.scriptedPlane(), roundTrips: monitor, ticks: ManualWatchdogTicks(),
            journal: journal)
        #expect(helper.watchdog.roundTrips === monitor)

        let wedge = WedgedRoundTrip(monitor, tpd0)
        defer { wedge.finish() }
        guard await wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            return
        }
        timeline.advance(by: .seconds(6))
        helper.watchdog.tick()
        helper.watchdog.tick()

        let ended = await pollUntil {
            await exits(of: journal).isEmpty == false
        }
        #expect(ended)
        #expect(await exits(of: journal) == [.blind])
    }

    /// The progress the supervisor stamps is the progress the watchdog reads. Started for
    /// real, the supervisor's first cycle completes and the count the **watchdog** holds
    /// moves; a second progress object on either side leaves it at zero for ever, and the
    /// first healthy helper then restarts itself fifteen seconds after bring-up.
    ///
    /// **Mutation:** give `ThermalSupervisor` a fresh `ThermalCycleProgress()` in the
    /// composition. Run: red. The same for handing the watchdog one.
    @Test("The supervisor reports into the progress the watchdog reads")
    func theSupervisorAndTheWatchdogShareOneProgress() async {
        let helper = Self.composed(
            over: Self.scriptedPlane(), roundTrips: idleRoundTrips(),
            ticks: ManualWatchdogTicks(), journal: TeardownJournal())
        #expect(helper.watchdog.progress === helper.cycleProgress)

        await helper.thermalSupervisor.start()
        let counted = await pollUntil { helper.watchdog.progress.reading().completions > 0 }
        await helper.thermalSupervisor.stop()

        #expect(counted, "a cycle ran and the watchdog's progress never moved")
        #expect(helper.watchdog.progress.reading().phase == .disarmed)
    }

    // MARK: - One claim on ending the process

    /// The watchdog and the teardown end the process through **one** claim. Whichever asks
    /// first wins and the other is refused, in either order: a teardown that finished just
    /// after the watchdog fired must not run `exit` again with a different code, and a
    /// watchdog that fired after the teardown had begun to exit must not begin another.
    ///
    /// **Mutation:** hand the watchdog a fresh `ProcessTermination` around the same terminate
    /// seam instead of `teardown.termination`. Run: red — two exits in the journal.
    @Test("The watchdog and the teardown end the process through one claim")
    func theTerminationIsSharedWithTheTeardown() async {
        // The teardown first, then the watchdog.
        do {
            let timeline = WatchdogTimeline()
            let monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
            let journal = TeardownJournal()
            let helper = Self.composed(
                over: Self.scriptedPlane(), roundTrips: monitor, ticks: ManualWatchdogTicks(),
                journal: journal)
            await helper.signalTeardown.run(stoppingSupervisorsWith: {})
            let afterTeardown = await exits(of: journal)
            #expect(afterTeardown.count == 1, "the teardown did not end the process once")

            let wedge = WedgedRoundTrip(monitor, tpd0)
            defer { wedge.finish() }
            guard await wedge.waitUntilWedged() else {
                Issue.record("the round trip never began")
                return
            }
            timeline.advance(by: .seconds(6))
            helper.watchdog.tick()
            helper.watchdog.tick()
            await settle()

            #expect(
                await exits(of: journal) == afterTeardown,
                "the watchdog ended a process the teardown was already ending")
        }

        // The watchdog first, then the teardown.
        do {
            let timeline = WatchdogTimeline()
            let monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
            let journal = TeardownJournal()
            let helper = Self.composed(
                over: Self.scriptedPlane(), roundTrips: monitor, ticks: ManualWatchdogTicks(),
                journal: journal)
            let wedge = WedgedRoundTrip(monitor, tpd0)
            defer { wedge.finish() }
            guard await wedge.waitUntilWedged() else {
                Issue.record("the round trip never began")
                return
            }
            timeline.advance(by: .seconds(6))
            helper.watchdog.tick()
            helper.watchdog.tick()
            let ended = await pollUntil {
                await exits(of: journal).isEmpty == false
            }
            #expect(ended)

            await helper.signalTeardown.run(stoppingSupervisorsWith: {})
            #expect(
                await exits(of: journal) == [.blind],
                "the teardown ended a process the watchdog was already ending")
        }
    }

    /// A teardown that is itself wedged still lets the watchdog end the process, once, and a
    /// teardown that later comes unstuck cannot end it a second time.
    ///
    /// The teardown sets its `hasBegun` before it awaits the gate and the leases, and both
    /// queue behind a wedged connection — so a guard that stood down because "the teardown has
    /// begun" would silence the watchdog in exactly the case it stays armed through teardown
    /// for. Here the teardown has begun, restored, and is parked at the step that stops the
    /// supervisors; the watchdog fires over it; and the journal ends up with `.blind`, alone.
    ///
    /// **Mutation:** remove the first-terminate-wins guard in `ProcessTermination.end`. Run:
    /// red — `.restored` follows `.blind`.
    /// **Mutation:** refuse the watchdog's `.blind` once the teardown has begun (consult
    /// `hasBegun`). Run: red — nothing ends the wedged process.
    @Test("A wedged teardown is ended blind, exactly once")
    func aWedgedTeardownEndsBlindExactlyOnce() async throws {
        let timeline = WatchdogTimeline()
        let monitor = SMCRoundTripMonitor(clock: timeline.monitorClock)
        let journal = TeardownJournal()
        let helper = Self.composed(
            over: Self.scriptedPlane(), roundTrips: monitor, ticks: ManualWatchdogTicks(),
            journal: journal)

        let parked = AsyncSignal()
        let reached = AsyncSignal()
        let teardown = Task {
            await helper.signalTeardown.run(stoppingSupervisorsWith: {
                await reached.signal()
                try? await parked.wait()
            })
        }
        try await reached.wait()

        let wedge = WedgedRoundTrip(monitor, tpd0)
        defer { wedge.finish() }
        guard await wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            await parked.signal()
            return
        }
        timeline.advance(by: .seconds(6))
        helper.watchdog.tick()
        helper.watchdog.tick()
        let ended = await pollUntil {
            await exits(of: journal).isEmpty == false
        }
        #expect(ended)

        // The teardown comes unstuck, finishes, and asks to end the process too.
        await parked.signal()
        await teardown.value

        #expect(await exits(of: journal) == [.blind])
    }

    // MARK: - Never through the connection

    /// A real `SMCConnection`, really held — a thread parked on a semaphore inside the actor,
    /// not a double that merely suspends — and a verdict reached and acted on while it is.
    ///
    /// **The decision is synchronous.** The `.fault` is in the log the moment the second
    /// `tick()` returns, with no `await` between: a watchdog that obtained the stamp through an
    /// actor hop, or hopped anywhere before deciding, would not have decided yet. That is what
    /// makes this fail for a hop even when the hop is not to the connection. The process then
    /// ends, still with the connection held, and a call queued behind the held connection is
    /// still queued — the proof the actor was really occupied the whole time.
    ///
    /// **Mutation:** read the stamp through an actor hop in `tick()` (a `Task` that awaits an
    /// actor, deciding when it returns). Run: red.
    @Test("A verdict is reached and acted on while the connection is held")
    func theWatchdogNeverEntersTheConnectionActor() async {
        let rig = WatchdogRig()
        let connection = SMCConnection(roundTrips: rig.monitor)
        let release = DispatchSemaphore(value: 0)
        let probeFinished = OSAllocatedUnfairLock(initialState: false)

        // A failsafe that frees the held actor if an assertion below stops the test short, so
        // a failure is a failure and not a hung process. On a thread of its own: the global
        // queue shares workers with the cooperative pool this very test is holding a thread of,
        // and a failsafe that has to wait for the thing it is a failsafe for is not one (#324).
        Thread {
            Thread.sleep(forTimeInterval: 30)
            release.signal()
        }.start()

        let occupation = Task {
            await connection.occupyForTesting {
                // Timed as well, so even a failsafe that never ran frees the thread.
                rig.monitor.bracket(.open) { _ = release.wait(timeout: .now() + .seconds(60)) }
            }
        }
        guard await pollUntil({ rig.monitor.inFlight() != nil }) else {
            Issue.record("the connection was never occupied")
            release.signal()
            await occupation.value
            return
        }

        // Queued behind the held connection; it cannot run until the release below.
        let probe = Task {
            await connection.close()
            probeFinished.withLock { $0 = true }
        }

        rig.timeline.advance(by: .seconds(6))
        rig.watchdog.tick()
        rig.watchdog.tick()
        // No `await` since the second tick: the verdict is already in the log.
        let faultsAtOnce = rig.log.faults.count

        let ended = await rig.waitForExit()
        for _ in 0..<25 { try? await Task.sleep(for: .milliseconds(10)) }
        let probeRanWhileHeld = probeFinished.withLock { $0 }

        release.signal()
        await occupation.value
        await probe.value

        #expect(faultsAtOnce == 1, "the verdict was not reached inside tick()")
        #expect(ended, "the process was not ended while the connection was held")
        #expect(await exits(of: rig.journal) == [.blind])
        #expect(!probeRanWhileHeld, "the connection was not actually held")
        #expect(probeFinished.withLock { $0 }, "the queued call never ran once it was freed")
    }
}
