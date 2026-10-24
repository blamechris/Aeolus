import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// A wake replaces the heartbeat. The beat it replaced cannot change the state once
/// `systemDidWake()` has returned, and a renewal answer that beat already had is not counted:
/// the helper may have given it before the sleep, and only the wake's own renewal says whether
/// the lease survived.
@Suite("Lease driver: wake", .timeLimit(.minutes(1)))
struct LeaseDriverWakeTests {

    /// The replaced beat's renewal is answered, with success, once the wake has replaced the beat
    /// and before the wake's own renewal is answered. The wake's renewal then finds the lease
    /// gone, and the loss says it came after the wake.
    ///
    /// **The test sets the order, not the scheduler** (#486). The wake's own renewal arriving
    /// shows that the wake has run, and so has cancelled the old beat, before the old answer is
    /// given. The wake returning shows that the old beat has finished with that answer before the
    /// wake's renewal is refused. So this red rests on no actor ordering, and the test calls no
    /// `settle()`. Until #486 it answered the old renewal first and then started the wake, and
    /// nothing made the wake reach the driver before that answer did: #486 records the test
    /// passing under the two mutants below in 2 of 46 runs.
    ///
    /// **Mutation (K2a):** in `LeaseDriver.beat`, delete `guard !Task.isCancelled` after the
    /// renewal. The replaced beat counts its old answer and clears the wake: red on `afterWake`.
    /// **Mutation (K2b):** K2a, and restore `held.lease.id == leaseID` to `renewalAccepted`'s
    /// first guard. The old beat's lease is the one held, so the check lets the answer in: red on
    /// `afterWake`.
    @Test("An answer the replaced beat already had does not clear the wake")
    func aReplacedBeatsAnswerIsNotCounted() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parkedThroughCancellation, .parked)
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }

        let waking = scene.call { await scene.driver.systemDidWake() }
        await scene.ledger.waitFor { $0.renewals.count == 2 }
        try #require(await scene.helper.answerOldestParked(.renew), "the old renewal was parked")
        await scene.waitForReturn(of: waking)
        try #require(
            await scene.helper.answerOldestParked(.renew, throwing: AeolusXPCFault.leaseUnknown),
            "the wake's renewal was parked")
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
