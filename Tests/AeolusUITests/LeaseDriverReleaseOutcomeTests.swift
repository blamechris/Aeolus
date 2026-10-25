import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// A release the helper refused or did not answer, with no `take` queued behind it, ends in `lost`
/// with `.releaseUnconfirmed` (#497's review, C1), and an answered one ends in `released`. These
/// are status lines: since ADR 0015 D3 no claim depends on which, because neither `released` nor
/// `lost` reads the fans as automatic.
@Suite("LeaseDriver — released only when the helper answers the release", .timeLimit(.minutes(1)))
struct LeaseDriverReleaseOutcomeTests {

    /// A release refused, or failed with no answer the client could read.
    static let unconfirmed: [FakeLeaseHelper.Answer] = [
        .refuse(.leaseExpired), .fail(.helperRestarted),
    ]

    /// **Mutation (C1b, "an unconfirmed release is released"):** in
    /// `LeaseDriver.releaseAnswered`, delete the `else if let unconfirmed` branch, so a failed
    /// release ends in `.released` again. Run: red at the loss, for both arguments.
    @Test(
        "A release the helper refused or did not answer ends lost, not released",
        arguments: [0, 1])
    func anUnconfirmedReleaseIsALoss(_ which: Int) async throws {
        let answer = Self.unconfirmed[which]
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, answer)

        // `releaseFans()` returns once the release task has finished, and that task records its
        // answer (`releaseAnswered`) before it does, so the state is final when this returns.
        let outcome = await scene.result { await scene.driver.releaseFans() }

        let state = await scene.driver.state
        let expected: HelperFailure
        switch which {
        case 0: expected = .refused(.leaseExpired)
        default: expected = .failed(.helperRestarted)
        }
        #expect(
            state
                == .lost(
                    LeaseLoss(
                        lease: held.lease, cause: .releaseUnconfirmed(expected), afterWake: false)))
        #expect(outcome == .failed(expected), "the caller's outcome is unchanged")
        await scene.finish()
    }

    @Test("A release the helper answered ends released")
    func anAnsweredReleaseIsReleased() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))

        let outcome = await scene.result { await scene.driver.releaseFans() }

        #expect(await scene.driver.state == .released)
        #expect(await scene.entries.releases == [held.lease.id])
        #expect(outcome == .released)
        await scene.finish()
    }

    /// A change of fans releases, then acquires. When that release is refused the acquisition goes
    /// ahead all the same: the second grant is the helper's to refuse, and the release's answer
    /// is not kept. That is unchanged by C1.
    @Test("A take queued behind an unconfirmed release is still acquired")
    func aQueuedTakeOutlivesAnUnconfirmedRelease() async throws {
        let scene = await LeaseScene()
        _ = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .refuse(.leaseExpired))

        await scene.driver.take(try LeaseScene.target([0: 3000, 1: 3000]))

        try #require(
            await SnapshotTestSupport.eventually { await scene.entries.acquires.count == 2 },
            "the queued take was acquired")
        #expect(await scene.entries.acquires.map(\.fanIndices) == [[0], [0, 1]])
        #expect(await scene.entries.lost == nil, "the queued take, not a loss")
        await scene.finish()
    }

    /// Auto while the acquire is in flight gives the grant straight back on arrival. When the
    /// helper refuses that give-back, nothing says it let the lease go, and the driver says so:
    /// `lost`, with `.releaseUnconfirmed`, on this path as on a release of a held lease (#497's
    /// delta review, MY3).
    ///
    /// **Mutation (MY3):** in `releaseOnArrival`, record the give-back with
    /// `releaseAnswered(id, unconfirmed: nil)` whatever the helper answered. Run: red at the loss.
    @Test("A give-back the helper refuses on the release-on-arrival path ends lost")
    func aRefusedGiveBackOnArrivalIsALoss() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.helper.script(.release, .refuse(.leaseExpired))
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.acquires.count == 1 }
        await scene.driver.selectAutomatic()
        #expect(await scene.driver.state == .releasing)

        let mark = await scene.mark()
        await scene.helper.answerParked(.acquire)
        await scene.waitForState(since: mark) { $0.isReleased || $0.isLost }
        await scene.settle()

        let state = await scene.driver.state
        guard case .lost(let loss) = state else {
            Issue.record("not lost: \(state)")
            await scene.finish()
            return
        }
        #expect(loss.cause == .releaseUnconfirmed(.refused(.leaseExpired)))
        #expect(await scene.entries.applies.isEmpty, "given back on arrival, never applied")
        #expect(await scene.entries.releases.count == 1)
        await scene.finish()
    }
}
