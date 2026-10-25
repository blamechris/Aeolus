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
/// ## The ticket stays beside the reply it was taken for
///
/// `readWillBeSent` returns the ticket and the judgement together, with the same ticket already
/// inside the judgement, so the driver judges each reply with its own read's ticket. The source
/// keeps the ticket beside that reply and publishes them together (`HelperSnapshotSource`'s
/// `Authority.fresh`), so the presentation can ask whether the snapshot on screen was read after
/// the driver last let go: its last stop, or a release answered ahead of an acquisition (ADR 0015
/// D2, D5). A ticket only orders reads against the driver's moments: it can take, adjust and
/// release nothing.
///
/// ## The source does not own the driver
///
/// This is a closure over the driver, not the driver. The source keeps no reference to anything
/// that can take, adjust or release a lease, and a source built with no observer, as in a build
/// with no helper, reads exactly as it did before there was one, with no ticket beside any reply.
///
/// ## Every successful reply is judged
///
/// Including one the source will not render: a reply that contradicts itself, or one whose
/// request went out in an earlier episode. The driver's judgement can only end a lease, never
/// claim one, so a reply the display refuses can still show that control ended, and giving the
/// fans back is the direction `CLAUDE.md` rule 6 favours. A failed request has no snapshot, and
/// nothing is judged.
///
/// ## What the source keeps from #478
///
/// The ticket's await is the one suspension added to a cycle. It comes before the episode is
/// stamped and the request is sent, so a request is still stamped with the episode it went out
/// in, and demand is checked again after it, so a last consumer that left during the hop sends
/// nothing. One request is still in flight at a time and none is cancelled, and the freshness
/// stamp is still taken on arrival, before the judgement.
struct HelperSnapshotObserver: Sendable {

    /// What to do with a successful reply to the read the ticket was taken for.
    typealias Judgement = @Sendable (SystemSnapshot) async -> Void

    /// One read, as the driver saw it begin: its ticket, and the judgement of its reply.
    struct Read: Sendable {
        let ticket: LeaseDriver.SnapshotTicket
        let judgement: Judgement
    }

    /// Called immediately before `snapshot` is sent.
    let readWillBeSent: @Sendable () async -> Read

    /// The lease driver's: `beginSnapshotRead()` before the read, `observe(_:readWith:)` after.
    static func judging(with driver: LeaseDriver) -> HelperSnapshotObserver {
        HelperSnapshotObserver {
            let ticket = await driver.beginSnapshotRead()
            return Read(
                ticket: ticket,
                judgement: { snapshot in await driver.observe(snapshot, readWith: ticket) })
        }
    }
}
