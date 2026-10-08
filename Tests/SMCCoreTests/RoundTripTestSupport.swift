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
func signalled(_ semaphore: DispatchSemaphore, within seconds: Int) -> Bool {
    semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
}

/// `monitor.inFlight()`, read on a thread of its own, with the answer to "did it return" as an
/// assertion of this helper's own.
///
/// If the stamp's lock were held across the call being observed, the read would block until
/// that call returned, and the caller — which is *inside* that call — would wait for a reader
/// that waits for it. The bound turns that into a failure that says what happened.
func observeInFlight(
    _ monitor: SMCRoundTripMonitor, within seconds: Int = 3,
    sourceLocation: SourceLocation = #_sourceLocation
) -> SMCRoundTripInFlight? {
    let finished = DispatchSemaphore(value: 0)
    let seen = OSAllocatedUnfairLock<SMCRoundTripInFlight?>(initialState: nil)
    let reader = Thread {
        // Read first, store second: the read is the thing that may block, and it must not do
        // so holding the lock the caller needs to look at the result.
        let reading = monitor.inFlight()
        seen.withLock { $0 = reading }
        finished.signal()
    }
    reader.start()
    let returned = signalled(finished, within: seconds)
    #expect(
        returned, "inFlight() blocked behind a round trip that had not returned",
        sourceLocation: sourceLocation)
    return seen.withLock { $0 }
}

/// Polls `condition` every few milliseconds with `Task.sleep`, which suspends rather than
/// parking a cooperative-pool thread, for at most ten seconds.
func poll(until condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// What a read made on a dedicated thread returned. A wrapper, because the read's own result is
/// optional ("nothing in flight") and "the read never came back" has to be told apart from it.
struct ThreadedReading: Sendable {
    let value: SMCRoundTripInFlight?
}

/// `monitor.inFlight()` on a thread of its own, polled for without parking a pool thread. `nil`
/// means the read never returned within the poll's bound.
func readOnDedicatedThread(_ monitor: SMCRoundTripMonitor) async -> ThreadedReading? {
    let result = OSAllocatedUnfairLock<ThreadedReading?>(initialState: nil)
    Thread {
        let reading = monitor.inFlight()
        result.withLock { $0 = ThreadedReading(value: reading) }
    }.start()
    guard await poll(until: { result.withLock { $0 != nil } }) else { return nil }
    return result.withLock { $0 }
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
