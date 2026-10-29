import Foundation

/// A bounded wait on a `DispatchSemaphore` for a thread that is not a cooperative-pool thread,
/// whose budget a stalled runner cannot spend
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)).
///
/// `semaphore.wait(timeout: .now() + 20)` measures its 20 s against the wall clock. A runner that
/// stops the test process for ten seconds, or starves it for twenty, spends the budget while the
/// thread that would have signalled was not running either, and a correct test then fails on the
/// stall: "the connection was never occupied" for a connection that was about to be. CI's first
/// tests have finished 11 s (release) and 22 s (debug) after the run began (#570).
///
/// **The budget is counted in slices, not measured.** The wait is `seconds * 20` waits of 50 ms,
/// and a stall of any length, however it ends the slice it landed in, spends that one slice. That
/// is `pollUntil`'s way of keeping time (2,000 iterations of 5 ms), and it needs no clock to be
/// right: the claim is that the thread ran for the budget, and a count of its own wake-ups is
/// the only measure a stall cannot touch.
///
/// **It still ends.** A waiter that is slow rather than stopped makes every slice long, and
/// 400 slices of a second each is not a bound anybody meant. So the wait also ends at
/// `ceiling` of wall time, `seconds + 50` by default: the budget plus the same 50 s that
/// `StallTolerantWait` allows a stall to add, and under the minute a suite's `.timeLimit` can be
/// no smaller than.
///
/// For waits whose claim is not about time: a failsafe that frees a thread a failing test would
/// otherwise leave parked, or a readiness that another thread has to reach. A wait whose bound is
/// a deadline the product is held to does not belong here; this stretches whatever it is given.
enum SliceCountedWait {

    /// How long one wait lasts.
    static let slice = DispatchTimeInterval.milliseconds(50)

    /// How many slices make a second.
    static let slicesPerSecond = 20

    /// Waits up to `seconds` of scheduled waiting time for `semaphore` to be signalled.
    ///
    /// - Parameters:
    ///   - semaphore: what is waited on.
    ///   - seconds: the budget, as slices actually waited.
    ///   - ceiling: the most wall time the wait may take, stall included.
    ///   - wait: one slice's wait, `true` when the semaphore was signalled. A seam for the
    ///     tests of this type; the default is the semaphore's own.
    /// - Returns: whether the semaphore was signalled.
    static func signalled(
        _ semaphore: DispatchSemaphore,
        within seconds: Int,
        ceiling: Duration? = nil,
        wait: (DispatchSemaphore, DispatchTimeInterval) -> Bool = { semaphore, slice in
            semaphore.wait(timeout: .now() + slice) == .success
        }
    ) -> Bool {
        let limit = ContinuousClock.now.advanced(by: ceiling ?? .seconds(seconds + 50))
        for _ in 0..<(seconds * slicesPerSecond) {
            if wait(semaphore, slice) { return true }
            if ContinuousClock.now >= limit { return false }
        }
        return false
    }
}

/// `SliceCountedWait.signalled(_:within:)`, spelled as the call sites in this target read it.
func signalled(_ semaphore: DispatchSemaphore, within seconds: Int) -> Bool {
    SliceCountedWait.signalled(semaphore, within: seconds)
}
