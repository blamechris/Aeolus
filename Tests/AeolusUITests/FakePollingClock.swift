import Foundation

@testable import AeolusUI

/// A `PollingClock` double: `sleep(seconds:)` never actually waits — it either resolves
/// immediately or throws `CancellationError`, per a scripted plan, so tests can drive many
/// ticks of `PollingViewModel`'s refresh loop without the suite taking real wall-clock
/// time. Mirrors `fanctlTests`' `FakeWatchClock`, reimplemented here for the same reason
/// as `FakeSensorProvider`.
///
/// An `actor`, not a class with `@unchecked Sendable` — see `FakeSensorProvider`'s
/// identical note: `sleepCallCount` is mutable state a test needs to observe safely under
/// strict concurrency.
actor FakePollingClock: PollingClock {
    private let cancelAfterSleeps: Int?
    private(set) var sleepCallCount = 0
    /// Every `seconds` value this clock was asked to sleep for, in call order — lets a
    /// test assert what `PollingViewModel` actually requested (e.g. that a non-positive
    /// `refreshInterval` was clamped before ever reaching the clock).
    private(set) var sleptSeconds: [Double] = []

    /// - Parameter cancelAfterSleeps: If set, the `n`th call to `sleep(seconds:)` throws
    ///   `CancellationError` instead of returning. `nil` (the default) never cancels.
    init(cancelAfterSleeps: Int? = nil) {
        self.cancelAfterSleeps = cancelAfterSleeps
    }

    func sleep(seconds: Double) async throws {
        sleepCallCount += 1
        sleptSeconds.append(seconds)
        if let cancelAfterSleeps, sleepCallCount >= cancelAfterSleeps {
            throw CancellationError()
        }
    }
}
