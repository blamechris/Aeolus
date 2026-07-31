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
                    message: "Refresh failed: \(error.description) — no reading yet",
                    severity: .warning)
            }
            return Text(
                message:
                    "Refresh failed: \(error.description) — showing the last reading from "
                    + elapsed(since: lastUpdated, now: now),
                severity: .warning)
        }
    }

    private static func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 1 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return "\(Int(seconds / 60))m ago"
    }
}
