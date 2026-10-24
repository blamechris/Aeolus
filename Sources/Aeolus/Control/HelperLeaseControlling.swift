import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation

/// What `LeaseDriver` asks of the helper: the verbs of the app's **control** connection.
///
/// ## A second connection, never the read connection
///
/// The app holds two `HelperClient`s (#153). One reads, and sends only `snapshot`. This is the
/// other one. `apply` may lawfully take its whole client deadline, 57 seconds for one fan
/// (`HelperClientDeadlines.applyDeadline(naming:)`), and a `snapshot` sequenced behind it on the
/// same connection would freeze the display for that long. Nothing here can read a snapshot, so the
/// driver cannot put one on this connection by accident: what it judges a snapshot by arrives from
/// the read side, through `LeaseDriver.observe(_:readWith:)`.
///
/// ## What is here, and what is not
///
/// The four lease verbs, the health signal the driver ends a lease on, and `disconnect()`, which is
/// how a quit tears the connection down after its explicit release. `restoreAllToAutomatic` is not
/// here: the panic path is `fanctl reset --all`'s, and the driver's way back to automatic is to
/// release the lease it holds.
///
/// Nothing here renews on its own. `HelperClient` renews nothing either ("a lease renewed by the
/// transport layer is a lease nobody is proving they still want"); the heartbeat is the driver's.
public protocol HelperLeaseControlling: Sendable {

    /// Asks for manual control of `request.fanIndices`. A refusal is thrown as the helper's own
    /// `AeolusXPCFault`.
    func acquireLease(_ request: LeaseRequest) async throws -> Lease

    /// Extends a lease this connection holds.
    func renewLease(id: UUID) async throws -> Lease

    /// Gives a lease back. Not sequenced at the helper, so it is not queued behind an `apply`.
    func releaseLease(id: UUID) async throws

    /// Sends fan settings under a lease.
    func apply(_ settings: [FanSetting], leaseID: UUID) async throws

    /// The connection's health, starting with its value now.
    func healthUpdates() -> AsyncStream<HelperConnectionHealth>

    /// Tears the connection down. The helper releases a connection's leases when it goes.
    func disconnect() async
}

/// The production conformance: the app's control `HelperClient`, unchanged.
extension HelperClient: HelperLeaseControlling {}
