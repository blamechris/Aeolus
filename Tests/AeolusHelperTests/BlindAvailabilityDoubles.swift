import Foundation

@testable import AeolusHelper

// The two doubles `BlindAvailabilityTests` drives, in a file of their own for
// `SnapshotAvailabilityDoubles`' reason: the suite is past SwiftLint's 400-line limit with them in
// it. Internal rather than `private` only so that file can reach them.

/// A `SightednessProving` whose every `sighting()` parks until it is cancelled, and then throws
/// `CancellationError`. A continuation, so nothing blocks a thread.
actor ParkedSighting: SightednessProving {
    private var waiters: [CheckedContinuation<CriticalTemperatureReport, any Error>] = []

    /// Sightings parked right now.
    var parked: Int { waiters.count }

    func sighting() async throws -> CriticalTemperatureReport {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append($0) }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func cancelAll() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(throwing: CancellationError()) }
    }
}

/// How many lines every recording log has been handed. `NSLock` rather than an actor, so a log's
/// synchronous sink can count without an `await`, as `RecordedLog` does.
final class LineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var lines = 0

    func add() { lock.withLock { lines += 1 } }

    var count: Int { lock.withLock { lines } }
}
