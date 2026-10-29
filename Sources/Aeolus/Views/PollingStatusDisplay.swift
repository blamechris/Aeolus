import Foundation

/// Pure formatter for "what should the freshness banner say", given a `PollingPhase` and
/// the last successful update.
///
/// Extracted from the view layer so the honesty behaviour `CLAUDE.md` rule 6 requires —
/// a stale or failed refresh must say so, never silently keep showing old data as though
/// it were current — is checkable by a unit test, not only by watching a live window.
enum PollingStatusDisplay {
    enum Severity: Equatable {
        /// Nothing is wrong: either polling has not started, is in flight with no prior
        /// failure, or the most recent tick succeeded.
        case normal
        /// The most recent tick failed. Whatever is currently on screen is stale (or, if
        /// nothing has ever succeeded, there is nothing to show at all).
        case warning
    }

    struct Text: Equatable {
        let message: String
        let severity: Severity
    }

    /// - Parameters:
    ///   - phase: The view model's current `PollingPhase`.
    ///   - lastUpdated: The view model's `lastUpdated`, `nil` until the first successful
    ///     tick.
    ///   - now: Injectable so tests are deterministic rather than racing the wall clock —
    ///     matches the `PollingClock` seam `PollingViewModel` itself uses.
    /// - Returns: The freshness message and its severity, for a `PollingStatusBanner`.
    static func text(phase: PollingPhase, lastUpdated: Date?, now: Date = Date()) -> Text {
        switch phase {
        case .notStarted:
            return Text(message: "Waiting for first reading…", severity: .normal)
        case .waitingForHelper:
            // The only marker that the readings on screen are not current, so it is a warning
            // whenever there are readings to qualify, and it never says "just now".
            guard let lastUpdated else {
                return Text(message: "Waiting for the helper's first snapshot…", severity: .normal)
            }
            return Text(
                message:
                    "Waiting for the helper — the readings shown are from "
                    + elapsedWithoutJustNow(since: lastUpdated, now: now),
                severity: .warning)
        case .polling:
            guard let lastUpdated else {
                return Text(message: "Reading sensors…", severity: .normal)
            }
            return Text(
                message: "Refreshing — last updated \(elapsed(since: lastUpdated, now: now))",
                severity: .normal)
        case .ready:
            guard let lastUpdated else {
                // Unreachable in practice: PollingViewModel.tick() always sets
                // lastUpdated before phase becomes .ready. Handled rather than force-
                // unwrapped so a violated assumption renders an honest fallback message
                // instead of crashing the window.
                return Text(message: "Updated", severity: .normal)
            }
            return Text(
                message: "Updated \(elapsed(since: lastUpdated, now: now))", severity: .normal)
        case .failed(let error):
            guard let lastUpdated else {
                return Text(
                    message: "Refresh failed: \(failureReason(error)) — no reading yet",
                    severity: .warning)
            }
            return Text(
                message:
                    "Refresh failed: \(failureReason(error)) — showing the last reading from "
                    + elapsed(since: lastUpdated, now: now),
                severity: .warning)
        }
    }

    /// A failure's own words as a status line shows them: `PollingError.description` through
    /// `HelperAuthoredText.sanitised(_:)`, the app's one sanitiser (#544).
    ///
    /// The words can carry bytes the firmware declared. On the direct read path, a `#KEY`
    /// declaring a type this project does not recognise is described with its four-character
    /// code verbatim, and a code holding `0x0A` would put a raw line feed into the line. Shared
    /// with the menu bar's "Last refresh failed:" line, so the two show the same words.
    static func failureReason(_ error: PollingError) -> String {
        HelperAuthoredText.sanitised(error.description)
    }

    /// The whole of the menu bar's status line for a failed refresh: "Last refresh failed: "
    /// and the cleaned reason (#548).
    ///
    /// Built here rather than in the menu bar's view body so that a unit test sees the string
    /// the user reads. When the view interpolated `failureReason(_:)` itself, restoring
    /// `error.description` there left every test green. The view now displays this value and
    /// adds nothing to it.
    static func lastRefreshFailedLine(_ error: PollingError) -> String {
        "Last refresh failed: \(failureReason(error))"
    }

    /// `elapsed(since:now:)` without "just now", for readings that are being shown as not
    /// current: "just now" there would read as an all-clear.
    private static func elapsedWithoutJustNow(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        return seconds < 1 ? "less than a second ago" : elapsed(since: date, now: now)
    }

    private static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 1 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
