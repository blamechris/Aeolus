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
            \(Self.seconds(WatchdogLimits.bringUpBound)) until the supervisors start), on two \
            consecutive \(Self.seconds(WatchdogLimits.tick)) ticks, ends the helper.
            """)
    }

    /// The verdict. One line, one `.fault`, and then the process ends.
    ///
    /// A round trip names its operation, raw key, selector and age. A stalled cycle or
    /// bring-up names the trigger, the phase, the age since the last completion, the
    /// completion count, and whether a stamp is in flight and what it is — the stamp is
    /// evidence either way: a stalled cycle with a round trip in flight is a different
    /// diagnosis from one with none.
    func verdict(_ verdict: WatchdogVerdict) {
        let consequence = """
            Ending the helper with exit code \(TeardownOutcome.blind.exitCode) and no orderly \
            teardown: launchd restarts it, and startup reconciliation restores automatic \
            control.
            """
        switch verdict.trigger {
        case .roundTrip:
            let stamp = verdict.stamp.map(Self.describe) ?? "a round trip that has since ended"
            emit(
                .fault,
                """
                Liveness watchdog: an SMC round trip has not returned. \(stamp), in flight for \
                \(Self.seconds(verdict.age)) against a bound of \(Self.seconds(verdict.bound)), \
                seen on two consecutive ticks. \(consequence)
                """)
        case .bringUp, .cycle:
            let name = verdict.trigger == .bringUp ? "bring-up" : "safety-cycle"
            let phase = verdict.progress.phase == .bringUp ? "bring-up" : "cycling"
            let stamp =
                verdict.stamp.map { "A stamp is in flight: \(Self.describe($0))." }
                ?? "No stamp is in flight."
            emit(
                .fault,
                """
                Liveness watchdog: the \(name) trigger fired in the \(phase) phase. No safety \
                cycle has completed for \(Self.seconds(verdict.age)) against a bound of \
                \(Self.seconds(verdict.bound)), with \(verdict.progress.completions) \
                completion(s) so far, seen on two consecutive ticks. \(stamp) \(consequence)
                """)
        }
    }

    /// A second request to end the process, refused because the first already holds the
    /// claim. Not a fault: the process is already on its way out, and this says so.
    func terminationAlreadyClaimed(by first: TeardownOutcome, refused second: TeardownOutcome) {
        emit(
            .notice,
            """
            The process is already ending as \(first); a second request to end it as \(second) \
            was ignored. The first request to end the process wins.
            """)
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
