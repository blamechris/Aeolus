import Foundation

/// The keystone verb, as a seam.
///
/// [ADR 0007](../../../docs/ADR/0007-safety-composition.md) rests every precedence ruling
/// on one principle:
///
/// > **Restore-to-automatic is a mode write, and must never depend on trusted data.** It
/// > needs no bounds, no clamp, no sensor reading, no lease lookup and no ramp budget —
/// > `F0Md = 0` (plus `Ftst = 0`) on Apple Silicon, clearing the `FS!` bit on Intel.
///
/// That is why this protocol takes fan indices and a provenance label and nothing else. If
/// an implementation of it ever needs to read a bound, consult a sensor, or look up a
/// lease before it can act, the design has gone wrong — the whole point is that this stays
/// available when every input the other mechanisms depend on has become untrustworthy.
///
/// ## Deliberately unimplemented in this target
///
/// E5.1 ships the lease core and **writes nothing to the SMC**: `SMCConnection.write` is
/// still `package`-scoped and still throws, and no write selector exists anywhere in
/// `Sources/`. The conforming type is the helper's control plane, which arrives with the
/// write path. Declaring the seam here rather than there keeps the lease core testable in
/// full today — every teardown path below is exercised against a recording double — and
/// means the control plane inherits a contract it cannot widen by accident.
///
/// ## Why it cannot fail
///
/// No `throws`, no return value, for the same reason
/// `FanAuthority.connectionDidInvalidate(_:)` has neither: the callers are teardown paths
/// with nobody to report to. A lease that expired has no live client, and a connection that
/// died has no port. An implementation that cannot complete the write must log it and keep
/// trying — surfacing it to a caller that can do nothing with it would be a failure
/// dressed as a decision.
protocol FanRestoring: Sendable {

    /// Returns `fans` to the system's own thermal management.
    ///
    /// Must be idempotent: every teardown path may run for fans that are already automatic,
    /// and two paths may name the same fan in the same instant.
    func restoreToAutomatic(fans: Set<Int>, because cause: FanRestoreCause) async
}

/// Which mechanism asked for the restore.
///
/// Provenance for a log line, never an input to the decision — the restore is unconditional
/// and identical whatever this says. It is carried because
/// [ADR 0005](../../../docs/ADR/0005-xpc-authorisation.md) requires the lease's two teardown
/// paths to be independent, and "independent" is only checkable if an observer can tell
/// which one acted. A restore whose cause cannot be named is a restore whose mechanism
/// cannot be audited.
enum FanRestoreCause: Sendable, Hashable {

    /// The TTL lapsed. The backstop path, driven by `LeaseExpirySupervisor` against the
    /// monotonic clock, and reachable with no connection event of any kind.
    case leaseExpired

    /// The connection holding the lease died — crash, `SIGKILL`, logout, orderly
    /// disconnect. Reachable with the monotonic clock frozen.
    case connectionInvalidated

    /// The client asked, on a connection that held the lease.
    case leaseReleased

    /// The panic path: every lease dropped at once.
    case allLeasesDropped
}

/// Where the lease core gets the set of fans this machine actually has.
///
/// `FanAuthority`'s own documentation puts this check on the authority side rather than the
/// listener: *"the authority owns the enumeration, and shipping the set up to the listener
/// on every message would be both chatty and a time-of-check/time-of-use gap on the one
/// input that decides which fans a lease may cover."*
///
/// The lease core does not own hardware, so it asks. `ReadOnlyFanAuthority` already declares
/// exactly this method and is conformed to it below, which is the cheapest possible proof
/// that the seam is satisfiable by shipped code rather than only by a test double.
///
/// **This is the suspension point that makes
/// [#95](https://github.com/blamechris/Aeolus/issues/95) real.** `LeaseAuthority.acquireLease`
/// awaits it, and an invalidation can land during that await — which is precisely the
/// interleaving the post-suspension liveness re-check exists to close.
protocol FanEnumerating: Sendable {

    /// The fan indices this machine enumerated.
    func enumeratedFanIndices() async throws -> Set<Int>
}

extension ReadOnlyFanAuthority: FanEnumerating {}
