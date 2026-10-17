import Foundation
import Testing

/// What a poll asks of a clock: the time, and a sleep.
///
/// A seam of its own rather than `MonotonicClock`, because the one thing the poll has to be
/// able to observe is a sleep that came back **late**, and `MonotonicClock.sleep(until:)` is
/// built so that the double can never be: `TestClock` jumps to the deadline. The members are
/// `async` so a double can be an `actor`, and there is no reason for any of this to be an
/// `@unchecked Sendable` class.
protocol WaitClock: Sendable {

    /// The current instant on the monotonic timeline.
    func now() async -> ContinuousClock.Instant

    /// Suspends for `interval`, or until the task is cancelled.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled. It is how a poll
    ///   inside a test whose `.timeLimit` expired stops, instead of running on to its ceiling.
    func sleep(for interval: Duration) async throws
}

/// The shipping clock: `ContinuousClock`, which keeps counting while the process is suspended
/// — the property the whole of `StallTolerantWait` rests on. A stall is visible to the poll
/// only because this clock went on without it.
struct SystemWaitClock: WaitClock {

    func now() async -> ContinuousClock.Instant { ContinuousClock.now }

    func sleep(for interval: Duration) async throws {
        try await ContinuousClock().sleep(for: interval)
    }
}

/// A poll whose budget counts only the time the waiter **ran**.
///
/// [#341](https://github.com/blamechris/Aeolus/issues/341): the poll used to measure its 5 s
/// on the wall clock. A CI runner stall of 20 to 30 s — which happened repeatedly across
/// unrelated branches on 2026-10-16 and 17 — then spent every 5 s wait at once, and a dozen
/// correct tests failed in the same second, indistinguishably from a client defect.
///
/// ## How the budget is kept
///
/// Each iteration schedules one `interval` of sleeping. When the iteration, condition
/// included, took longer than that by more than ``stallThreshold``, the process was not
/// running for the difference, and the difference is added to the deadline. What a wait asks
/// for with `timeout:` is therefore scheduled waiting time and not wall time, which is the
/// only reading under which it can mean the same thing on a quiet laptop and a stalled
/// runner.
///
/// ## Why 250 ms
///
/// The threshold is what separates a stall from a slow poll. A 10 ms sleep that returns 250 ms
/// late is 25 times late, which scheduling jitter on a busy pool does not do and a descheduled
/// process does. Under the threshold the overrun is **not** compensated, so ordinary
/// slowness keeps costing the wait its budget as it always did. Over it, the cost of a wrong
/// guess is asymmetric: compensating too much only lets a genuinely failing wait run longer
/// before it fails, bounded by ``ceiling``, while compensating too little is the flake.
///
/// ## The ceiling, and why it is below a minute
///
/// Compensation must not let a broken test hang the suite, so the total is capped at
/// ``ceiling``. It is 50 s, under the 60 s that is the **smallest** `.timeLimit` Swift Testing
/// can express — `TimeLimitTrait` takes minutes — so the cap fires, and says "cap hit", before
/// the suite's own limit can fire with a message that says nothing about why. And if a limit
/// does expire first, the clock's `sleep` throws on cancellation and the poll ends with it: the
/// ceiling is checked between polls, so one poll in flight can overrun it by exactly the stall
/// that poll is measuring, and by no more.
///
/// ## The final check
///
/// The budget is tested after a sleep and before the condition, as it always was, so the last
/// poll ends with a sleep nobody looked after. One more evaluation once the budget is spent
/// means a condition that became true during that sleep passes rather than being reported as
/// a timeout — several waits on 2026-10-17 missed by under half a second.
enum StallTolerantWait {

    /// How far past `interval` an iteration may run before the overrun counts as a stall.
    static let stallThreshold: Duration = .milliseconds(250)

    /// The most wall time one wait may take, stall compensation included.
    static let ceiling: Duration = .seconds(50)

    enum Outcome: Sendable, Equatable {
        case held
        case timedOut(Expiry)
    }

    /// What a wait spent before it gave up.
    struct Expiry: Sendable, Equatable {

        /// Scheduled waiting time: the wall time spent, less the stall.
        let waited: Duration

        /// Wall time the runner was not running the wait, added to its deadline.
        let stall: Duration

        /// Whether it was the ceiling rather than the budget that ended the wait.
        let capHit: Bool

        /// The ceiling this wait ran under, so the message names the one that applied.
        let ceiling: Duration

        /// The issue text, which says in every case how much stall was compensated — zero
        /// included, so that "no stall" is a statement and not an omission.
        func message(waitingFor what: String) -> String {
            let spent = "\(Self.render(waited)) of waiting"
            let compensated = "plus \(Self.render(stall)) of runner stall compensated"
            guard capHit else {
                return "timed out after \(spent) (\(compensated)) for: \(what)"
            }
            return """
                timed out at the \(Self.render(ceiling)) cap (cap hit) after \
                \(spent) (\(compensated)) for: \(what)
                """
        }

        private static func render(_ duration: Duration) -> String {
            let parts = duration.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return String(format: "%.1f s", seconds)
        }
    }

    /// Polls `condition` until it holds or the budget is spent.
    ///
    /// - Parameters:
    ///   - timeout: scheduled waiting time, not wall time.
    ///   - interval: the sleep between polls.
    ///   - threshold: how far past `interval` an iteration may run before the overrun counts
    ///     as a stall.
    ///   - ceiling: the most wall time the wait may take, stall included.
    ///   - clock: the time, and the sleeps.
    ///   - condition: what the wait is for.
    /// - Returns: whether the condition held, and if it did not, what the wait spent.
    /// - Throws: `CancellationError`, from the clock's `sleep`.
    static func poll(
        timeout: Duration,
        interval: Duration,
        threshold: Duration = StallTolerantWait.stallThreshold,
        ceiling: Duration = StallTolerantWait.ceiling,
        clock: some WaitClock,
        condition: () async -> Bool
    ) async throws -> Outcome {
        let start = await clock.now()
        var mark = start
        var stall = Duration.zero

        while true {
            let wall = mark - start
            if wall >= ceiling || wall - stall >= timeout { break }

            if await condition() { return .held }

            try await clock.sleep(for: interval)
            let woke = await clock.now()

            // Condition and sleep both: a process stopped while the condition was being
            // evaluated lost that time as surely as one stopped while sleeping.
            let overrun = (woke - mark) - interval
            if overrun > threshold { stall += overrun }
            mark = woke
        }

        if await condition() { return .held }

        let wall = mark - start
        return .timedOut(
            Expiry(waited: wall - stall, stall: stall, capHit: wall >= ceiling, ceiling: ceiling))
    }
}

/// Polls `condition` until it holds or the budget is spent, counting only time the waiter
/// ran — see ``StallTolerantWait`` for the budget, the 250 ms threshold, the 50 s ceiling and
/// the final check.
///
/// Connection invalidation is delivered by libxpc on its own schedule, so the alternative
/// to polling is a fixed sleep — which is either flaky or slow, and gives no diagnostic
/// when it fails. Fails the test with the reason rather than hanging the suite.
///
/// `timeout` is scheduled waiting time, not wall time, so every caller keeps the meaning it
/// had: a runner that stalled for 30 s does not spend it. A timeout says how much stall it
/// compensated. The figure is evidence and not an excuse — the budget was spent in full
/// either way — but a large one says the run was on a stalled runner, so look first for
/// something else the stall tripped, such as a client deadline measured on the wall clock,
/// before looking for a client defect. Zero says there was nothing to look for.
///
/// This is the injectable overload, and it is what the shipping one calls. `clock` has no
/// default, so a call without it can only mean the overload below.
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    threshold: Duration = StallTolerantWait.stallThreshold,
    ceiling: Duration = StallTolerantWait.ceiling,
    clock: some WaitClock,
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let outcome = try await StallTolerantWait.poll(
        timeout: timeout, interval: interval, threshold: threshold, ceiling: ceiling,
        clock: clock, condition: condition)
    if case .timedOut(let expiry) = outcome {
        Issue.record(
            Comment(rawValue: expiry.message(waitingFor: what)), sourceLocation: sourceLocation)
    }
}
