import Foundation
import SMCCore
import os

/// What the liveness watchdog says, and the one line that matters: why it ended the process.
///
/// Its own category, because it answers a question no other log does: *"why did the helper
/// restart?"*. A verdict ends the process, so this line is the last thing the dying process
/// writes and the first thing a person reading `log show` after the restart needs. It names
/// the raw SMC key beside everything it says about a round trip: a label that was wrong would
/// send someone looking at the wrong sensor, and the raw code cannot be wrong about what was
/// sent (`CLAUDE.md`: always show the raw SMC key).
///
/// Shaped after `SafetyLog` — one private `emit`, a level that a recording sink receives —
/// and not added to it, because `SafetyLog` is the safety subsystem's vocabulary and this is
/// the process's. The level travels to the sink for `SafetyLog.init(recording:)`'s reason: a
/// verdict that could be demoted to a notice with the whole suite green is a claim no test
/// can check.
struct WatchdogLog: Sendable {

    enum Level: Sendable, Hashable {
        /// Persisted by default.
        case notice
        /// The watchdog ended, or tried to end, the process.
        case fault
    }

    private let emit: @Sendable (Level, String) -> Void

    init(subsystem: String = "dev.aeolus.AeolusHelper", category: String = "Watchdog") {
        let logger = Logger(subsystem: subsystem, category: category)
        emit = { level, message in
            switch level {
            case .notice: logger.notice("\(message, privacy: .public)")
            case .fault: logger.fault("\(message, privacy: .public)")
            }
        }
    }

    /// A sink a test can read back, level included.
    init(recording sink: @escaping @Sendable (Level, String) -> Void) {
        emit = sink
    }

    // MARK: - Lines

    /// The watchdog is running. Said once, so a log that ends without a verdict can be told
    /// apart from one whose watchdog never started.
    func armed() {
        emit(
            .notice,
            """
            Liveness watchdog armed: a round trip in flight for longer than \
            \(Self.seconds(WatchdogLimits.roundTrip)), or no completed safety cycle for longer \
            than \(Self.seconds(WatchdogLimits.cycleBound)) (\
            \(Self.seconds(WatchdogLimits.bringUpBound)) until the supervisors start), on \
            \(Self.consecutiveTicks), ends the helper. A read parked at the scheduler's gate \
            for longer than \(Self.seconds(WatchdogLimits.gateWaiterAlarm)) is logged as a \
            fault and nothing more.
            """)
    }

    /// The verdict, when this watchdog holds the claim on ending the process and is about to
    /// end it. One line, one `.fault`.
    ///
    /// A round trip names its operation, raw key, selector and age. A stalled cycle or
    /// bring-up names the trigger, the phase, the age since the last completion, the
    /// completion count, and whether a stamp is in flight and what it is — the stamp is
    /// evidence either way: a stalled cycle with a round trip in flight is a different
    /// diagnosis from one with none.
    ///
    /// **It promises a restart no further than the truth.** launchd restarts a job it is
    /// keeping alive, and only then does a reconciliation pass run; its first read goes to the
    /// same driver, so a wedge that outlives the restart ends the next process the same way and
    /// nothing is restored until the driver answers. Where launchd is itself stopping the job —
    /// `launchctl bootout`, `SMAppService.unregister()`, shutdown — it does not restart it.
    func verdict(_ verdict: WatchdogVerdict) {
        emit(
            .fault,
            """
            \(Self.facts(of: verdict)) Ending the helper now with exit code \
            \(TeardownOutcome.blind.exitCode) and no orderly teardown. launchd restarts a job it \
            is keeping alive, and the next process's startup reconciliation then restores \
            automatic control if its pass reaches its keystone. A wedge that outlives the restart \
            ends that process the same way, and nothing is restored until the driver answers. \
            Where launchd is removing or stopping the job it does not restart it.
            """)
    }

    /// A read has been parked at the scheduler's gate for longer than G (ADR 0012's third
    /// trigger, [#135](https://github.com/blamechris/Aeolus/issues/135)). One line, one
    /// `.fault`, for one waiter: the priority it queued at, how long the oldest waiter there has
    /// waited, and how many are parked behind that gate.
    ///
    /// **A report and nothing more, and it says so.** The gate is not cancellable and nothing
    /// here resumes or drops a waiter. This line does not end the helper, and it promises no more
    /// than the phase makes true: while § 3 runs, a gate that never turns starves it and the
    /// cycle trigger ends the helper; before it has started, the bring-up trigger does; once it
    /// is stopped (the orderly teardown), neither is armed and the line says that nothing will.
    ///
    /// `stamp` is the round trip in flight at the tick, if any, as evidence: it was not older
    /// than one tick (an older one suppresses this line), so it does not explain the wait, and
    /// the raw key it names is shown beside it.
    func gateWaiter(
        _ wait: GateWait, stamp: SMCRoundTripInFlight?, phase: ThermalCycleProgress.Phase
    ) {
        let waited = Self.seconds(wait.age)
        let bound = Self.seconds(WatchdogLimits.gateWaiterAlarm)
        let consequence: String
        switch phase {
        case .cycling:
            consequence = """
                If no safety cycle completes for \(Self.seconds(WatchdogLimits.cycleBound)), \
                the cycle trigger ends the helper.
                """
        case .bringUp:
            consequence = """
                The supervisors have not started: if no safety cycle completes within \
                \(Self.seconds(WatchdogLimits.bringUpBound)) of arming, the bring-up trigger ends \
                the helper.
                """
        case .disarmed:
            consequence = """
                The safety supervisors are stopped, so the cycle trigger is not armed and nothing \
                will end the helper for this; only the round-trip trigger is armed.
                """
        }
        let inFlight =
            stamp.map {
                "A round trip is in flight but is not older than one tick: \(Self.describe($0))."
            } ?? "No round trip is in flight."
        emit(
            .fault,
            """
            Liveness watchdog: a read has been parked at the scheduler's gate for \(waited) \
            against a bound of \(bound): priority \(wait.priority), \(wait.depth) waiting at \
            that priority. \(inFlight) A turn that was taken and not given back looks exactly \
            like this, and so does a queue longer than the one G was sized for. This is a \
            report: the watchdog does not end the helper for it, and nothing in the helper \
            resumes or drops the waiting read. \(consequence)
            """)
    }

    /// The verdict, when something else already holds the claim on ending the process: the
    /// orderly teardown reached its last step first. The wedge is as real as it was, so this is
    /// still a `.fault`; what it must not do is say the helper is ending because of it, or that
    /// anything will restart it.
    func verdictNotEnding(_ verdict: WatchdogVerdict, alreadyEndingAs holder: TeardownOutcome) {
        emit(
            .fault,
            """
            \(Self.facts(of: verdict)) The process is already ending as \(holder), so this \
            verdict does not end it and promises no restart: if that ending is itself held up by \
            the wedge, nothing in the helper will end the process.
            """)
    }

    /// A second request to end the process, refused because the first already holds the
    /// claim, and who holds it. Not a fault: the process is already on its way out.
    func terminationAlreadyClaimed(by holder: TeardownOutcome, refused second: TeardownOutcome) {
        emit(
            .notice,
            """
            The process is already ending as \(holder); a second request to end it as \(second) \
            was ignored. The first request to end the process wins.
            """)
    }

    /// What was found, for either verdict line.
    private static func facts(of verdict: WatchdogVerdict) -> String {
        switch verdict.trigger {
        case .roundTrip:
            let stamp = verdict.stamp.map(describe) ?? "a round trip that has since ended"
            return """
                Liveness watchdog: an SMC round trip has not returned. \(stamp), in flight for \
                \(seconds(verdict.age)) against a bound of \(seconds(verdict.bound)), seen on \
                \(consecutiveTicks).
                """
        case .bringUp, .cycle:
            let name = verdict.trigger == .bringUp ? "bring-up" : "safety-cycle"
            let phase = verdict.progress.phase == .bringUp ? "bring-up" : "cycling"
            let stamp =
                verdict.stamp.map { "A stamp is in flight: \(describe($0))." }
                ?? "No stamp is in flight."
            return """
                Liveness watchdog: the \(name) trigger fired in the \(phase) phase. No safety \
                cycle has completed for \(seconds(verdict.age)) against a bound of \
                \(seconds(verdict.bound)), with \(verdict.progress.completions) completion(s) \
                so far, seen on \(consecutiveTicks). \(stamp)
                """
        }
    }

    /// "2 consecutive ticks", from the constant that decides it: the line states the rule the
    /// code applies, and cannot go on saying "two" after the constant moves.
    private static var consecutiveTicks: String {
        "\(WatchdogLimits.ticksPerVerdict) consecutive ticks"
    }

    // MARK: - Rendering

    /// A stamp as a person reads it: the operation, and for a call the key as the four
    /// characters the wire carried **and** as the raw code, then the selector and the
    /// sequence number.
    ///
    /// The IOKit entry points are not named here, deliberately: `RoundTripStampTripwireTests`
    /// counts every occurrence of those names under `Sources/`, string literals included, and
    /// this is a log line, not a call.
    static func describe(_ stamp: SMCRoundTripInFlight) -> String {
        switch stamp.operation {
        case .open:
            return "opening the SMC connection (round trip #\(stamp.sequence))"
        case .close:
            return "closing the SMC connection (round trip #\(stamp.sequence))"
        case .call(let key, let selector):
            return """
                an SMC call, key \(render(key)), selector \(selector) \
                (round trip #\(stamp.sequence))
                """
        }
    }

    /// `'TPD0' (0x54504430)` for a printable code, and `0x00000000 (no key: an index read)`
    /// for zero. The hexadecimal is always present, so a code that is not four printable
    /// characters is still shown exactly.
    static func render(_ key: FourCharCode) -> String {
        let hex = "0x" + String(format: "%08X", key)
        if key == 0 { return "\(hex) (no key: an index read)" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: key >> $0) }
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        guard printable else { return hex }
        return "'\(String(decoding: bytes, as: UTF8.self))' (\(hex))"
    }

    static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return String(format: "%.3f s", value)
    }
}
