import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// A wake replaces the heartbeat. The beat it replaced cannot change the state once
/// `systemDidWake()` has returned, and a renewal answer that beat already had is not counted:
/// the helper may have given it before the sleep, and only the wake's own renewal says whether
/// the lease survived.
@Suite("Lease driver: wake", .timeLimit(.minutes(1)))
struct LeaseDriverWakeTests {

    /// The replaced beat's renewal is answered, with success, just before the wake handler runs.
    /// The wake's own renewal then finds the lease gone, and the loss says it came after the wake.
    ///
    /// **Mutation (K2):** in `LeaseDriver.beat`, delete `guard !Task.isCancelled` after the
    /// renewal. The replaced beat counts its old answer and clears the wake: red on `afterWake`.
    @Test("An answer the replaced beat already had does not clear the wake")
    func aReplacedBeatsAnswerIsNotCounted() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parkedThroughCancellation, .parked)
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }

        await scene.helper.answerParked(.renew)
        await scene.run { await scene.driver.systemDidWake() }
        await scene.ledger.waitFor { $0.renewals.count == 2 }
        await scene.helper.answerParked(.renew, throwing: AeolusXPCFault.leaseUnknown)
        await scene.waitForState { $0.isLost }

        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .renewal(.refused(.leaseUnknown)))
        #expect(loss.afterWake, "the wake's own renewal found the loss")
        await scene.finish()
    }

    /// The control: the same renewal answered, and counted, before the wake. The loss the wake's
    /// renewal finds still comes after the wake.
    @Test("An answer counted before the wake leaves the wake to say what survived")
    func anAnswerCountedBeforeTheWake() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parkedThroughCancellation, .parked)
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }

        await scene.helper.answerParked(.renew)
        await scene.ledger.waitFor { $0.contains { $0.event == .renewAnswered(held.lease.id) } }
        await scene.clock.untilParked { $0.contains(scene.at(.seconds(20))) }
        await scene.run { await scene.driver.systemDidWake() }
        await scene.ledger.waitFor { $0.renewals.count == 2 }
        await scene.helper.answerParked(.renew, throwing: AeolusXPCFault.leaseUnknown)
        await scene.waitForState { $0.isLost }

        #expect(try #require(await scene.driver.state.loss).afterWake)
        await scene.finish()
    }

    /// `systemDidWake()` waits for the beat it replaced: with that beat's renewal still unanswered
    /// and deaf to its cancellation, the wake does not return, and it returns once the renewal is
    /// answered.
    ///
    /// **Mutation:** in `LeaseDriver.systemDidWake`, delete `await replaced?.value`. Red on the
    /// first expectation.
    @Test("A wake returns only once the beat it replaced has finished")
    func aWakeWaitsForTheReplacedBeat() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parkedThroughCancellation)
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }

        let waking = scene.call { await scene.driver.systemDidWake() }
        await scene.ledger.waitFor { $0.renewals.count == 2 }
        await scene.settle()
        #expect(!(await scene.hasReturned(waking)), "the wake returned with the old beat running")

        await scene.helper.answerParked(.renew)
        await scene.waitForReturn(of: waking)
        await scene.finish()
    }
}
