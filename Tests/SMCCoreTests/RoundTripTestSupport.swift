import Foundation
import Testing
import os

@testable import SMCCore

/// A clock the test moves by hand, on the monitor's own `Instant`.
///
/// It is typed `SMCRoundTripMonitor.Instant` and takes its starting point from the monitor's
/// own `MeasuringClock`, rather than being declared over `SuspendingClock.Instant` directly.
/// That is deliberate: the clock family is one line in the monitor, and a helper that named
/// it a second time would stop compiling the moment that line changed — turning the
/// assertion that pins the family into a build error instead of a failure.
final class SteppedClock: Clock, Sendable {
    typealias Instant = SMCRoundTripMonitor.Instant

    private let base = SMCRoundTripMonitor.MeasuringClock().now
    private let elapsed = OSAllocatedUnfairLock(initialState: Duration.zero)

    var now: Instant { base.advanced(by: elapsed.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by amount: Duration) {
        elapsed.withLock { $0 += amount }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()
    }
}

/// A bounded wait, in a synchronous function so an `async` test may call it: the compiler
/// refuses `DispatchSemaphore.wait` directly in an async context, and the bound is what keeps
/// a failing test from hanging instead of failing.
///
/// **The budget is counted in slices of 50 ms, not measured against a deadline**
/// ([#421](https://github.com/blamechris/Aeolus/issues/421)). `observeInFlight` allows a reader
/// that takes microseconds three seconds, and a runner that stops the process for ten, or
/// starves it for twenty, spends that while the reader was not running either, and a correct
/// monitor is then reported as one that "blocked behind a round trip that had not returned".
/// A stall, however it ends the slice it lands in, spends that one slice. The wait also ends at
/// `seconds + 50` of wall time, so a waiter that is slow rather than stopped still fails.
/// `SliceCountedWait` in `AeolusHelperTests` is the same wait, with the tests of it; the two
/// targets cannot share a file.
///
/// It parks the calling thread, and for an `async` test that is a cooperative-pool thread. That is
/// harmless only because every signaller here (`observeInFlight`'s reader, `ParkedRoundTrip`) is a
/// dedicated `Thread`; never wait on a semaphore a pool task has to signal (#554).
func signalled(_ semaphore: DispatchSemaphore, within seconds: Int) -> Bool {
    let limit = ContinuousClock.now.advanced(by: .seconds(seconds + 50))
    for _ in 0..<(seconds * 20) {
        if semaphore.wait(timeout: .now() + .milliseconds(50)) == .success { return true }
        if ContinuousClock.now >= limit { return false }
    }
    return false
}

/// What a read made on a thread of its own returned. A wrapper, because the read's own result is
/// optional ("nothing in flight") and "the read never came back" has to be told apart from it.
struct ThreadedReading: Sendable {
    let value: SMCRoundTripInFlight?
}

/// `monitor.inFlight()`, read on a thread of its own and waited for with a bound. `nil` means the
/// read never came back within `seconds`.
///
/// If the stamp's lock were held across the call being observed, the read would block until
/// that call returned, and the caller — which is *inside* that call — would wait for a reader
/// that waits for it. The bound turns that into a result that says what happened.
///
/// It asserts nothing, so a thread that is not the test's own may call it: an expectation made
/// on a bare `Thread` belongs to no test. `observeInFlight` is this plus the expectation.
func readStampOnAThread(_ monitor: SMCRoundTripMonitor, within seconds: Int) -> ThreadedReading? {
    let finished = DispatchSemaphore(value: 0)
    let seen = OSAllocatedUnfairLock<ThreadedReading?>(initialState: nil)
    let reader = Thread {
        // Read first, store second: the read is the thing that may block, and it must not do
        // so holding the lock the caller needs to look at the result.
        let reading = monitor.inFlight()
        seen.withLock { $0 = ThreadedReading(value: reading) }
        finished.signal()
    }
    reader.start()
    guard signalled(finished, within: seconds) else { return nil }
    return seen.withLock { $0 }
}

/// `monitor.inFlight()` on a thread of its own, with the answer to "did it return" as an
/// assertion of this helper's own.
func observeInFlight(
    _ monitor: SMCRoundTripMonitor, within seconds: Int = 3,
    sourceLocation: SourceLocation = #_sourceLocation
) -> SMCRoundTripInFlight? {
    let reading = readStampOnAThread(monitor, within: seconds)
    #expect(
        reading != nil, "inFlight() blocked behind a round trip that had not returned",
        sourceLocation: sourceLocation)
    return reading?.value
}

/// A round trip parked inside `bracket` on a thread of its own: it begins, signals, and waits
/// until the test lets it go. A real blocked thread, not a suspended task, which is what a
/// wedged `IOConnectCallStructMethod` is.
///
/// `finish()` is for a `defer`: it lets the round trip go and joins the thread whatever the
/// test did, so a failing run cannot leave a thread parked for the rest of the process.
final class ParkedRoundTrip: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let returned = DispatchSemaphore(value: 0)
    private let joined = OSAllocatedUnfairLock(initialState: false)

    init(
        _ monitor: SMCRoundTripMonitor, _ operation: SMCRoundTripOperation,
        allowingOverlap: Bool = false
    ) {
        Thread { [entered, release, returned] in
            let park = {
                entered.signal()
                release.wait()
            }
            if allowingOverlap {
                monitor.bracketAllowingOverlapForTesting(operation, park)
            } else {
                monitor.bracket(operation, park)
            }
            returned.signal()
        }.start()
    }

    func waitUntilParked(within seconds: Int = 10) -> Bool {
        signalled(entered, within: seconds)
    }

    func letReturn() {
        release.signal()
    }

    func waitUntilReturned(within seconds: Int = 10) -> Bool {
        let didReturn = signalled(returned, within: seconds)
        if didReturn { joined.withLock { $0 = true } }
        return didReturn
    }

    /// Lets the round trip go and waits for its thread, unless the test already did.
    func finish() {
        letReturn()
        if !joined.withLock({ $0 }) { _ = waitUntilReturned() }
    }
}
