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
    /// The ending is **synchronous**: it has happened by the time the second `tick()` returns,
    /// on the thread that called it, with no hand-off to the cooperative pool that could be
    /// parked.
    ///
    /// **Mutation:** delete the `ending.end()` in `LivenessWatchdog.tick()`. Run: red — the
    /// fault is logged and the process never ends.
    /// **Mutation:** map `.blind` to `0` in `TeardownOutcome.exitCode`. Run: red — the
    /// process ends, and with the code that tells launchd not to restart it.
    @Test("A round trip that does not return ends the process, non-zero")
    func aWedgedRoundTripEndsTheProcessNonZero() async {
        let rig = WatchdogRig()
        let wedge = WedgedRoundTrip(rig.monitor, tpd0)
        defer { wedge.finish() }
        guard await wedge.waitUntilWedged() else {
            Issue.record("the round trip never began")
            return
        }

        rig.timeline.advance(by: .seconds(6))
        rig.tickTwice()

        #expect(rig.exitsNow == [.blind], "the terminate seam is called once, with .blind")
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

    /// The line states the rule the code applies, derived from the constant that decides it,
    /// and promises a restart and a restoration no further than they are true: a wedge that
    /// outlives the restart ends the next process too, and a job launchd is stopping is not
    /// restarted at all.
    ///
    /// The tick count is read from `WatchdogLimits.ticksPerVerdict` in the log, and compared
    /// with it here; that it is *derived* and not merely equal today is a property of one line
    /// of `WatchdogLog`, not something a test can distinguish while the constant is 2.
    ///
    /// **Mutation:** restore the sentence "launchd restarts it, and startup reconciliation
    /// restores automatic control". Run: red.
    @Test("The fault promises no more restart than there is")
    func theFaultDoesNotOverpromise() {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.tickTwice()
        }

        let line = rig.log.faults.first ?? ""
        #expect(
            line.contains("seen on \(WatchdogLimits.ticksPerVerdict) consecutive ticks"),
            "\(line)")
        #expect(line.contains("restarts a job it is keeping alive"), "\(line)")
        #expect(line.contains("if its pass reaches its keystone"), "\(line)")
        #expect(!line.contains("if its first read returns"), "\(line)")
        #expect(line.contains("nothing is restored until the driver answers"), "\(line)")
        #expect(line.contains("it does not restart it"), "\(line)")
        #expect(
            !line.contains("restores automatic control."),
            "the line promises a restoration unconditionally: \(line)")
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
    /// calls the terminate seam again.
    @Test("A verdict is one fault and one request, however many ticks follow")
    func aVerdictIsReachedOnce() {
        let rig = WatchdogRig()
        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            for _ in 0..<6 { rig.watchdog.tick() }
        }

        #expect(rig.log.faults.count == 1)
        // The terminate seam was called once, and nothing was refused: with no hand-off there
        // is no second request in flight that a later tick could have raced.
        #expect(rig.exitsNow == [.blind])
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
    func continuousShortRoundTripsNeverTrip() {
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
        #expect(rig.exitsNow.isEmpty)
    }

    /// One observation past the bound is not a verdict. A round trip that was slow and then
    /// came back — a legal tail, not a wedge — is seen once and forgotten.
    ///
    /// **Mutation:** act on the first over-bound tick (`>= 1` where the streak is compared
    /// with `ticksPerVerdict`). Run: red.
    @Test("A stamp seen past the bound once is not a verdict")
    func anOverBoundStampSeenOnceIsNotAVerdict() {
        let rig = WatchdogRig()

        rig.monitor.bracket(tpd0) {
            rig.timeline.advance(by: .seconds(6))
            rig.watchdog.tick()
        }
        // It returned. Whatever comes next is a new round trip.
        rig.watchdog.tick()
        rig.watchdog.tick()

        #expect(rig.log.faults.isEmpty)
        #expect(rig.exitsNow.isEmpty)
    }

    /// Two different round trips, each past the bound on one tick, are not one wedge. The
    /// rule is the *same* sequence on consecutive ticks.
    ///
    /// **Mutation:** key the streak on "some round trip is over the bound" rather than on the
    /// sequence number. Run: red.
    @Test("Two different slow round trips on consecutive ticks are not a verdict")
    func twoDifferentSlowRoundTripsAreNotOneWedge() {
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
        #expect(rig.exitsNow.isEmpty)
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
        #expect(rig.exitsNow == [.blind])
    }
}
