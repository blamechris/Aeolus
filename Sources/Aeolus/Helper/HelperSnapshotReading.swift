import AeolusXPC
import AeolusXPCClient

/// The read side of the helper, and nothing else: one verb and the health signal.
///
/// `HelperSnapshotSource` holds one of these, and this is everything it can do with it. There
/// is no lease, apply, renew or release here, and none may be added. Control travels on a
/// **second** `HelperClient`, the lease driver's (`AppComposition`), so that an `apply` that
/// may lawfully take 57 s never queues a `snapshot` behind it on one connection and freezes the
/// display. Nothing in the app takes a lease yet, so it sends no control verb. A read
/// connection that could also acquire would be one refactor away from being that second
/// connection.
///
/// The seam is also what lets `AeolusUITests` drive the source against a fake helper whose
/// replies are parked until the test releases them, so "one request in flight" is something
/// a test can watch fail rather than something an actor's serialisation hands out for free.
///
/// Declared here, in the app, and not in `AeolusXPCClient`: it is this client's narrowing of
/// that target's API, and the conformance below adds nothing to the actor — no member, no
/// state, no file in the target whose members `HelperClientAccessTests` holds to account.
public protocol HelperSnapshotReading: Sendable {
    /// A fresh round trip, or an error. `HelperClient.snapshot()`.
    func snapshot() async throws -> SystemSnapshot

    /// The connection's health, current value first. `HelperClient.healthUpdates()`.
    func healthUpdates() -> AsyncStream<HelperConnectionHealth>
}

extension HelperClient: HelperSnapshotReading {}
