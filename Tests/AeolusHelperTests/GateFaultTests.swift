import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The liveness watchdog's third trigger: a read parked at the scheduler's gate for longer than
/// G (ADR 0012, PR C, #135).
///
/// **It raises a `.fault` and nothing else.** The gate stays non-cancellable, so there is no wait
/// to abandon, and the action on a gate that never turns is D_cycle's: § 3 reads through the same
/// gate, so a leaked turn starves it and the cycle trigger ends the helper. This trigger is how
/// the log says *why* two seconds earlier than the ending would, and that it was a waiter and not
/// a round trip.
///
/// Time is a `WatchdogTimeline` the test moves, ticks are `tick()` calls, waiters are the
/// scheduler's own two events emitted by hand, and the process ends into a journal — so nothing
/// here waits on a clock, and nothing can end `swift test`.
///
/// Every test names the mutation that must turn it red; each was run, and the table is on the
/// pull request.
@Suite("The liveness watchdog's gate trigger", .timeLimit(.minutes(1)))
struct GateFaultTests {

    /// Past G by a second: comfortably over, so that a test about something else is not also a
    /// test about the edge.
    private static let pastTheBound = WatchdogLimits.gateWaiterAlarm + .seconds(1)

    // MARK: - One fault per waiter

    /// A waiter parked past G logs one `.fault`, and a waiter that **stays** parked does not
    /// log another on every tick that follows.
    ///
    /// **Mutation:** delete the `log.gateWaiter(…)` call in `LivenessWatchdog.tick()`. Run: red.
    /// **Mutation:** drop the rate-collapse — log every overdue waiter on every tick, without
    /// comparing its ticket to the last one faulted. Run: red — six faults for one waiter.
    @Test("A waiter parked past the bound faults once, however many ticks follow")
    func aParkedWaiterPastTheBoundFaultsOnce() {
        let rig = WatchdogRig()
        GateScript(rig.gate).park(.supervisor)

        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1, "\(rig.log.faults)")

        for _ in 0..<5 {
            rig.timeline.advance(by: .seconds(1))
            rig.watchdog.tick()
        }
        #expect(rig.log.faults.count == 1, "a waiter that stayed parked faulted again")
    }

    /// The next waiter is a new waiter: once a fault is logged for one, a different one that
    /// also outlives G is logged in its own right. The collapse is per waiter, not once per
    /// priority for the life of the process.
    ///
    /// **Mutation:** collapse on the priority alone (`gateFaulted[priority] == nil`, or a
    /// `Set<SMCReadPriority>`). Run: red — the second waiter is never logged.
    @Test("A second waiter faults in its own right")
    func aSecondWaiterFaultsInItsOwnRight() {
        let rig = WatchdogRig()
        let script = GateScript(rig.gate)

        let first = script.park(.supervisor)
        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1)

        script.grant(first)
        script.park(.supervisor)
        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        rig.watchdog.tick()

        #expect(rig.log.faults.count == 2, "\(rig.log.faults)")
    }

    /// The line names what it is about: the **priority**, how long the oldest waiter at it has
    /// waited, and how many are parked behind that gate. Two priorities that are both overdue
    /// are two lines, each with its own figures.
    ///
    /// The timeline: a snapshot waiter at 0 s; three supervisor waiters at 1 s, 3 s and 5 s;
    /// read at 12 s. The snapshot has waited 12 s; the oldest supervisor 11 s of three.
    ///
    /// **Mutation:** name the priority `.supervisor` in every line. Run: red.
    /// **Mutation:** report the youngest waiter's age (the last in the queue). Run: red.
    /// **Mutation:** report the depth of the other priority's queue. Run: red.
    @Test("The fault names the priority, the age and the queue depth")
    func theFaultNamesThePriorityTheAgeAndTheDepth() {
        let rig = WatchdogRig()
        let script = GateScript(rig.gate)
        script.park(.snapshot)
        rig.timeline.advance(by: .seconds(1))
        script.park(.supervisor)
        rig.timeline.advance(by: .seconds(2))
        script.park(.supervisor)
        rig.timeline.advance(by: .seconds(2))
        script.park(.supervisor)
        rig.timeline.advance(by: .seconds(7))

        rig.watchdog.tick()

        let supervisor = rig.log.lines(containing: "priority supervisor")
        let snapshot = rig.log.lines(containing: "priority snapshot")
        #expect(supervisor.count == 1, "\(rig.log.lines)")
        #expect(snapshot.count == 1, "\(rig.log.lines)")
        let supervisorLine = supervisor.first?.message ?? ""
        let snapshotLine = snapshot.first?.message ?? ""
        #expect(supervisorLine.contains("11.000 s"), "\(supervisorLine)")
        #expect(supervisorLine.contains("3 waiting at that priority"), "\(supervisorLine)")
        #expect(snapshotLine.contains("12.000 s"), "\(snapshotLine)")
        #expect(snapshotLine.contains("1 waiting at that priority"), "\(snapshotLine)")
        #expect(rig.log.faults.count == 2, "a gate fault is logged at .fault, one per priority")
        for line in [supervisorLine, snapshotLine] {
            #expect(line.contains("bound of 10.000 s"), "\(line)")
        }
    }

    // MARK: - The edge

    /// A waiter that has waited exactly G has not waited past it, and one nanosecond more has.
    ///
    /// **Mutation:** `>=` for `>` against `WatchdogLimits.gateWaiterAlarm`. Run: red.
    @Test("A waiter is past G only after G")
    func aWaiterAtExactlyGIsNotPastIt() {
        let rig = WatchdogRig()
        GateScript(rig.gate).park(.supervisor)

        rig.timeline.advance(by: WatchdogLimits.gateWaiterAlarm)
        rig.watchdog.tick()
        #expect(rig.log.faults.isEmpty, "exactly G is a fault: \(rig.log.faults)")

        rig.timeline.advance(by: .nanoseconds(1))
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1, "one nanosecond past G is not a fault")
    }

    /// A waiter the scheduler serves just under G never faults, however long the process
    /// runs on afterwards: the grant took it out, and nothing that was served keeps aging.
    ///
    /// **Mutation:** ignore `turnGranted` in `GateWaitMonitor.schedulerDidObserve(_:)`. Run:
    /// red — the served waiter is thirty seconds old by the last tick.
    @Test("A waiter granted just under G never faults")
    func aWaiterGrantedJustUnderGNeverFaults() {
        let rig = WatchdogRig()
        let script = GateScript(rig.gate)
        let waiter = script.park(.supervisor)

        rig.timeline.advance(by: WatchdogLimits.gateWaiterAlarm - .milliseconds(1))
        rig.watchdog.tick()
        script.grant(waiter)

        for _ in 0..<30 {
            rig.timeline.advance(by: .seconds(1))
            rig.watchdog.tick()
        }

        #expect(rig.log.faults.isEmpty, "\(rig.log.faults)")
        #expect(rig.exitsNow.isEmpty)
    }

    // MARK: - A round trip in flight explains the wait

    /// A waiter parked behind a stamped round trip that is older than one tick is explained by
    /// that stamp, and the gate stays silent while it is. The stamp has its own alarm: D, if it
    /// keeps going, or D_cycle, if it starves § 3. Two faults for one wedge would send a reader
    /// looking for two problems.
    ///
    /// Here the stamp is two seconds old — over a tick, well under D, so it is not yet a verdict
    /// — and the waiter has waited thirteen. **Once the stamp clears the fault is owed**: the
    /// suppression defers it and does not forgive it.
    ///
    /// **Mutation:** drop the suppression (never consult the stamp). Run: red.
    /// **Mutation:** record the waiter as faulted before the suppression check, so a suppressed
    /// waiter is never logged. Run: red — the second half.
    @Test("The gate fault is silent while a stamped round trip explains it")
    func theGateFaultIsSilentWhileAStampedRoundTripExplainsIt() {
        let rig = WatchdogRig()
        GateScript(rig.gate).park(.supervisor)
        rig.timeline.advance(by: Self.pastTheBound)

        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(2))
            rig.watchdog.tick()
        }
        #expect(rig.log.faults.isEmpty, "a stamp two seconds old did not explain the wait")

        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1, "the fault was forgiven, not deferred")
    }

    /// "Explains" means older than **one tick**, not older than D. A reader who took
    /// "overdue" to mean past D would suppress too little (a stamp between a tick and D is
    /// the case this exists for), and one who took it to mean "present" would suppress every
    /// waiter parked behind a healthy 11 ms round trip.
    ///
    /// **Mutation:** suppress only against a stamp older than D (`WatchdogLimits.roundTrip`).
    /// Run: red — the stamp at 1.5 s no longer explains the wait.
    /// **Mutation:** `>=` for `>` against `WatchdogLimits.tick`. Run: red — a stamp of exactly
    /// one tick explains it.
    /// **Mutation:** suppress while any stamp is in flight. Run: red — a young stamp explains it.
    @Test("A stamp explains the wait only when it is older than one tick")
    func aStampExplainsTheWaitOnlyWhenOlderThanATick() {
        // Exactly one tick: not older than one tick, so it explains nothing.
        do {
            let rig = WatchdogRig()
            GateScript(rig.gate).park(.supervisor)
            rig.timeline.advance(by: Self.pastTheBound)
            rig.monitor.bracket(tpd0) {
                rig.timeline.advance(by: WatchdogLimits.tick)
                rig.watchdog.tick()
            }
            #expect(rig.log.faults.count == 1, "a stamp of exactly one tick explained the wait")
        }
        // A tick and a nanosecond: older than one tick, so it does.
        do {
            let rig = WatchdogRig()
            GateScript(rig.gate).park(.supervisor)
            rig.timeline.advance(by: Self.pastTheBound)
            rig.monitor.bracket(tpd0) {
                rig.timeline.advance(by: WatchdogLimits.tick + .nanoseconds(1))
                rig.watchdog.tick()
            }
            #expect(rig.log.faults.isEmpty, "a stamp older than one tick did not explain it")
        }
        // Well under D and well over a tick.
        do {
            let rig = WatchdogRig()
            GateScript(rig.gate).park(.supervisor)
            rig.timeline.advance(by: Self.pastTheBound)
            rig.monitor.bracket(tpd0) {
                rig.timeline.advance(by: .milliseconds(1_500))
                rig.watchdog.tick()
            }
            #expect(rig.log.faults.isEmpty, "a stamp between a tick and D did not explain it")
        }
    }

    // MARK: - Report only

    /// The gate fault ends nothing. The terminate seam is never called, the claim on ending the
    /// process is never taken (it is still there to be had), and the line says that this is a
    /// report and what ends the helper if the gate never turns.
    ///
    /// **Mutation:** take the claim and end the process in the gate path of `tick()`
    /// (`if case .granted(let ending) = termination.claim(.blind) { ending.end() }` after the
    /// log). Run: red.
    @Test("The gate fault never ends the process")
    func theGateFaultNeverEndsTheProcess() {
        let rig = WatchdogRig()
        GateScript(rig.gate).park(.supervisor)

        rig.timeline.advance(by: WatchdogLimits.gateWaiterAlarm * 3)
        for _ in 0..<10 { rig.watchdog.tick() }

        #expect(rig.log.faults.count == 1)
        #expect(rig.exitsNow.isEmpty, "a parked waiter ended the process: \(rig.exitsNow)")
        let line = rig.log.faults.first ?? ""
        #expect(line.contains("does not end the helper"), "\(line)")
        #expect(!line.contains("Ending the helper now"), "\(line)")
        // The claim is untouched: the next thing to ask for it is granted it.
        guard case .granted = rig.termination.claim(.restored) else {
            Issue.record("the gate trigger took the claim on ending the process")
            return
        }
    }

    /// A gate that never turns is ended by D_cycle, not by this trigger: the fault comes first
    /// and is logged once, and the safety cycle starved behind the same gate ends the helper
    /// `.blind` when it has gone D_cycle without completing. The gate fault must not stand in
    /// the cycle trigger's way.
    ///
    /// **Mutation:** set `state.fired = true` when a gate fault is logged (reusing the verdict's
    /// latch to collapse it). Run: red — no verdict is ever reached.
    @Test("A gate that never turns is ended by the cycle trigger")
    func aGateThatNeverTurnsIsEndedByTheCycleTrigger() {
        let rig = WatchdogRig()
        rig.progress.beginCycling()
        GateScript(rig.gate).park(.supervisor)

        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1)
        #expect(rig.exitsNow.isEmpty, "the gate fault ended the process")

        rig.timeline.advance(by: WatchdogLimits.cycleBound - Self.pastTheBound + .nanoseconds(1))
        rig.tickTwice()

        #expect(rig.exitsNow == [.blind], "nothing ended a helper whose gate never turned")
        #expect(rig.log.faults.count == 2, "\(rig.log.faults)")
        #expect(rig.log.faults.last?.contains("safety-cycle trigger") == true)
    }

    /// A verdict outranks a gate fault that is due on the same tick. § 3 has stalled past D_cycle
    /// while a deep supervisor queue drains a turn a second, so every tick has a new overdue head
    /// and a gate fault due. The cycle trigger must still end the helper on the tick that
    /// confirms it (the second), not when the queue has run dry: a gate fault returned ahead of
    /// the verdict would put the ending off for as long as the queue keeps producing heads.
    ///
    /// The queue is twenty deep and loses one waiter a tick, so the old head is granted and a new,
    /// already overdue head takes its place on each. The verdict tick is read from the journal,
    /// not timed.
    ///
    /// **Mutation:** compute the gate faults first in the locked step of `tick()` and return
    /// `.gateFaults` whenever there are any, ahead of `if let confirmed`. Run: red — the ending
    /// comes on tick 21, once the queue is empty.
    @Test("A verdict outranks a gate fault due on the same tick")
    func aVerdictOutranksAGateFaultDueOnTheSameTick() {
        let rig = WatchdogRig()
        let script = GateScript(rig.gate)
        rig.progress.beginCycling()
        var queue = (0..<20).map { _ in script.park(.supervisor) }

        rig.timeline.advance(by: WatchdogLimits.cycleBound + .nanoseconds(1))
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1, "the first tick is the gate fault, not the verdict")
        #expect(rig.exitsNow.isEmpty)

        var endedOnTick: Int?
        for tick in 2...22 {
            if !queue.isEmpty { script.grant(queue.removeFirst()) }
            rig.timeline.advance(by: WatchdogLimits.tick)
            rig.watchdog.tick()
            if endedOnTick == nil, !rig.exitsNow.isEmpty { endedOnTick = tick }
        }

        #expect(endedOnTick == 2, "the verdict was put off to tick \(endedOnTick ?? -1)")
        #expect(rig.exitsNow == [.blind])
        #expect(rig.log.faults.last?.contains("safety-cycle trigger") == true)
    }

    // MARK: - What the line promises

    /// The line promises no more than the phase makes true. While § 3 runs, a gate that never turns
    /// starves it and the cycle trigger ends the helper. Before § 3 has started, the bring-up
    /// trigger does. Once the supervisors are stopped — the orderly teardown — neither is armed,
    /// nothing in the helper will end it for this, and the line says so; the process, in fact, is
    /// not ended however long it goes on.
    ///
    /// **Mutation:** say "If no safety cycle completes for …, the cycle trigger ends the helper"
    /// in every phase (the unconditional wording). Run: red — the stopped and bring-up lines.
    /// **Mutation:** swap the `.cycling` and `.bringUp` wording. Run: red.
    @Test("The gate fault promises no more than the phase makes true")
    func theGateFaultPromisesOnlyWhatThePhaseMakesTrue() {
        func line(in phase: ThermalCycleProgress.Phase) -> (line: String, rig: WatchdogRig) {
            let rig = WatchdogRig()
            switch phase {
            case .cycling: rig.progress.beginCycling()
            case .bringUp: rig.progress.beginBringUp()
            case .disarmed:
                rig.progress.beginCycling()
                rig.progress.endCycling()
            }
            GateScript(rig.gate).park(.supervisor)
            rig.timeline.advance(by: WatchdogLimits.gateWaiterAlarm + .seconds(1))
            rig.watchdog.tick()
            return (rig.log.faults.first ?? "", rig)
        }

        let cycling = line(in: .cycling).line
        #expect(cycling.contains("the cycle trigger ends the helper"), "\(cycling)")
        #expect(cycling.contains("for 15.000 s"), "\(cycling)")
        #expect(!cycling.contains("bring-up trigger"), "\(cycling)")

        let bringUp = line(in: .bringUp).line
        #expect(bringUp.contains("the bring-up trigger ends the helper"), "\(bringUp)")
        #expect(!bringUp.contains("cycle trigger ends the helper"), "\(bringUp)")

        let (stopped, rig) = line(in: .disarmed)
        #expect(stopped.contains("the cycle trigger is not armed"), "\(stopped)")
        #expect(stopped.contains("nothing will end the helper for this"), "\(stopped)")
        #expect(!stopped.contains("trigger ends the helper"), "\(stopped)")
        // And it is true: a stopped supervisor is not a stall, and no tick ends the process.
        for _ in 0..<120 {
            rig.timeline.advance(by: WatchdogLimits.tick)
            rig.watchdog.tick()
        }
        #expect(rig.exitsNow.isEmpty, "the line says nothing ends the helper, and something did")
    }

    // MARK: - Against the real scheduler

    /// #135's own scenario, against the real scheduler: a provider that never returns the turn
    /// it was given. The read that took it is parked at the provider for good, and a second read
    /// queues behind it at the gate. Past G, the watchdog logs the one `.fault`, naming the
    /// priority of the read that is waiting, and ends nothing.
    ///
    /// The turn is released at the end so the test can finish, and the waiter's grant is what the
    /// mirror hears: nothing is left parked and nothing more is logged however long the process
    /// goes on.
    ///
    /// **Mutation:** delete the `log.gateWaiter(…)` call in `LivenessWatchdog.tick()`. Run: red.
    /// **Mutation:** ignore `turnGranted` in `GateWaitMonitor.schedulerDidObserve(_:)`. Run: red
    /// — the served waiter is still in the mirror.
    @Test("A provider that never returns faults the read parked behind it")
    func aProviderThatNeverReturnsFaultsTheReadParkedBehindIt() async throws {
        let rig = WatchdogRig()
        let provider = GatedSensorProvider(holdingSubsetReads: true)
        let scheduler = SMCReadScheduler(provider: provider, observer: rig.gate)

        let stuck = observing { try await scheduler.read(keys: ["S0"], at: .snapshot) }
        await yieldUntil("the first read to reach the provider") {
            await provider.turns.count == 1
        }
        let behind = observing { try await scheduler.read(keys: ["T0"], at: .supervisor) }
        await yieldUntil("the supervisor read to be queued behind it") {
            await scheduler.queuedTurns(at: .supervisor) == 1
        }

        rig.timeline.advance(by: Self.pastTheBound)
        rig.watchdog.tick()
        rig.timeline.advance(by: .seconds(1))
        rig.watchdog.tick()

        #expect(rig.log.faults.count == 1, "\(rig.log.faults)")
        let line = rig.log.faults.first ?? ""
        #expect(line.contains("priority supervisor"), "\(line)")
        #expect(line.contains("1 waiting at that priority"), "\(line)")
        #expect(rig.exitsNow.isEmpty, "a parked waiter ended the process")

        // The turn comes back and the waiter is served: the mirror forgets it.
        await provider.releaseEveryTurn()
        _ = try await finished("the read that held the turn", stuck)
        _ = try await finished("the read that was parked behind it", behind)
        #expect(rig.gate.oldestParked().isEmpty, "a served waiter is still in the mirror")

        rig.timeline.advance(by: .seconds(30))
        rig.watchdog.tick()
        #expect(rig.log.faults.count == 1)
    }
}
