import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// Every route into `released`, `lost` and `refused` the driver has, by the event that ends it.
enum FloorPath: CaseIterable {
    /// Auto on a held lease, the release answered.
    case answeredAuto
    /// Auto on a held lease, the release refused or failed: `lost(.releaseUnconfirmed)`.
    case refusedRelease, unansweredRelease
    /// The acquire refused (`refused`), or failed with no answer (`lost(.acquireUnanswered)`).
    case refusedAcquire, unansweredAcquire
    /// Auto while acquiring, a release on arrival: the request grants nothing, or grants and
    /// is given straight back.
    case autoBeforeANullGrant, autoBeforeAGrant
    /// A held lease lost to a refused renewal, a refused `apply`, a snapshot, the connection.
    case renewalRefused, applyRefused, snapshotLoss, connectionLoss
    /// #497's delta review: a loss, a take, Auto, and the loss's release unanswered.
    case lossTakeAutoReleaseUnanswered
    /// #497's delta review: a loss whose release is unanswered, then a refused take.
    case lossThenRefusedTake
    /// #497's delta review: an unconfirmed release, a queued take, Auto, the acquire
    /// unanswered.
    case releaseUnconfirmedThenAutoAcquireFails

    /// Whether `state` is where this path ends.
    func ends(in state: LeaseDriverState) -> Bool {
        switch self {
        case .answeredAuto, .autoBeforeANullGrant, .autoBeforeAGrant,
            .lossTakeAutoReleaseUnanswered, .releaseUnconfirmedThenAutoAcquireFails:
            return state == .released
        case .refusedAcquire, .lossThenRefusedTake:
            if case .refused = state { return true }
            return false
        case .refusedRelease, .unansweredRelease, .unansweredAcquire, .renewalRefused,
            .applyRefused, .snapshotLoss, .connectionLoss:
            return state.isLost
        }
    }

    /// A path asked to drive a group it is not in.
    struct NotInThisGroup: Error {}

    /// Drives `scene` to the event that ends the path, takes a ticket, causes the event, and
    /// returns the ticket.
    func drive(_ scene: LeaseScene) async throws -> LeaseDriver.SnapshotTicket {
        switch self {
        case .answeredAuto, .refusedRelease, .unansweredRelease:
            return try await driveARelease(scene)
        case .refusedAcquire, .unansweredAcquire, .autoBeforeANullGrant, .autoBeforeAGrant:
            return try await driveAnAcquire(scene)
        case .renewalRefused, .applyRefused, .snapshotLoss, .connectionLoss:
            return try await driveALoss(scene)
        case .lossTakeAutoReleaseUnanswered, .lossThenRefusedTake,
            .releaseUnconfirmedThenAutoAcquireFails:
            return try await driveAProbe(scene)
        }
    }

    /// Auto on a held lease, the release parked, then answered as the path says.
    private func driveARelease(_ scene: LeaseScene) async throws -> LeaseDriver.SnapshotTicket {
        let target = try LeaseScene.target([0: 3000])
        switch self {
        case .answeredAuto, .refusedRelease, .unansweredRelease:
            let held = try #require(await scene.take(target))
            await scene.helper.script(.release, .parked)
            await scene.driver.selectAutomatic()
            await scene.ledger.waitFor { $0.releases == [held.lease.id] }
            // Taken while releasing: a floor minted when the release began is not past it.
            let before = await scene.driver.beginSnapshotRead()
            switch self {
            case .refusedRelease:
                await scene.helper.answerParked(.release, throwing: AeolusXPCFault.leaseExpired)
            case .unansweredRelease:
                await scene.helper.answerParked(
                    .release, throwing: HelperClientError.helperRestarted)
            default:
                await scene.helper.answerParked(.release)
            }
            return before
        default:
            throw NotInThisGroup()
        }
    }

    /// An acquire parked, then answered, with or without Auto before it answers.
    private func driveAnAcquire(_ scene: LeaseScene) async throws -> LeaseDriver.SnapshotTicket {
        let target = try LeaseScene.target([0: 3000])
        switch self {
        case .refusedAcquire, .unansweredAcquire:
            await scene.helper.script(.acquire, .parked)
            await scene.driver.take(target)
            await scene.ledger.waitFor { $0.acquires.count == 1 }
            let before = await scene.driver.beginSnapshotRead()
            await scene.helper.answerParked(
                .acquire,
                throwing: self == .refusedAcquire
                    ? AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)
                    : HelperClientError.helperRestarted)
            return before
        case .autoBeforeANullGrant, .autoBeforeAGrant:
            await scene.helper.script(.acquire, .parked)
            await scene.driver.take(target)
            await scene.ledger.waitFor { $0.acquires.count == 1 }
            await scene.driver.selectAutomatic()
            let before = await scene.driver.beginSnapshotRead()
            if self == .autoBeforeAGrant {
                await scene.helper.answerParked(.acquire)
            } else {
                await scene.helper.answerParked(.acquire, throwing: AeolusXPCFault.leaseUnknown)
            }
            return before
        default:
            throw NotInThisGroup()
        }
    }

    /// A held lease, then the event that loses it.
    private func driveALoss(_ scene: LeaseScene) async throws -> LeaseDriver.SnapshotTicket {
        let target = try LeaseScene.target([0: 3000])
        switch self {
        case .renewalRefused:
            await scene.helper.script(.renew, .refuse(.leaseExpired))
            await scene.take(target)
            await scene.clock.untilParked { !$0.isEmpty }
            let before = await scene.driver.beginSnapshotRead()
            scene.clock.advance(to: scene.at(.seconds(10)))
            return before
        case .applyRefused:
            await scene.take(target)
            await scene.helper.script(.apply, .refuse(.leaseUnknown))
            let before = await scene.driver.beginSnapshotRead()
            await scene.driver.take(try LeaseScene.target([0: 3500]))
            return before
        case .snapshotLoss:
            let held = try #require(await scene.take(target))
            let before = await scene.driver.beginSnapshotRead()
            await scene.driver.observe(
                SnapshotTestSupport.snapshot(activeLease: nil), readWith: before)
            await scene.ledger.waitFor { $0.releases == [held.lease.id] }
            return before
        case .connectionLoss:
            await scene.take(target)
            let before = await scene.driver.beginSnapshotRead()
            await scene.helper.pushHealth(.unresponsive)
            return before
        default:
            throw NotInThisGroup()
        }
    }

    /// #497's delta-review probes.
    private func driveAProbe(_ scene: LeaseScene) async throws -> LeaseDriver.SnapshotTicket {
        let target = try LeaseScene.target([0: 3000])
        switch self {
        case .lossTakeAutoReleaseUnanswered:
            let held = try #require(await scene.take(target))
            await scene.helper.script(.release, .parked)
            await scene.helper.pushHealth(.unresponsive)
            await scene.waitForState { $0.isLost }
            await scene.ledger.waitFor { $0.releases == [held.lease.id] }
            await scene.driver.take(target)
            await scene.driver.selectAutomatic()
            try #require(await scene.driver.state == .releasing)
            let before = await scene.driver.beginSnapshotRead()
            await scene.helper.answerParked(
                .release, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
            return before
        case .lossThenRefusedTake:
            await scene.take(target)
            await scene.helper.script(.release, .fail(.helperNeverAnswered(after: .seconds(5))))
            await scene.helper.pushHealth(.unresponsive)
            await scene.waitForState { $0.isLost }
            await scene.ledger.waitFor { !$0.releases.isEmpty }
            await scene.settle()
            await scene.helper.script(.acquire, .parked)
            await scene.driver.take(target)
            await scene.ledger.waitFor { $0.acquires.count == 2 }
            let before = await scene.driver.beginSnapshotRead()
            await scene.helper.answerParked(
                .acquire,
                throwing: AeolusXPCFault.manualControlUnavailable(
                    reason: .leaseHeldByAnotherClient))
            return before
        case .releaseUnconfirmedThenAutoAcquireFails:
            let held = try #require(await scene.take(target))
            await scene.helper.script(.release, .parked)
            await scene.driver.selectAutomatic()
            await scene.ledger.waitFor { $0.releases == [held.lease.id] }
            await scene.driver.take(try LeaseScene.target([0: 3500]))
            await scene.helper.script(.acquire, .parked)
            await scene.helper.answerParked(
                .release, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
            await scene.ledger.waitFor { $0.acquires.count == 2 }
            await scene.driver.selectAutomatic()
            let before = await scene.driver.beginSnapshotRead()
            await scene.helper.answerParked(
                .acquire, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
            return before
        default:
            throw NotInThisGroup()
        }
    }
}
