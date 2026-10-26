@testable import AeolusLeaseControl

/// The wait for the floor a driver mints, and the one definition of what a floor is.
extension LeaseScene {

    /// How many steps of `floorStep` `firstFloor(since:)` sleeps through before it gives up.
    static let floorPatience = 5_000

    /// One step of `firstFloor(since:)`'s patience.
    static let floorStep: Duration = .milliseconds(1)

    /// The most wall-clock time `firstFloor(since:)` waits, whatever its steps cost.
    ///
    /// 50 s, as the helper tests' `StallTolerantWait.ceiling` is (that target cannot be imported
    /// here), for the same reason: under the 60 s that is the **smallest** `.timeLimit` Swift
    /// Testing can express, so the ceiling is a red with the `#require`'s message before the
    /// suite's limit can be one that says nothing about why. The patience alone is not that bound:
    /// it is 5,000 sleeps, and it was spent in about ten seconds only because a step took about
    /// 2 ms. At 12 ms a step, 5,000 of them are the whole limit.
    static let floorCeiling: Duration = .seconds(50)

    /// What ended a wait for a floor.
    enum FloorWaitEnd: Sendable, Equatable {

        /// A report that carries a floor reached the ledger.
        case published

        /// `patience` steps were slept through, in less than `ceiling` of wall-clock time.
        case patience

        /// `ceiling` of wall-clock time passed, in fewer than `patience` steps.
        case ceiling

        /// The waiting task was cancelled, as a suite's time limit does.
        case cancelled
    }

    /// What a wait for a floor found, and what ended it.
    struct FloorWait: Sendable, Equatable {

        /// The first report published after the wait's `mark` that carries a floor, from a last
        /// look at the ledger once the wait ended: a floor that landed as a bound was reached is
        /// still found, whatever `end` says.
        let report: LeaseDriverReport?

        let end: FloorWaitEnd
    }

    /// The first report published after `mark` that carries a floor, once the ledger has one, or
    /// `nil` if none has reached it within `floorPatience` steps of `floorStep` or `floorCeiling`
    /// of wall-clock time, whichever is first.
    ///
    /// **For the floor the last unanswered `apply`'s answer mints** (ADR 0015 D5). The fake writes
    /// the answer to the ledger and only then returns to the driver, which mints on its own actor
    /// and publishes the floor as a report with the state unchanged. So the answer's entry is no
    /// promise that the driver has handled it, and `settle()` is none either (#519): in 40 runs of
    /// `AeolusUITests` in the release configuration, 13 of 200 reads of `driver.report` after
    /// that entry and `settle()` still said `noRead`. In every one of the 13 the floor was
    /// published moments later (a wait on the ledger begun just after the read ended within
    /// 516 µs), and none was missing for good. This waits on the published report itself,
    /// forwarded from `reportUpdates()`, as `firstReport(since:where:)` does.
    ///
    /// **It ends at the first of three things, and a caller `#require`s the result.** A driver
    /// that never mints publishes nothing, so no event can end the wait; the patience or the
    /// ceiling does, and the caller's `#require` is a red with a message rather than a red at the
    /// suite's time limit. A correct driver never spends either: its report ends the wait as soon
    /// as the ledger has it. A `nil` is therefore never a pass, and no caller may go on without
    /// requiring the floor it waited for.
    ///
    /// **The patience counts steps the waiter slept through, not elapsed time and not hops.** A
    /// stall of the whole process spends one step however long it lasts, so a CI runner's pause
    /// (#341's were 20 to 30 s) does not use the patience up, where a wall-clock bound of the same
    /// size would be spent at once; the helper's `StallTolerantWait` counts only scheduled time
    /// for the same reason. A pool too busy to wake the waiter on time makes each step longer
    /// rather than using more of the patience. And a step is a timer, so a release build does not
    /// shorten it, as it did the hops of `settle()`. A step took about 2 ms on the development
    /// machine, so a driver that never mints is a red in about ten seconds there (#519's M3 and
    /// mA, 9.9 s each).
    ///
    /// **The ceiling is wall-clock time, and is the one bound a stall can spend.** It is the other
    /// half of that trade: a patience that a slow pool lengthens needs a limit of its own, or a
    /// driver that never mints would reach the suite's time limit before it reached the
    /// `#require` (#521). It is read on `ContinuousClock`, never on the scene's hand-wound
    /// `clock`, which does not move on its own, and it is checked between steps, so one step in
    /// flight can overrun it by exactly the stall that step is measuring and by no more. A stall
    /// that did spend it would cost a correct driver nothing: the last look at the ledger still
    /// finds a floor that was published meanwhile.
    func firstFloor(since mark: Int) async -> LeaseDriverReport? {
        await awaitFloor(since: mark).report
    }

    /// `firstFloor(since:)` over bounds of the caller's choosing, with what ended the wait. The
    /// scene's own bounds are the defaults; a test of the bounds themselves passes short ones.
    func awaitFloor(
        since mark: Int, patience: Int = LeaseScene.floorPatience,
        step: Duration = LeaseScene.floorStep, ceiling: Duration = LeaseScene.floorCeiling
    ) async -> FloorWait {
        let ledger = self.ledger
        let end = await withTaskGroup(of: FloorWaitEnd.self) { group in
            group.addTask {
                await ledger.waitFor {
                    Array($0.dropFirst(mark)).reports.contains { $0.automaticEvidence.isFloor }
                }
                // `waitFor` also returns when the task is cancelled.
                return Task.isCancelled ? .cancelled : .published
            }
            group.addTask {
                await Self.spendPatience(patience, step: step, ceiling: ceiling)
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
        let report = Array(await ledger.entries.dropFirst(mark)).reports.first {
            $0.automaticEvidence.isFloor
        }
        return FloorWait(report: report, end: end)
    }

    /// Sleeps `patience` steps of `step`, or until `ceiling` of wall-clock time has passed or the
    /// task is cancelled, and says which. Never ends on the ledger: that is the other half of the
    /// race in `awaitFloor(since:patience:step:ceiling:)`.
    private static func spendPatience(
        _ patience: Int, step: Duration, ceiling: Duration
    ) async -> FloorWaitEnd {
        let began = ContinuousClock.now
        for _ in 0..<patience {
            do { try await Task.sleep(for: step) } catch { return .cancelled }
            if ContinuousClock.now - began >= ceiling { return .ceiling }
        }
        return .patience
    }
}

extension LeaseDriverReport.AutomaticEvidence {

    /// Whether this is a floor: `readFrom`, which the driver mints when it has stopped acting with
    /// no `apply` unanswered (ADR 0015 D5). Neither `noRead`, which means an `apply` is
    /// unanswered, nor `anyRead`, which means the driver has never let go, is one.
    ///
    /// **The one definition in this target (#521).** Every wait for a floor and every assertion
    /// that one was published asks this, so a change to what a floor is changes all of them at
    /// once, and a wait and the assertion beside it cannot disagree. It is its own, not the
    /// app's: `LeaseStateModel.isFloor` is private to the code under test, and a test that asked
    /// the code it checks would agree with it whatever it said. Exhaustive, with no `default:`, so
    /// a case added to the evidence has to be decided here.
    var isFloor: Bool {
        switch self {
        case .readFrom:
            true
        case .anyRead, .noRead:
            false
        }
    }
}
