import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The watchdog as `HelperComposition` wires it (ADR 0012 I2, I5, I6).
///
/// What the unit suites cannot say is whether the watchdog in the **composed** helper holds the
/// monitor the connection stamps, the progress the supervisor reports into, the tick source the
/// daemon ships, and the same termination claim the signal teardown ends the process through. A
/// watchdog over a private copy of any of the four compiles, passes every test of the watchdog
/// alone, and watches nothing — the failure shape `HelperComposition` documents for a defaulted
/// latch.
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
                sources: RecordingSignalSources(), terminate: journal.terminate))
    }

    private static func scriptedPlane() -> ScriptedControlPlane {
        ScriptedControlPlane(
            fans: [0: .automatic(at: 2_400)],
            stages: [.nominal(temperatures: LeaseFixture.nominalDieTemperatures)])
    }

    // MARK: - The shipped tick source

    /// The shipped daemon's watchdog is given a tick source that **ticks**.
    ///
    /// Everything else about the watchdog is exercised with a source the test fires by hand, so
    /// a later edit that gave `production()` a source which never fires — a test double
    /// promoted to the default, a refactor that dropped the argument, a conformer whose
    /// `start` returns early — would still arm, still log "armed", never look, and pass every
    /// test here. `DispatchWatchdogTicksTests` covers the timer type; this covers that it is
    /// the one the daemon is built with.
    ///
    /// Behavioural in the way `HelperCompositionTests`' power-observer test is:
    /// `production(log:)` only constructs, so a test may build it on a machine with no SMC, look
    /// at what it holds, and throw it away. Nothing is armed and no timer is made.
    ///
    /// **Mutation:** replace `production`'s default `watchdogTicks` with a source that never
    /// fires. Run: red.
    @Test("The shipped daemon's watchdog is given the real timer")
    func theProductionGraphIsGivenARealTickSource() {
        let ticks = HelperComposition.production(log: Self.helperLog).watchdog.ticks
        let held = String(describing: type(of: ticks))

        #expect(
            ticks is DispatchWatchdogTicks,
            """
            the shipped watchdog's tick source is \(held). Nothing calls tick(), so a wedged \
            round trip or a stalled safety cycle is never noticed, and the log says the \
            watchdog is armed. docs/SAFETY.md § 6, ADR 0012.
            """)
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

        #expect(journal.exitsNow == [.blind])
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
            let afterTeardown = journal.exitsNow
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

            #expect(
                journal.exitsNow == afterTeardown,
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
            #expect(journal.exitsNow == [.blind])

            await helper.signalTeardown.run(stoppingSupervisorsWith: {})
            #expect(
                journal.exitsNow == [.blind],
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
        #expect(journal.exitsNow == [.blind], "nothing ended the wedged process")

        // The teardown comes unstuck, finishes, and asks to end the process too.
        await parked.signal()
        await teardown.value

        #expect(journal.exitsNow == [.blind])
    }

    // MARK: - Never through the connection

    /// What the thread that drives the held window saw.
    private struct HeldWindow: Sendable {
        var occupied = false
        var stampWhileHeld: SMCRoundTripInFlight?
        var faultsAtOnce = -1
        var endedWhileHeld: [TeardownOutcome] = []
        var probeRanWhileHeld = false
        var finished = false
    }

    /// A real `SMCConnection`, really held — a thread parked on a semaphore inside the actor,
    /// not a double that merely suspends — and a verdict reached **and the process ended**
    /// while it is.
    ///
    /// **The decision is synchronous, and so is the ending.** The `.fault` is in the log and
    /// the terminate seam has been called the moment the second `tick()` returns, with no
    /// `await` between: a watchdog that obtained the stamp through an actor hop, or hopped
    /// anywhere before deciding or ending, would not have done either yet. The stamp is read
    /// while the actor is held, from a thread that is not the actor's, and a call queued
    /// behind the held connection has not run when the process has ended.
    ///
    /// ## No dependence on the width of the cooperative pool
    ///
    /// Holding an actor parks a pool thread, and this repository already has two tests that do
    /// (`SMCRoundTripMonitorTests`' and `ThreadBlockingRestorePlane`'s). On a three-core runner
    /// a third left none to resume any of them, and this pull request's first CI run stopped
    /// for twenty minutes. So the held window asks nothing of the pool: the thread that drives
    /// it and the failsafe that ends it are `Thread`s, and it lasts as long as two synchronous
    /// ticks.
    ///
    /// It used to give up the assertion that the process *ends* while the connection is held,
    /// because the ending was a `Task` and a `Task` needs a pool thread this window may be
    /// holding. The ending is synchronous now (ADR 0012's amendment records the reversal), so
    /// the assertion is back, and it holds on a pool of any width: the driver thread calls
    /// `tick()`, and `tick()` calls the terminate seam.
    ///
    /// **Mutation:** read the stamp through an actor hop in `tick()` (a `Task` that awaits an
    /// actor, deciding when it returns). Run: red.
    /// **Mutation:** end the process from a `Task` instead of inline. Run: red.
    @Test("A verdict ends the process while the real connection is held")
    func theWatchdogNeverEntersTheConnectionActor() async {
        let rig = WatchdogRig()
        let connection = SMCConnection(roundTrips: rig.monitor)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let probeFinished = OSAllocatedUnfairLock(initialState: false)
        let window = OSAllocatedUnfairLock(initialState: HeldWindow())

        // The held window. Whatever happens inside it, the `defer` frees the actor, so a failure
        // here is a failure and not a hung process.
        Thread {
            defer {
                release.signal()
                window.withLock { $0.finished = true }
            }
            guard entered.wait(timeout: .now() + .seconds(20)) == .success else { return }
            window.withLock { $0.occupied = true }

            // Queued behind the held connection; it cannot run until the release.
            Task {
                await connection.close()
                probeFinished.withLock { $0 = true }
            }

            // Read from this thread, while the actor is held by another.
            let stamp = rig.monitor.inFlight()
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
            rig.watchdog.tick()
            // No suspension since the second tick: the verdict is in the log and the process
            // has been ended, on this thread.
            window.withLock {
                $0.stampWhileHeld = stamp
                $0.faultsAtOnce = rig.log.faults.count
                $0.endedWhileHeld = rig.exitsNow
                $0.probeRanWhileHeld = probeFinished.withLock { $0 }
            }
        }.start()

        let occupation = Task {
            await connection.occupyForTesting {
                // Timed as well, so even a driver that never ran frees the thread.
                rig.monitor.bracket(.open) {
                    entered.signal()
                    _ = release.wait(timeout: .now() + .seconds(30))
                }
            }
        }

        let finished = await pollUntil { window.withLock { $0.finished } }
        await occupation.value
        let seen = window.withLock { $0 }

        #expect(finished, "the held window never ended")
        #expect(seen.occupied, "the connection was never occupied")
        #expect(seen.stampWhileHeld?.operation == .open, "no stamp was visible while it was held")
        #expect(seen.faultsAtOnce == 1, "the verdict was not reached inside tick()")
        #expect(
            seen.endedWhileHeld == [.blind],
            "the process was not ended, once, while the connection was held: \(seen.endedWhileHeld)"
        )
        #expect(!seen.probeRanWhileHeld, "the connection was not actually held")
        #expect(await pollUntil { probeFinished.withLock { $0 } }, "the queued call never ran")
        #expect(rig.exitsNow == [.blind], "freeing the connection ended the process again")
    }
}
