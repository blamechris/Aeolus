import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// The liveness watchdog's round-trip trigger (ADR 0012 I4, I5), driven by hand.
///
/// Time is a `WatchdogTimeline` the test moves, ticks are `tick()` calls the test makes, and
/// the process ends into a journal — so nothing here waits on a clock, and nothing can end
/// `swift test`. A round trip "that has not returned" is a real parked thread where the test is
/// about being wedged, and a bracket the test is standing inside where it is about ages.
///
/// Every test names the mutation that must turn it red; each was run, and the table is on the
/// pull request.
@Suite("The liveness watchdog's round-trip trigger", .timeLimit(.minutes(1)))
struct LivenessWatchdogTests {

    // MARK: - A wedge ends the process

    /// A round trip that is out for longer than D, seen on two consecutive ticks, logs one
    /// `.fault` and ends the process with the exit code launchd reads as "restart me".
    ///
    /// **Mutation:** delete the `Task { await termination.end(.blind) }` in
    /// `LivenessWatchdog.tick()`. Run: red — the fault is logged and the process never ends.
    /// **Mutation:** map `.blind` to `0` in `TeardownOutcome.exitCode`. Run: red — the
    /// process ends, and with the code that tells launchd not to restart it.
    @Test("A round trip that does not return ends the process, non-zero")
    func aWedgedRoundTripEndsTheProcessNonZero() async {
        let rig = WatchdogRig()
        let wedge = WedgedRoundTrip(rig.monitor, tpd0)
        defer { wedge.finish() }
        guard wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            return
        }

        rig.timeline.advance(by: .seconds(6))
        rig.tickTwice()

        #expect(await rig.waitForExit())
        #expect(await exits(of: rig.journal) == [.blind])
        #expect(TeardownOutcome.blind.exitCode == 2, "the exit code the restart policy reads")
        #expect(
            TeardownOutcome.blind.exitCode != 0,
            "a zero exit tells launchd the helper finished cleanly, and it is not restarted")
        #expect(rig.log.faults.count == 1)
    }

    /// The `.fault` is the last line the dying process writes, and the first one a person
    /// reads after the restart. It names the operation, the **raw** key beside its four
    /// characters, the selector, the sequence number and the age.
    ///
    /// **Mutation:** pass the stamp's operation as `.open` in the verdict. Run: red.
    @Test("The fault names the operation, the raw key, the selector and the age")
    func theFaultNamesTheRoundTrip() {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
            rig.timeline.advance(by: .seconds(1))
            rig.watchdog.tick()
        }

        let faults = rig.log.faults
        #expect(faults.count == 1)
        let line = faults.first ?? ""
        #expect(line.contains("an SMC round trip has not returned"), "\(line)")
        #expect(line.contains("an SMC call, key"), "\(line)")
        // The raw code beside its characters: a label alone could be wrong.
        #expect(line.contains("'TPD0' (0x54504430)"), "\(line)")
        #expect(line.contains("selector 5"), "\(line)")
        #expect(line.contains("round trip #1"), "\(line)")
        // The age at the verdict: six seconds on the first tick, seven on the second.
        #expect(line.contains("7.000 s"), "\(line)")
        #expect(line.contains("bound of 5.000 s"), "\(line)")
        #expect(line.contains("exit code 2"), "\(line)")
        #expect(rig.log.lines.last?.level == .fault, "a verdict is a fault, not a notice")
    }

    /// `IOServiceOpen` and `IOServiceClose` are stamped as well (a reconnect runs them), and a
    /// `READ_INDEX` call carries key zero, which is not a key: the line says so rather than
    /// printing four NULs.
    ///
    /// **Mutation:** render every operation as a `.call`. Run: red.
    @Test("An open, a close and an index read are each named as what they are")
    func everyOperationIsNamed() {
        let cases: [(SMCRoundTripOperation, String)] = [
            (.open, "opening the SMC connection"),
            (.close, "closing the SMC connection"),
            (.call(key: 0, selector: 8), "0x00000000 (no key: an index read), selector 8"),
        ]
        for (operation, expected) in cases {
            let rig = WatchdogRig()
            rig.monitor.bracket(operation) {
                rig.timeline.advance(by: .seconds(6))
                rig.tickTwice()
            }
            #expect(
                rig.log.faults.first?.contains(expected) == true,
                "\(operation): \(rig.log.faults)")
        }
    }

    /// One verdict is one `.fault` and one request to end the process. `fired` is set inside
    /// the locked step that decides it, so a tick after the verdict does nothing.
    ///
    /// **Mutation:** never set `fired`. Run: red — every further tick logs another fault and
    /// asks to end the process again.
    @Test("A verdict is one fault and one request, however many ticks follow")
    func aVerdictIsReachedOnce() async {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            for _ in 0..<6 { rig.watchdog.tick() }
        }

        #expect(rig.log.faults.count == 1)
        #expect(await rig.waitForExit())
        #expect(await exits(of: rig.journal) == [.blind])
        // The termination's own claim would hide a second request from the journal, so the
        // fault count is the evidence that the watchdog asked once.
        #expect(rig.log.lines(containing: "already ending").isEmpty)
    }

    // MARK: - What is not a wedge

    /// A busy connection is not a wedged one. Round trips follow one another without a gap,
    /// so a stamp is in flight on every tick — and each is a different round trip with an age
    /// of its own. Age is the stamp's own start, never "the connection has been busy since".
    ///
    /// **Mutation:** measure the age from the first tick that found a stamp (a "busy since"
    /// reading) instead of from the stamp's own start. Run: red — the sixth tick of an
    /// unbroken run of short calls ends the process.
    @Test("Continuous short round trips never trip the watchdog")
    func continuousShortRoundTripsNeverTrip() async {
        let rig = WatchdogRig()

        // 120 ticks, 0.5 s apart — a minute of back-to-back calls, with a stamp in flight on
        // every one of them and no stamp older than half a second.
        for _ in 0..<120 {
            rig.monitor.bracket(tpd0) {
                rig.timeline.advance(by: .milliseconds(500))
                rig.watchdog.tick()
            }
        }

        #expect(rig.log.faults.isEmpty)
        #expect(await rig.endedAfterSettling() == false)
    }

    /// One observation past the bound is not a verdict. A round trip that was slow and then
    /// came back — a legal tail, not a wedge — is seen once and forgotten.
    ///
    /// **Mutation:** act on the first over-bound tick (`>= 1` where the streak is compared
    /// with `ticksPerVerdict`). Run: red.
    @Test("A stamp seen past the bound once is not a verdict")
    func anOverBoundStampSeenOnceIsNotAVerdict() async {
        let rig = WatchdogRig()

        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
        }
        // It returned. Whatever comes next is a new round trip.
        rig.watchdog.tick()
        rig.watchdog.tick()

        #expect(rig.log.faults.isEmpty)
        #expect(await rig.endedAfterSettling() == false)
    }

    /// Two different round trips, each past the bound on one tick, are not one wedge. The
    /// rule is the *same* sequence on consecutive ticks.
    ///
    /// **Mutation:** key the streak on "some round trip is over the bound" rather than on the
    /// sequence number. Run: red.
    @Test("Two different slow round trips on consecutive ticks are not a verdict")
    func twoDifferentSlowRoundTripsAreNotOneWedge() async {
        let rig = WatchdogRig()

        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
        }
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
        }

        #expect(rig.monitor.issuedCount == 2, "the scenario did not issue two round trips")
        #expect(rig.log.faults.isEmpty)
        #expect(await rig.endedAfterSettling() == false)
    }

    // MARK: - Arming

    /// `arm()` starts the tick source once and starts the bring-up bound once. A second call
    /// must not restart either: a bring-up that had stalled for ten seconds would get another
    /// fifteen.
    ///
    /// It also says so, once, so that a log which ends without a verdict can be told apart from
    /// one whose watchdog never started.
    ///
    /// **Mutation:** delete the `isArmed` guard in `arm()`. Run: red.
    /// **Mutation:** delete `log.armed()` from `arm()`. Run: red.
    @Test("Arming twice neither restarts the timer nor resets the bring-up bound")
    func armingIsIdempotent() async {
        let rig = WatchdogRig()

        await rig.watchdog.arm()
        rig.timeline.advance(by: .seconds(10))
        await rig.watchdog.arm()
        rig.timeline.advance(by: .seconds(6))

        #expect(rig.ticks.startCount == 1)
        #expect(rig.log.lines(containing: "Liveness watchdog armed").count == 1)
        rig.tickTwice()
        #expect(rig.log.faults.count == 1, "the second arm() gave the bring-up a fresh bound")
    }

    /// A second request to end the process is refused and says so, and the first outcome
    /// stands. The refusal is a notice and not a fault: the process is already on its way out.
    ///
    /// **Mutation:** remove the first-wins return in `ProcessTermination.end`. Run: red — the
    /// journal holds two endings. **Mutation:** delete the `log.terminationAlreadyClaimed(…)`
    /// call. Run: red — the refusal is silent.
    @Test("A second request to end the process is refused, and logged")
    func aSecondRequestToEndTheProcessIsRefused() async {
        let rig = WatchdogRig()

        await rig.termination.end(.restored)
        await rig.termination.end(.blind)

        #expect(await exits(of: rig.journal) == [.restored])
        let refusals = rig.log.lines(containing: "already ending as restored")
        #expect(refusals.count == 1)
        #expect(refusals.first?.level == .notice)
        #expect(refusals.first?.message.contains("blind") == true)
    }

    /// The handler the timer is given is the watchdog's own tick: firing the source is what
    /// produces a verdict, with no other path from the timer to the decision.
    ///
    /// **Mutation:** register an empty handler in `arm()`. Run: red.
    @Test("The timer's handler is the watchdog's tick")
    func theTimerDrivesTheWatchdog() async {
        let rig = WatchdogRig()
        await rig.watchdog.arm()
        #expect(rig.ticks.isRunning)

        rig.timeline.advance(by: .seconds(16))
        rig.ticks.fire()
        rig.ticks.fire()

        #expect(rig.log.faults.count == 1)
        #expect(await rig.waitForExit())
    }
}
