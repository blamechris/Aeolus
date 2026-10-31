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

/// What a wait's `timeout:` bounds.
enum WaitBudget: Sendable, Equatable {

    /// Scheduled waiting time: a stall is added to the deadline. What a wait for something to
    /// happen means, and what every caller gets unless it says otherwise.
    case runTime

    /// Elapsed time: a stall is measured and reported but spends the bound. For a `timeout:`
    /// that is a deadline the product is held to, which compensation would stretch to the
    /// ceiling.
    case wallTime
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
/// only reading under which a *wait* can mean the same thing on a quiet laptop and a stalled
/// runner.
///
/// ## When the timeout is a contract, not a wait
///
/// Not every `timeout:` is a wait. A caller that passes a bound the product promises — the
/// time a lease heartbeat has to be answered in, derived from the TTL — is asserting a
/// deadline, and stretching a deadline by 50 s is no longer asserting it. Those callers pass
/// ``WaitBudget/wallTime``: the stall is still measured and still reported, but it is spent
/// from the bound like any other time. The price is honest and paid by the caller: a runner
/// stall can fail such a wait, and the message says that it is the stall — "seen, not
/// compensated" — rather than the client.
///
/// ## What compensation cannot tell
///
/// A stall and a slow condition look the same from here: both are an iteration that overran.
/// A condition that regresses from 10 ms to 2 s, on an idle runner, is compensated exactly as
/// a descheduled process is, and a *passing* wait says nothing. So a pass that compensated
/// more than ``noteThreshold`` writes a line to standard error — never an issue, since the
/// test passed — naming the wait. Seeing that line on a run with no stall in it is how a slow
/// condition is caught; this is the trade the fix makes, and it is chosen over failing a
/// correct test for the runner's pause.
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

    /// How much stall a *passing* wait may compensate before it says so on standard error.
    static let noteThreshold: Duration = .seconds(1)

    /// The scheduled waiting time a **setup** wait gives a message to cross the XPC boundary and
    /// be acted on, or an event to reach the client
    /// ([#592](https://github.com/blamechris/Aeolus/issues/592)).
    ///
    /// **Why the default 5 s is not enough.** Compensation adds back only an iteration that
    /// overran by more than ``stallThreshold``. A runner that is busy rather than stopped delivers
    /// a message late without any one 10 ms poll running 250 ms over, so a wait that needs a round
    /// trip through the anonymous listener spends its 5 s in scheduled time and gives up with
    /// "0.0 s of runner stall compensated" and nothing at the helper. Main failed that way on
    /// `5034c41` (run 40946892305): 47 issues in 10 suites, the longest wait 5.0 s plus 7.5 s of
    /// stall, and the helper side had received nothing.
    ///
    /// **When to pass it.** For a wait whose subject is the product having *done* something that
    /// needs a hop to the other side ("is held at the helper", "is parked at the helper", "the
    /// client has the reply in hand", "the client heard the helper die"), in a test whose
    /// deadlines are counted on a clock only the test moves, or have all run out already
    /// (`FanctlResetTests.aHelperThatNeverAnswersIsReportedAsUnknown` counts its 2 s on the wall
    /// clock, and waits after `run()` has returned). The budget then carries no claim about time:
    /// a longer one cannot make a wrong client pass, it only decides how long a failing test takes
    /// to say so. A wait whose claim *is* a time keeps its own bound and a `budget:` that says so
    /// (``WaitBudget/wallTime``).
    ///
    /// **Where it must not be used.** No wait whose condition is the client's *reaction to a
    /// clock advance the test made* (a deadline having run out, a turn having come) may use this
    /// constant. Its length is the backstop's, so the backstop can run a late deadline out while
    /// the wait is still going, and a client with the wrong deadline then passes. The #595
    /// review gave `HelperClientHandshakeCancellationTests`' "the handshake's deadline ran out
    /// and gave the connection up" this budget, and a client with a doubled handshake deadline
    /// went green at 30.034 s (30.026 s when repeated for #596): the backstop had run the
    /// deadline out. With the default budget the same client is red at 5.04 s. That wait keeps
    /// the default. One wait of the kind still has this constant, where no backstop moves the
    /// client's clock and a later assertion catches a late deadline
    /// (`HelperClientSequencedDeadlineTests`, "the snapshot's turn came when the apply's
    /// deadline ran out"), and says so. A wait for the helper to *hear* something after the
    /// test has asserted the client's reaction is a delivery, and is the constant's.
    ///
    /// **Why 30 s.** Over twice the longest wait that was missed, and no longer than the 30 s the
    /// harness gives a lost reply (`ClockBackstop.defaultBudget`). It is not "before" the
    /// backstop: that 30 s starts when the harness is built and a wait starts later, so a
    /// delivery that never happens is reported **after** the backstop has fired and run the
    /// harness's deadlines out, by as long as the harness had lived when the wait began. What the
    /// bound keeps is that this lag does not grow with the budget. Under the 50 s ``ceiling`` and
    /// the 60 s of the shortest `.timeLimit`. The relations are held by
    /// `StallTolerantWaitTests.aDeliveryWaitFitsInsideTheBackstopAndTheTimeLimit`.
    static let deliveryBudget: Duration = .seconds(30)

    enum Outcome: Sendable, Equatable {

        /// The condition held, having compensated `compensated` of stall on the way.
        case held(compensated: Duration)
        case timedOut(Expiry)
    }

    /// What a wait spent before it gave up.
    struct Expiry: Sendable, Equatable {

        /// Time the wait spent: wall time, less whatever was compensated.
        let waited: Duration

        /// Wall time the runner was not running the wait, as measured.
        let stall: Duration

        /// Whether `stall` was added to the deadline (``WaitBudget/runTime``) or spent from
        /// it (``WaitBudget/wallTime``).
        let compensated: Bool

        /// Whether it was the ceiling rather than the budget that ended the wait.
        let capHit: Bool

        /// The ceiling this wait ran under, so the message names the one that applied.
        let ceiling: Duration

        /// The issue text, which says in every case how much stall there was and what was done
        /// about it — zero included, so that "no stall" is a statement and not an omission.
        func message(waitingFor what: String) -> String {
            let spent = "\(Self.render(waited)) of waiting"
            let stalled =
                compensated
                ? "plus \(Self.render(stall)) of runner stall compensated"
                : "wall-clock bound: \(Self.render(stall)) of runner stall seen, not compensated"
            guard capHit else {
                return "timed out after \(spent) (\(stalled)) for: \(what)"
            }
            return """
                timed out at the \(Self.render(ceiling)) cap (cap hit) after \
                \(spent) (\(stalled)) for: \(what)
                """
        }

        /// The line a passing wait writes when it compensated more than
        /// ``StallTolerantWait/noteThreshold``.
        static func passNote(
            waitingFor what: String, compensated: Duration, at location: String
        ) -> String {
            """
            note: waitUntil at \(location) passed after compensating \(render(compensated)) of \
            runner stall, for: \(what). A stall and a slow condition look alike to the wait; \
            if this line appears on a run with no runner stall in it, the condition is slow.
            """
        }

        private static func render(_ duration: Duration) -> String {
            let parts = duration.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return String(format: "%.1f s", seconds)
        }
    }

    /// The default sink for a pass that compensated a lot: one write, so concurrent tests do not
    /// interleave inside a line.
    static func writeToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Polls `condition` until it holds or the budget is spent.
    ///
    /// - Parameters:
    ///   - timeout: scheduled waiting time, or elapsed time under ``WaitBudget/wallTime``.
    ///   - interval: the sleep between polls.
    ///   - budget: whether a stall is added to the deadline or spent from it.
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
        budget: WaitBudget = .runTime,
        threshold: Duration = StallTolerantWait.stallThreshold,
        ceiling: Duration = StallTolerantWait.ceiling,
        clock: some WaitClock,
        condition: () async -> Bool
    ) async throws -> Outcome {
        let start = await clock.now()
        var mark = start
        var stall = Duration.zero
        var granted = Duration.zero

        while true {
            let wall = mark - start
            if wall >= ceiling || wall - granted >= timeout { break }

            if await condition() { return .held(compensated: granted) }

            try await clock.sleep(for: interval)
            let woke = await clock.now()

            // Condition and sleep both: a process stopped while the condition was being
            // evaluated lost that time as surely as one stopped while sleeping.
            let overrun = (woke - mark) - interval
            if overrun > threshold {
                stall += overrun
                if budget == .runTime { granted += overrun }
            }
            mark = woke
        }

        if await condition() { return .held(compensated: granted) }

        let wall = mark - start
        return .timedOut(
            Expiry(
                waited: wall - granted, stall: stall, compensated: budget == .runTime,
                capHit: wall >= ceiling, ceiling: ceiling))
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
/// By default `timeout` is scheduled waiting time, not wall time: a runner that stalled for
/// 30 s does not spend it. A caller whose `timeout` is a deadline the product is held to, and
/// not a wait for something to happen, passes `budget: .wallTime` and is not stretched. A
/// timeout says how much stall there was and which of the two was done about it. The figure is
/// evidence and not an excuse — the budget was spent in full either way — but a large one says
/// the run was on a stalled runner, so look first for something else the stall tripped, such
/// as a client deadline measured on the wall clock, before looking for a client defect. Zero
/// says there was nothing to look for.
///
/// A *pass* that compensated more than a second writes a line to `note`, standard error by
/// default; see "What compensation cannot tell" on ``StallTolerantWait``.
///
/// `what` is the event waited for, and is what a pass note and a timeout both name. A caller that
/// can say why a timeout means something is wrong passes `ifItTimesOut`, which is appended to the
/// timeout's issue and to nothing else: a wait that passed has no failure to explain, and a note
/// that did would say so.
///
/// This is the injectable overload, and it is what the shipping one calls. `clock` has no
/// default, so a call without it can only mean the overload below.
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    budget: WaitBudget = .runTime,
    threshold: Duration = StallTolerantWait.stallThreshold,
    ceiling: Duration = StallTolerantWait.ceiling,
    clock: some WaitClock,
    note: (String) -> Void = StallTolerantWait.writeToStandardError,
    ifItTimesOut explanation: String? = nil,
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let outcome = try await StallTolerantWait.poll(
        timeout: timeout, interval: interval, budget: budget, threshold: threshold,
        ceiling: ceiling, clock: clock, condition: condition)
    switch outcome {
    case .held(let compensated) where compensated > StallTolerantWait.noteThreshold:
        note(
            StallTolerantWait.Expiry.passNote(
                waitingFor: what, compensated: compensated,
                at: "\(sourceLocation.fileID):\(sourceLocation.line)"))
    case .held:
        break
    case .timedOut(let expiry):
        let said = expiry.message(waitingFor: what)
        Issue.record(
            Comment(rawValue: explanation.map { "\(said): \($0)" } ?? said),
            sourceLocation: sourceLocation)
    }
}
