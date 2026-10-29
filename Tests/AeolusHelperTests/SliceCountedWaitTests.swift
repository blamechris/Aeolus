import Foundation
import Testing
import os

/// `SliceCountedWait`: a semaphore wait whose budget a stall cannot spend
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)).
@Suite("A semaphore wait counted in slices", .timeLimit(.minutes(1)))
struct SliceCountedWaitTests {

    /// **A stall inside one slice spends that slice and no more.** The first wait takes 300 ms of
    /// real time, as a stopped process would take ten seconds; every wait is a slice, so a budget
    /// of one second is twenty of them whatever the first cost.
    ///
    /// A budget measured against the wall clock would be spent by the 300 ms and make fewer waits
    /// (and, with waits that return at once, a great many more); only a count is exactly twenty.
    ///
    /// **Mutation:** in `signalled`, replace the `for` with a loop that runs until
    /// `ContinuousClock.now` passes a deadline `seconds` ahead. Run: red on the count, which
    /// becomes thousands because the fake waits take no time.
    @Test("A slice that took far longer than it should spent one slice of the budget")
    func aStalledSliceSpendsOneSlice() {
        let waits = Counter()
        let signalled = SliceCountedWait.signalled(DispatchSemaphore(value: 0), within: 1) { _, _ in
            if waits.next() == 1 { Thread.sleep(forTimeInterval: 0.3) }
            return false
        }

        #expect(!signalled)
        #expect(
            waits.count == SliceCountedWait.slicesPerSecond,
            "\(waits.count) waits for a one second budget; a stall must spend one slice, not more")
    }

    /// A signal in the middle of the budget ends the wait at once and says so.
    ///
    /// **Mutation:** in `signalled`, return `false` from the `if wait(…)` branch. Run: red.
    @Test("A signal that arrives ends the wait")
    func aSignalEndsTheWait() {
        let semaphore = DispatchSemaphore(value: 0)
        Thread {
            Thread.sleep(forTimeInterval: 0.1)
            semaphore.signal()
        }.start()

        #expect(SliceCountedWait.signalled(semaphore, within: 30))
    }

    /// A semaphore nobody signals ends the wait, false, after the budget and not before.
    ///
    /// **Mutation:** in `signalled`, drop the `seconds * slicesPerSecond` bound for `Int.max`.
    /// Run: red on the time limit, because the wait never ends; the ceiling below is what stops
    /// a wait that is slow rather than stopped.
    @Test("A semaphore nobody signals runs the budget out")
    func aSemaphoreNobodySignalsRunsTheBudgetOut() {
        let waits = Counter()

        let signalled = SliceCountedWait.signalled(DispatchSemaphore(value: 0), within: 2) { _, _ in
            _ = waits.next()
            return false
        }

        #expect(!signalled)
        #expect(waits.count == 2 * SliceCountedWait.slicesPerSecond)
    }

    /// A wait that is slow rather than stopped still ends, at the ceiling.
    ///
    /// **Mutation:** in `signalled`, delete the `if ContinuousClock.now >= limit { return false }`.
    /// Run: red on the count, which is the whole budget instead of the few waits the ceiling
    /// allows.
    @Test("A wait that every slice makes slow ends at the wall ceiling")
    func aSlowWaitEndsAtTheCeiling() {
        let waits = Counter()

        let signalled = SliceCountedWait.signalled(
            DispatchSemaphore(value: 0), within: 60, ceiling: .milliseconds(200)
        ) { _, _ in
            _ = waits.next()
            Thread.sleep(forTimeInterval: 0.05)
            return false
        }

        #expect(!signalled)
        #expect(
            waits.count < 20,
            "\(waits.count) waits of 50 ms ran past a 200 ms ceiling; the ceiling did not end it")
    }
}

/// How many waits ran. A lock rather than an `@unchecked` conformance.
private final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    /// Counts one, and says which one it was.
    func next() -> Int {
        value.withLock { count in
            count += 1
            return count
        }
    }

    var count: Int { value.withLock { $0 } }
}
