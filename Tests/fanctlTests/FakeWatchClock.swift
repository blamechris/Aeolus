import Foundation

@testable import fanctl

/// A `WatchClock` double: `now()` always returns the same injected `Date`, so a tick's
/// table timestamp and JSON `capturedAt` are deterministic and directly comparable against
/// a fixture, and `sleep(seconds:)` never actually waits — it either resolves immediately
/// or throws `CancellationError`, per a scripted plan, so `WatchCommandTests` can exercise
/// many ticks and a simulated mid-loop SIGINT without the suite taking real wall-clock time
/// or touching a real signal.
///
/// An `actor` rather than a class with `@unchecked Sendable`: `sleepCallCount` is genuinely
/// mutable state this type needs to track across calls, and an actor is what makes that
/// safe under strict concurrency without asserting anything the compiler cannot check —
/// see `FakeSensorProvider`, which follows the same pattern for the same reason.
actor FakeWatchClock: WatchClock {
    private let fixedDate: Date
    private let cancelAfterSleeps: Int?
    private var sleepCallCount = 0

    /// - Parameters:
    ///   - fixedDate: What every tick's `now()` reports.
    ///   - cancelAfterSleeps: If set, the `n`th call to `sleep(seconds:)` throws
    ///     `CancellationError` instead of returning, simulating a `SIGINT` landing between
    ///     that tick and the next. `nil` (the default) never cancels — the loop runs for
    ///     exactly as many ticks as `count` specifies.
    init(
        fixedDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        cancelAfterSleeps: Int? = nil
    ) {
        self.fixedDate = fixedDate
        self.cancelAfterSleeps = cancelAfterSleeps
    }

    nonisolated func now() -> Date { fixedDate }

    func sleep(seconds: Double) async throws {
        sleepCallCount += 1
        if let cancelAfterSleeps, sleepCallCount >= cancelAfterSleeps {
            throw CancellationError()
        }
    }
}
