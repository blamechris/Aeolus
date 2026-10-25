import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// Quit, logout and closing the last control window give the fans back explicitly, within a
/// bound, and quit tears the connection down only after its release (#155).
@Suite("Lease lifecycle: quit, logout and window close", .timeLimit(.minutes(1)))
@MainActor
struct LeaseLifecycleTests {

    /// Quit sends `releaseLease`, then tears the connection down, then answers the quit, with
    /// "terminate". The app never relies on the helper's invalidation path alone.
    ///
    /// **Mutation (X22):** in `LeaseLifecycle.applicationShouldTerminate`, reply `false`. Red on
    /// the reply.
    ///
    /// **Mutation (no explicit release):** in `LeaseDriver.shutDown`, delete
    /// `await releaseFans()`. Red on the release.
    @Test("Quit sends releaseLease before the connection is torn down")
    func quitReleasesBeforeDisconnect() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: TestMainRunLoop(.atOnce))

        let answer = lifecycle.applicationShouldTerminate(reply: scene.recordReply)
        await scene.ledger.waitFor { $0.index(where: \.isTerminationReply) != nil }

        #expect(answer == .later)
        let entries = await scene.entries
        let released = try #require(
            entries.index(of: .release(held.lease.id)), "an explicit release was sent")
        let disconnected = try #require(entries.index(of: .disconnect))
        let replied = try #require(entries.index(of: .terminationReplied(true)))
        #expect(released < disconnected, "released before the connection was torn down")
        #expect(disconnected < replied)
        #expect(entries.index(of: .releaseAnswered(held.lease.id)) != nil)
        await scene.finish()
    }

    /// A release the helper never answers does not hold the quit: it is answered at the bound,
    /// and the teardown that follows answers the release.
    ///
    /// **Mutation (unbounded wait):** in `LeaseDriver.releaseFans`, return `await task.value`
    /// instead of the bounded outcome. The quit is never answered, and the test is red on its
    /// time limit at the wait for that answer.
    /// **Mutation (M5, "a hand-over between the release and the teardown"):** in
    /// `LeaseLifecycle.applicationShouldTerminate`'s detached task, `await driver.releaseFans()`,
    /// then the `mainRunLoop.perform`, then `await driver.shutDown()`. Red at the requirement that
    /// the teardown is in the ledger: when the reply is recorded, there has been no `.disconnect`.
    /// `.atOnce` delivers on a main-actor task rather than at the hand-over, so this is a race the
    /// mutation loses, not a deterministic pin.
    @Test("Quit is answered within the bound when the release gets no reply")
    func quitIsBounded() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: TestMainRunLoop(.atOnce))

        lifecycle.applicationShouldTerminate(reply: scene.recordReply)
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        let sent = try #require(await scene.entries.first { $0.event == .release(held.lease.id) })
        scene.clock.advance(to: sent.at.advanced(by: LeaseDriver.releaseBound))
        await scene.ledger.waitFor { $0.index(where: \.isTerminationReply) != nil }

        let entries = await scene.entries
        let reply = try #require(entries.first { $0.event == .terminationReplied(true) })
        #expect(reply.at == sent.at.advanced(by: LeaseDriver.releaseBound), "answered at the bound")
        #expect(entries.index(of: .releaseAnswered(held.lease.id)) == nil, "the helper never did")
        let disconnected = try #require(entries.index(of: .disconnect))
        #expect(disconnected < entries.index(of: .terminationReplied(true)) ?? -1)
        await scene.finish()
    }

    /// Closing the last control window, then quitting, then logging out sends one release, not
    /// three: a release in flight is joined, and nothing held sends nothing.
    ///
    /// **Mutation (non-idempotent):** in `LeaseDriver.requestRelease`, for `.releasing` start a
    /// new release of the pending lease instead of returning the one in flight. Red on the count.
    @Test("Close, then quit, then logout sends exactly one release")
    func oneReleaseForThreeEvents() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: TestMainRunLoop(.atOnce))

        // Close: the release is sent and parked; the close is let go at the bound.
        let closing = scene.call { await lifecycle.lastControlWindowClosed() }
        await scene.ledger.waitFor { $0.releases.count == 1 }
        let sent = try #require(await scene.entries.first { $0.event == .release(held.lease.id) })
        scene.clock.advance(to: sent.at.advanced(by: LeaseDriver.releaseBound))
        await scene.waitForReturn(of: closing)

        // Quit, with that release still in flight: joined, bounded, then the teardown answers it.
        // The wait ends on the quit's bound being armed, or on a second release, whichever comes
        // first, so a driver that sends one more is caught by the count below rather than left
        // waiting for a bound its own answered release has already cancelled.
        let quitAt = scene.clock.now
        let quitBound = quitAt.advanced(by: LeaseDriver.releaseBound)
        lifecycle.applicationShouldTerminate(reply: scene.recordReply)
        await firstOf(
            { await scene.clock.untilParked { $0.contains(quitBound) } },
            { await scene.ledger.waitFor { $0.releases.count > 1 } })
        scene.clock.advance(to: quitBound)
        await scene.ledger.waitFor { $0.index(where: \.isTerminationReply) != nil }

        // Logout, after the quit.
        await scene.run { await lifecycle.systemWillPowerOff() }

        #expect(await scene.entries.releases == [held.lease.id], "one release for three events")
        await scene.finish()
    }

    /// Closing the last control window releases the lease, and once the call returns the helper
    /// has answered.
    ///
    /// **Mutation (X6b):** make `LeaseLifecycle.lastControlWindowClosed()` do nothing. Red.
    @Test("Closing the last control window releases")
    func closingReleases() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: TestMainRunLoop(.atOnce))

        await scene.run { await lifecycle.lastControlWindowClosed() }

        #expect(await scene.entries.releases == [held.lease.id])
        #expect(await scene.helper.heldLeases.isEmpty)
        await scene.finish()
    }

    /// Logout releases the lease, and once the call returns the helper has answered.
    ///
    /// **Mutation (X6, Mlogout):** make `LeaseLifecycle.systemWillPowerOff()` do nothing. Red.
    @Test("Logout releases")
    func logoutReleases() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let lifecycle = LeaseLifecycle(driver: scene.driver, mainRunLoop: TestMainRunLoop(.atOnce))

        await scene.run { await lifecycle.systemWillPowerOff() }

        #expect(await scene.entries.releases == [held.lease.id])
        #expect(await scene.helper.heldLeases.isEmpty)
        await scene.finish()
    }

    /// A release asked for while the lease is still being acquired gives the grant straight back
    /// when it arrives, and nothing is applied under it.
    @Test("A release while acquiring gives the grant straight back")
    func aReleaseWhileAcquiring() async throws {
        let scene = await LeaseScene(releaseBound: .seconds(1_000))
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        let outcome = ResultBox<ReleaseOutcome>()
        let releasing = scene.call { outcome.set(await scene.driver.releaseFans()) }
        await scene.waitForState { $0 == .releasing }
        await scene.helper.answerParked(.acquire)
        await scene.waitForReturn(of: releasing)

        #expect(outcome.value == .released)
        let entries = await scene.entries
        #expect(entries.applies.isEmpty, "nothing applied under a grant nobody wanted")
        #expect(entries.releases.count == 1)
        #expect(await scene.driver.state == .released)
        #expect(await scene.helper.heldLeases.isEmpty)
        await scene.finish()
    }
}

extension LeaseScene {

    /// A quit's reply, written to the ledger at the clock's instant when it is called.
    var recordReply: @MainActor @Sendable (Bool) -> Void {
        let ledger = self.ledger
        let clock = self.clock
        return { terminate in
            let at = clock.now
            Task { await ledger.record(.terminationReplied(terminate), at: at) }
        }
    }
}
