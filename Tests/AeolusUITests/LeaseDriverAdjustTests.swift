import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `adjust(_:)` under a lease that is acquiring or held: it moves the speed over the same fans and
/// does nothing over any others; and a target equal to one already sent or confirmed sends nothing
/// more. Each state is read straight after the call, the moment a wrong branch would already have
/// moved it.
@Suite("Lease driver: adjust under a live lease", .timeLimit(.minutes(1)))
struct LeaseDriverAdjustTests {

    /// Held and confirmed, the same fans: one more `apply`, with the new speed, under the same
    /// lease.
    ///
    /// **Mutation (Ma):** in `LeaseDriver.adjust`, make the held-over-the-same-fans case return.
    /// Red on the state.
    @Test("adjust while held moves the speed, with one apply and no acquire")
    func adjustWhileHeld() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        let moved = try LeaseScene.target([0: 4100])

        let from = await scene.mark()
        await scene.driver.adjust(moved)
        guard case .held(let held) = await scene.driver.state else {
            Issue.record("not held after the adjust")
            return
        }
        try #require(held.phase == .applying(moved, queued: nil), "the adjust sent nothing")
        await scene.waitForState(since: from) {
            if case .held(let now) = $0 { now.phase == .confirmed(moved) } else { false }
        }

        let entries = await scene.entries
        #expect(entries.applies.count == 2)
        #expect(entries.applies.last == moved.settings)
        #expect(entries.acquires.count == 1, "under the same lease")
        await scene.finish()
    }

    /// Acquiring: `adjust` over the same fans replaces the target the grant will be applied with.
    ///
    /// **Mutation:** in `LeaseDriver.adjust`, make the `.acquiring` case return. Red on the first
    /// apply.
    @Test("adjust while acquiring refines the first apply")
    func adjustWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }
        let refined = try LeaseScene.target([0: 3500])

        await scene.driver.adjust(refined)
        await scene.helper.answerParked(.acquire)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }

        #expect(await scene.entries.applies == [refined.settings])
        await scene.finish()
    }

    /// Held: `adjust` over other fans sends nothing and changes nothing. Over fan 1 alone it would
    /// otherwise send an `apply` for a fan the lease does not cover, which the helper refuses, and
    /// the driver would end a good lease over it.
    ///
    /// **Mutation:** in `LeaseDriver.adjust`, drop `where held.fans == target.fans`. Red on the
    /// state. **Mutation (Mc):** make the held-over-other-fans case do what `take` does. Red on
    /// the state.
    @Test(
        "adjust over other fans while held changes nothing",
        arguments: [[1: 3000.0], [0: 3000.0, 1: 3000.0]])
    func adjustOverOtherFansWhileHeld(_ speeds: [Int: Double]) async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        let before = await scene.driver.state

        await scene.driver.adjust(try LeaseScene.target(speeds))

        #expect(await scene.driver.state == before, "adjust over other fans moved the lease")
        await scene.settle()
        let entries = await scene.entries
        #expect(entries.applies.count == 1 && entries.acquires.count == 1)
        #expect(entries.releases.isEmpty)
        await scene.finish()
    }

    /// Acquiring: `adjust` over other fans changes nothing, and the grant is applied over the fans
    /// asked for.
    ///
    /// **Mutation (Mb):** in `LeaseDriver.adjust`, drop the acquiring case's fan guard. Red on the
    /// acquires.
    @Test("adjust over other fans while acquiring never acquires")
    func adjustOverOtherFansWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        await scene.driver.adjust(try LeaseScene.target([0: 3000, 1: 3000]))
        await scene.helper.answerParked(.acquire)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }
        await scene.settle()

        let entries = await scene.entries
        #expect(entries.acquires.map(\.fanIndices) == [[0]])
        #expect(entries.releases.isEmpty)
        await scene.finish()
    }

    /// While a change of fans releases, an `adjust` over the **old** fans does not replace the
    /// `take` that is waiting: the new fans are acquired.
    ///
    /// **Mutation (Md):** in `LeaseDriver.adjust`, reduce the releasing guard to `wanted != nil`.
    /// Red on the fans acquired.
    @Test("adjust over the old fans while a change of fans releases is ignored")
    func adjustOverOldFansDuringAChangeOfFans() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000]))
        await scene.helper.script(.release, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000, 1: 3000]))
        await scene.ledger.waitFor { !$0.releases.isEmpty }

        await scene.driver.adjust(try LeaseScene.target([0: 2500]))
        await scene.helper.answerParked(.release)
        await scene.ledger.waitFor { $0.acquires.count == 2 }

        #expect(await scene.entries.acquires.last?.fanIndices == [0, 1])
        await scene.finish()
    }

    // MARK: - Nothing new to send

    /// Taking the target already confirmed sends nothing: no second `apply` of the same speed.
    ///
    /// **Mutation:** in `LeaseDriver.requestApply`, drop `guard target != confirmed`. Red on the
    /// state.
    @Test("A re-take of the confirmed target sends no second apply")
    func aReTakeOfTheConfirmedTarget() async throws {
        let scene = await LeaseScene()
        let target = try LeaseScene.target([0: 3000])
        await scene.take(target)
        let before = await scene.driver.state

        await scene.driver.take(target)

        #expect(await scene.driver.state == before)
        await scene.settle()
        #expect(await scene.entries.applies.count == 1)
        await scene.finish()
    }

    /// While an `apply` is in flight, the latest target equal to the one being sent leaves
    /// nothing queued, so nothing more is sent when it answers.
    ///
    /// **Mutation:** in `LeaseDriver.requestApply`, set `queued = target`. Red on the phase.
    @Test("The latest target equal to the one in flight queues nothing")
    func theLatestEqualToTheOneInFlight() async throws {
        let scene = await LeaseScene()
        let sending = try LeaseScene.target([0: 3000])
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(sending)
        await scene.ledger.waitFor { !$0.applies.isEmpty }

        await scene.driver.adjust(try LeaseScene.target([0: 4000]))
        await scene.driver.adjust(sending)

        guard case .held(let held) = await scene.driver.state else {
            Issue.record("not held")
            return
        }
        #expect(held.phase == .applying(sending, queued: nil))
        await scene.finish()
    }
}
