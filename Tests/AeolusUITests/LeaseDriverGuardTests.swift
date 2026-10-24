import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// The guards a review found nothing pinning: each test here goes red when its guard is deleted,
/// and the guard is named on the test.
@Suite("Lease driver: the guards", .timeLimit(.minutes(1)))
struct LeaseDriverGuardTests {

    typealias Loss = LeaseDriverLossTests

    // MARK: - Replies are matched to their lease

    /// An `apply` of an old lease answered with success after a new lease is held changes nothing
    /// about the new one: its phase is not set from a target it never sent.
    ///
    /// **Mutation (MC):** in `LeaseDriver.applyAccepted`, drop `held.lease.id == leaseID`. Red
    /// on the phase.
    @Test("A stale apply success under an old lease leaves the new lease applying")
    func staleApplySuccessUnderAnOldLease() async throws {
        let scene = await LeaseScene()
        let first = try LeaseScene.target([0: 2000])
        let second = try LeaseScene.target([0: 4000])
        await scene.helper.script(.apply, .after(.seconds(57)), .parked)
        // The old lease's release is refused, so the old apply can still succeed at 57 s.
        await scene.helper.script(.release, .refuse(.leaseUnknown))
        try await Self.loseByHealth(taking: first, in: scene)
        await scene.driver.take(second)
        await scene.ledger.waitFor { $0.applies.count == 2 }

        scene.clock.advance(to: scene.at(.seconds(57)))
        await scene.ledger.waitFor { $0.index(where: \.isApplyAnswer) != nil }
        await scene.settle()

        guard case .held(let held) = await scene.driver.state else {
            Issue.record("the new lease is not held")
            return
        }
        #expect(held.phase == .applying(second, queued: nil), "\(held.phase)")
        await scene.finish()
    }

    /// An `apply` answered with success after its lease was lost leaves `lost` as it is. Drawing
    /// `held` again would claim control the helper had ended.
    ///
    /// **Mutation (MC2):** in `LeaseDriver.applyAccepted`, also accept `.lost` whose lease is
    /// `leaseID`, rebuilding a `HeldLease` from it. Red on the state.
    @Test("A stale apply success after a loss leaves the state lost")
    func staleApplySuccessAfterALoss() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.helper.script(.release, .parked)
        try await Self.loseByHealth(taking: LeaseScene.target([0: 3000]), in: scene)

        await scene.helper.answerParked(.apply)
        await scene.ledger.waitFor { $0.index(where: \.isApplyAnswer) != nil }
        await scene.settle()

        let state = await scene.driver.state
        #expect(state.isLost, "\(state)")
        await scene.finish()
    }

    /// An `apply` of an old lease that fails after a new lease is held does not end the new one.
    ///
    /// **Mutation (ME):** in `LeaseDriver.lose`, drop `held.lease.id == leaseID`. Red on the
    /// state.
    @Test("A stale apply failure under an old lease leaves the new lease held")
    func staleApplyFailureUnderAnOldLease() async throws {
        let scene = await LeaseScene()
        let first = try LeaseScene.target([0: 2000])
        let second = try LeaseScene.target([0: 4000])
        await scene.helper.script(.apply, .after(.seconds(57)), .parked)
        try await Self.loseByHealth(taking: first, in: scene)
        await scene.driver.take(second)
        await scene.ledger.waitFor { $0.applies.count == 2 }

        // The old lease was released, so its apply is refused when it answers.
        scene.clock.advance(to: scene.at(.seconds(57)))
        await scene.ledger.waitFor { $0.index(where: \.isApplyAnswer) != nil }
        await scene.settle()

        let state = await scene.driver.state
        #expect(state.isHeld, "\(state)")
        await scene.finish()
    }

    /// A renewal of an old lease answered after a new lease is held does not put the old lease
    /// in the new one's place.
    ///
    /// **Mutation (Z4):** in `LeaseDriver.renewalAccepted`, drop `held.lease.id == leaseID`. Red
    /// on the lease the state shows.
    @Test("A stale renewal answer under an old lease leaves the new lease's state alone")
    func staleRenewalUnderAnOldLease() async throws {
        let scene = await LeaseScene()
        let first = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.clock.untilParked { !$0.isEmpty }
        await scene.helper.script(.renew, .parkedThroughCancellation)
        await scene.helper.script(.release, .refuse(.leaseUnknown))
        scene.clock.advance(to: scene.at(.seconds(10)))
        await scene.ledger.waitFor { $0.renewals.count == 1 }
        await scene.driver.observe(
            Loss.snapshot([], listing: nil), readWith: await scene.driver.beginSnapshotRead())
        try #require(await scene.driver.state.isLost)
        let second = try #require(await scene.take(LeaseScene.target([0: 3000])))

        await scene.helper.answerParked(.renew)
        await scene.ledger.waitFor { $0.contains { $0.event == .renewAnswered(first.lease.id) } }
        await scene.settle()

        guard case .held(let held) = await scene.driver.state else {
            Issue.record("the new lease is not held")
            return
        }
        #expect(held.lease.id == second.lease.id, "the state shows the old lease")
        await scene.finish()
    }

    // MARK: - Tickets

    /// A ticket taken under one lease is not evidence about the next: the app's own old lease is
    /// not drawn as another holder.
    ///
    /// **Mutation:** in `LeaseDriver.granted`, set `epoch = 0` before it is counted on. Red on the
    /// first expectation.
    @Test("A ticket from an earlier lease is not judged")
    func aTicketFromAnEarlierLease() async throws {
        let scene = await LeaseScene()
        let first = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let stale = await scene.driver.beginSnapshotRead()
        let second = try #require(await scene.take(LeaseScene.target([0: 3000, 1: 3000])))
        #expect(second.lease.id != first.lease.id)
        let listingTheFirst = Loss.snapshot([Loss.fan(0, target: 3000)], listing: first.lease)

        await scene.driver.observe(listingTheFirst, readWith: stale)
        #expect(await scene.driver.state.isHeld, "a ticket from the first lease was judged")

        await scene.driver.observe(
            listingTheFirst, readWith: await scene.driver.beginSnapshotRead())
        #expect(await scene.driver.state.isLost)
        await scene.finish()
    }

    /// `covering` is the granted lease's fans, all of them: a two-fan lease whose second fan is
    /// not held is lost, and the loss names that fan.
    ///
    /// **Mutation:** in `LeaseDriver.observe`, pass `covering: [0]`. Red on the loss.
    @Test("Every fan the grant covers is judged")
    func everyCoveredFanIsJudged() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000, 1: 3000])))

        await scene.driver.observe(
            Loss.snapshot(
                [Loss.fan(0, target: 3000), Loss.fan(1, target: nil)], listing: held.lease),
            readWith: await scene.driver.beginSnapshotRead())

        let loss = try #require(await scene.driver.state.loss)
        #expect(loss.cause == .snapshot(.fanNotHeld(fan: 1), isThermalEmergencyActive: false))
        await scene.finish()
    }

    // MARK: - Ordering across a change of lease

    /// A `take` after a loss waits for that loss's release to answer before it acquires, so the
    /// helper never sees the new request while it still lists the old lease.
    ///
    /// **Mutation:** in `LeaseDriver.startAcquisition`, set `previous = nil`. Red on the order.
    @Test("A take after a loss acquires only once the loss's release answered")
    func aTakeAfterALossWaitsForTheRelease() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.observe(
            Loss.snapshot([], listing: nil), readWith: await scene.driver.beginSnapshotRead())
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }

        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.settle()
        #expect(await scene.entries.acquires.count == 1, "acquired with the release in flight")

        await scene.helper.answerParked(.release)
        await scene.ledger.waitFor { $0.acquires.count == 2 }
        let entries = await scene.entries
        let answered = try #require(entries.index(of: .releaseAnswered(held.lease.id)))
        let second = try #require(
            entries.indices.filter { entries[$0].event.isAcquire }.dropFirst().first)
        #expect(answered < second)
        await scene.finish()
    }

    /// Fans changed while the request was in flight: the grant, which covers the old fans, is
    /// released and the new fans are asked for, rather than applied under a lease that does not
    /// cover them.
    ///
    /// **Mutation:** in `LeaseDriver.granted`, delete the `pending.target.fans ==
    /// request.fanIndices` guard. Red on the fans held and the acquires.
    @Test("A change of fans during the acquire is release, then acquire")
    func aChangeOfFansDuringTheAcquire() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }
        let wider = try LeaseScene.target([0: 3000, 1: 3000])
        await scene.driver.take(wider)

        await scene.helper.answerParked(.acquire)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }

        guard case .held(let held) = await scene.driver.state else {
            Issue.record("not held")
            return
        }
        #expect(held.fans == [0, 1], "applied under a lease that does not cover fan 1")
        let entries = await scene.entries
        #expect(entries.acquires.map(\.fanIndices) == [[0], [0, 1]])
        #expect(entries.releases.count == 1)
        await scene.finish()
    }

    /// Auto while a `take` waits for an earlier release: the request it was waiting to send is
    /// never sent.
    ///
    /// **Mutation:** in `LeaseDriver.acquire`, drop `!pending.releaseOnArrival`. Red on the
    /// acquire count.
    @Test("Auto before the queued acquire is sent means it is never sent")
    func autoBeforeTheQueuedAcquire() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.observe(
            Loss.snapshot([], listing: nil), readWith: await scene.driver.beginSnapshotRead())
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        await scene.driver.take(try LeaseScene.target([0: 3000]))

        await scene.driver.selectAutomatic()
        await scene.helper.answerParked(.release)
        await scene.waitForState { $0.isReleased }

        #expect(await scene.entries.acquires.count == 1, "the queued acquire was sent anyway")
        await scene.finish()
    }

    // MARK: - Fixtures

    /// Takes `target`, and ends the lease by its connection's health while its first `apply` is
    /// still outstanding.
    static func loseByHealth(taking target: LeaseTarget, in scene: LeaseScene) async throws {
        await scene.driver.take(target)
        await scene.ledger.waitFor { !$0.applies.isEmpty && $0.healthAsks >= 2 }
        await scene.helper.pushHealth(.interrupted)
        await scene.waitForState { $0.isLost }
        await scene.ledger.waitFor { !$0.releases.isEmpty }
    }
}
