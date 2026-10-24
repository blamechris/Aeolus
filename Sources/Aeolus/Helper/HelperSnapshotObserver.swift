import AeolusLeaseControl
import AeolusXPC
import Foundation

/// What the lease driver is told about each read on the read connection: a ticket taken
/// **before** `snapshot` is sent, and each successful reply judged with that ticket (#479).
///
/// ## Why the ticket is taken before the request exists
///
/// The read connection and the control connection are two `HelperClient`s, and nothing orders a
/// message on one against a message on the other. A snapshot asked for before the grant was
/// answered can arrive after it without the lease; one asked for before the first `apply` was
/// answered can arrive after it with the fans not yet held. Judging either would end a lease that
/// was fine, for good. `LeaseDriver.observe(_:readWith:)` acts only on what the ticket's moment
/// can prove, and that moment is the one `LeaseDriver.beginSnapshotRead()` was called at. So
/// `HelperSnapshotSource` calls `readWillBeSent` before it creates the request's task, and never
/// after: a ticket taken after the send would be younger than the read it vouches for.
///
/// ## The ticket never leaves this value
///
/// `readWillBeSent` returns the judgement with the ticket already inside it, so the source holds
/// no ticket and cannot pair one read's ticket with another read's reply.
///
/// ## The source does not own the driver
///
/// This is a pair of closures over the driver, not the driver. The source keeps no reference to
/// anything that can take, adjust or release a lease, and a source built with no observer, as in
/// a build with no helper, reads exactly as it did before there was one.
struct HelperSnapshotObserver: Sendable {

    /// What to do with a successful reply to the read the ticket was taken for.
    typealias Judgement = @Sendable (SystemSnapshot) async -> Void

    /// Called immediately before `snapshot` is sent. Returns the judgement for its reply.
    let readWillBeSent: @Sendable () async -> Judgement

    /// The lease driver's: `beginSnapshotRead()` before the read, `observe(_:readWith:)` after.
    static func judging(with driver: LeaseDriver) -> HelperSnapshotObserver {
        HelperSnapshotObserver {
            let ticket = await driver.beginSnapshotRead()
            return { snapshot in await driver.observe(snapshot, readWith: ticket) }
        }
    }
}
