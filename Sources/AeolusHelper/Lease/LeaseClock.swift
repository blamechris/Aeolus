import Foundation

/// The clock lease expiry is enforced against, and the only one it may ever be enforced
/// against.
///
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md) makes this a rule rather than a
/// preference: *"Enforcement is helper-internal against a monotonic clock. The `expiresAt`
/// in the `Lease` DTO is display-grade; the supervisor enforces on `ContinuousClock`, so a
/// wall-clock jump — NTP, a user setting the clock back — can never extend a lease, and
/// time asleep counts against the TTL."*
///
/// ## Why the instant type is `ContinuousClock.Instant` and not a generic
///
/// A `Clock`-generic supervisor would let a test substitute an instant type of its own,
/// and would equally let production code substitute `Date`. Pinning the type here means
/// the arithmetic under test is the arithmetic that ships: a double controls *what time it
/// is*, never *what kind of time it is*. There is no configuration of this protocol under
/// which a wall clock reaches the expiry comparison.
///
/// `now` is a synchronous property on purpose. Every expiry decision is made inside an
/// actor between suspension points, and an `async` clock read would introduce a suspension
/// point into exactly the straight-line region that
/// [#95](https://github.com/blamechris/Aeolus/issues/95)'s fix depends on staying
/// straight-line.
protocol MonotonicClock: Sendable {

    /// The current instant on the monotonic timeline.
    var now: ContinuousClock.Instant { get }

    /// Suspends until `deadline`, or until the task is cancelled.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled. The TTL supervisor
    ///   treats that as its stop signal and nothing else, which is why this is the only
    ///   error it has to reason about.
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

/// The production clock: `ContinuousClock`, unadorned.
///
/// `ContinuousClock` advances while the machine is asleep, which is the property that makes
/// it the right one — a lease acquired before the lid closed must not come back live on
/// wake. [ADR 0007](../../../docs/ADR/0007-safety-composition.md) records that this is
/// documented but **unverified on this machine**, and that the composition tolerates either
/// answer: if it turns out not to advance across sleep, the TTL degrades from "the lease is
/// already gone" to "the lease resumes with its remaining TTL", and §4's release-before-
/// sleep stays load-bearing either way. Nothing here needs changing if that assumption
/// falls.
struct SystemMonotonicClock: MonotonicClock {

    var now: ContinuousClock.Instant { ContinuousClock.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline)
    }
}
