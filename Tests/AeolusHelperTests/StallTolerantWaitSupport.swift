import Foundation
import Testing

/// Expects exactly one issue, whose text holds every fragment.
///
/// An issue that does not match is not "known": it fails the test as itself, so a wrong
/// message reads as a wrong message and not as a missing one.
func expectTimeout(
    saying fragments: String...,
    waitedUnder limit: Double? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async throws {
    try await withKnownIssue(sourceLocation: sourceLocation) {
        try await body()
    } matching: { issue in
        let said = fragments.allSatisfy { fragment in
            issue.comments.contains { $0.rawValue.contains(fragment) }
        }
        guard said, let limit else { return said }
        return waitedSeconds(in: issue).map { $0 < limit } ?? false
    }
}

/// The scheduled waiting time a timeout reports, in seconds: the figure the message gives
/// before " s of waiting". It excludes whatever was compensated, so a bound on it holds on
/// a stalled runner.
func waitedSeconds(in issue: Issue) -> Double? {
    for comment in issue.comments {
        let text = comment.rawValue
        guard let lead = text.range(of: "timed out after ") else { continue }
        let rest = text[lead.upperBound...]
        guard let end = rest.range(of: " s of waiting") else { continue }
        return Double(rest[..<end.lowerBound])
    }
    return nil
}

/// Runs the wait and answers the notes it wrote, which are otherwise standard error.
///
/// Also how a test whose stall is simulated keeps the note out of the CI log, where a line
/// saying a wait compensated 27.3 s would read as a real finding.
@discardableResult
func waitCollectingNotes(
    _ what: String, on clock: VirtualWaitClock, until condition: () async -> Bool
) async throws -> [String] {
    var written: [String] = []
    try await waitUntil(what, clock: clock, note: { written.append($0) }, condition)
    return written
}

/// A clock the test moves, whose sleeps can come back late.
///
/// Late is the whole point: `TestClock` jumps to the deadline it is asked for, so it cannot
/// show a poll a sleep that took longer than it was told to. This one advances by the interval
/// **plus** what `lateness` says that sleep (numbered from 1) was delayed by. Nothing here
/// sleeps for real, so a 27 s stall costs microseconds and no cooperative-pool thread is ever
/// blocked.
///
/// An `actor`, as the `WaitClock` members are `async` to allow. It yields once per sleep so a
/// poll driven by it still gives other tasks a chance to run, and so a suite `.timeLimit` can
/// land on a poll that has stopped making progress.
actor VirtualWaitClock: WaitClock {

    private let origin: ContinuousClock.Instant
    private var instant: ContinuousClock.Instant
    private let lateness: @Sendable (Int) -> Duration
    private var stalledAt: Set<Int> = []

    /// How many sleeps have been asked for.
    private(set) var sleeps = 0

    init(
        start: ContinuousClock.Instant = ContinuousClock.now,
        lateness: @escaping @Sendable (Int) -> Duration = { _ in .zero }
    ) {
        origin = start
        instant = start
        self.lateness = lateness
    }

    /// How far the clock has moved.
    var elapsed: Duration { instant - origin }

    func now() -> ContinuousClock.Instant { instant }

    func sleep(for interval: Duration) async throws {
        sleeps += 1
        instant = instant.advanced(by: interval + lateness(sleeps))
        await Task.yield()
        // After the advance, so a wait that swallowed the cancellation would still move
        // on the clock and end by its budget rather than spin where it stood.
        try Task.checkCancellation()
    }

    /// Stops the process for `duration`, once, when exactly `count` sleeps have been asked
    /// for — the stall landing in whatever runs between two polls, which is the condition.
    func stall(for duration: Duration, atSleep count: Int) {
        guard sleeps == count, stalledAt.insert(count).inserted else { return }
        instant = instant.advanced(by: duration)
    }
}
