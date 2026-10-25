import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// `released` means the helper answered the release; a release it refused or did not answer is a
/// loss (#497's review, C1). `released` is what lets a renderer judge the fans from a snapshot
/// again, so it must never follow a release nothing confirmed.
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

        await scene.ledger.waitFor { $0.acquires.count == 2 }
        #expect(await scene.entries.acquires.map(\.fanIndices) == [[0], [0, 1]])
        #expect(await scene.entries.lost == nil, "the queued take, not a loss")
        await scene.finish()
    }
}
