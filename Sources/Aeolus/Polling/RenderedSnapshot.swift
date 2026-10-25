import AeolusLeaseControl
import AeolusXPC
import Foundation

/// The snapshot `PollingViewModel` has on screen, when its reply arrived, and the lease driver's
/// ticket for the read that brought it (ADR 0015 D2).
///
/// **One value**, so a render replaces the ticket with the snapshot and a withdrawal clears both:
/// the ticket on screen is always the one taken for the snapshot on screen, never an earlier
/// read's beside a later reply. The view model holds it `private`, and exposes each part through a
/// get-only accessor (`renderedSnapshot`, `renderedReadTicket`).
struct RenderedSnapshot: Equatable {
    let snapshot: SystemSnapshot
    /// This process's wall clock when the reply arrived.
    let receivedAt: Date
    /// Taken before the read was sent, or `nil` from a source with no observer.
    let ticket: LeaseDriver.SnapshotTicket?
}
