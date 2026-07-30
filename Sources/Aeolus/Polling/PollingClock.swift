import Foundation

/// Abstracts "how time passes" for `PollingViewModel`'s refresh loop, so it is
/// deterministically testable — the same seam `fanctl watch` uses (`WatchCommand
/// .WatchClock`) for the identical reason: a real run waits on the wall clock, a test can
/// make every tick resolve instantly and simulate cancellation without the suite actually
/// taking `interval * ticks` seconds.
///
/// `public`, not `internal`: `PollingViewModel.init` accepts `some PollingClock` with a
/// default of `SystemPollingClock()`, and a generic parameter can never be less visible
/// than the initializer that exposes it.
public protocol PollingClock: Sendable {
    func sleep(seconds: Double) async throws
}

/// The real clock: `Task.sleep(nanoseconds:)` throws `CancellationError` the instant the
/// surrounding `Task` is cancelled, rather than waiting out the full interval — what makes
/// `PollingViewModel.stop()` feel immediate even when it lands mid-sleep.
public struct SystemPollingClock: PollingClock {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: Self.clampedNanoseconds(forSeconds: seconds))
    }

    /// The nanosecond duration `sleep(seconds:)` waits for, clamped rather than trapping.
    ///
    /// `UInt64(_:)` on an out-of-range `Double` (anything at or above
    /// ~1.8446744e10 seconds, `UInt64.max` nanoseconds) is a runtime precondition
    /// failure, not a thrown error. `UInt64(exactly:)` never traps: it returns `nil` for
    /// exactly that case, handled here by clamping to `UInt64.max` (effectively "forever,
    /// until cancelled") instead of crashing the process over a misconfigured refresh
    /// interval. Mirrors `fanctl`'s identical `SystemWatchClock.clampedNanoseconds(
    /// forSeconds:)`.
    static func clampedNanoseconds(forSeconds seconds: Double) -> UInt64 {
        let nanoseconds = max(0, seconds * 1_000_000_000).rounded()
        return UInt64(exactly: nanoseconds) ?? UInt64.max
    }
}
