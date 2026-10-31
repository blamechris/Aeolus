import os

// The vocabulary `HelperLog` writes in: its levels, the one mapping from a level to the unified
// log's, and what § 7's machine-wide restore did. The lines themselves stay in `HelperLog.swift`
// beside `emit`, the one private route that writes them.

extension HelperLog {

    /// How loud a line is.
    ///
    /// Every line names one, and `emit` hands that one value both to the unified log, through
    /// `osLogType(for:)`, and to a test's sink. So the level a test reads back is the level that
    /// was written, and the two cannot come to differ. Until the review of #349 the sink carried a
    /// level tag beside a separate `log.fault(...)`, and demoting the real call left every test
    /// green.
    enum Level: Sendable, Hashable, CaseIterable {
        /// Not persisted by default. What a repeat of an already-reported condition costs.
        case debug
        /// Not persisted by default: the mechanism working as designed.
        case info
        /// Persisted: what an operator reading afterwards should find.
        case notice
        /// Persisted, and the level an operator goes looking at.
        case error
        /// The helper could not do what the line names, and fans may be off automatic control.
        case fault
    }

    /// The unified log's type for each level — the one mapping, so a demoted fault is a red test
    /// rather than a change nobody can observe: `Logger` writes nowhere a test can read.
    /// `Logger.notice` is `.default`.
    static func osLogType(for level: Level) -> OSLogType {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }

    /// What § 7's machine-wide restore did, for the line that closes the panic path.
    enum MachineWideRestore: Sendable, Hashable {
        /// Not issued, because the plane reports no SMC write path: asked, not assumed.
        case noWritePath
        /// Not issued, by an authority that issues none whatever its plane can do.
        case notIssued
        /// The firmware accepted it. Accepted is not automatic.
        case accepted
        /// It threw, and `panicRestoreRefused(connection:detail:)` has said so at fault level.
        case refused
    }
}
