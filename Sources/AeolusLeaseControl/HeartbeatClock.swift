import Foundation

/// The clock `LeaseDriver` keeps its heartbeat on, and bounds a release with: what time it is,
/// and a wait until an instant.
///
/// ## `ContinuousClock`, because the helper enforces on it
///
/// The helper enforces a lease on `ContinuousClock`, where time asleep counts against the TTL
/// (`AeolusXPCProtocol`'s lease section). The schedule the app keeps is measured the same way, so
/// the two agree about what a sleep costs: after a long sleep the next renewal is already due and
/// is sent at once, and nothing in the app thinks the lease has time left that the helper does
/// not.
///
/// ## Injectable, so the suite winds it by hand
///
/// "A renewal at ten seconds and none at 9.99" is shown by moving a clock the test holds, never by
/// waiting for one. A heartbeat measured on a real clock under a real-time budget is one a stalled
/// runner can make late for a driver that did nothing wrong.
public protocol HeartbeatClock: Sendable {

    /// Now.
    var now: ContinuousClock.Instant { get }

    /// Suspends until `deadline`. Throws `CancellationError` as soon as the calling task is
    /// cancelled; a deadline already reached returns at once.
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

/// The shipping clock: `ContinuousClock`, as the helper's.
public struct SystemHeartbeatClock: HeartbeatClock {

    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline, tolerance: nil)
    }
}
