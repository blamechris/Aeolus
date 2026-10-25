import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// The rest of the architect's table for the per-fan verbs (#154): while releasing, Custom is the
/// `take` waiting on the release; in `idle`, `released`, `lost` and `refused` nothing is Custom,
/// so `takeFan` takes the fan alone and `adjustFan` and `releaseFan` do nothing.
/// `LeaseDriverPerFanTests` holds the held and acquiring rows.
@Suite(
    "Lease driver: one fan at a time, releasing and with nothing in Custom",
    .timeLimit(.minutes(1)))
struct LeaseDriverPerFanReleasingTests {

    typealias Start = LeaseDriverTakeAdjustTests.Start

    static func speed(_ rpm: Double) throws -> FanTargetRPM {
        try LeaseDriverPerFanTests.speed(rpm)
    }

    static func confirmed(_ target: LeaseTarget, in scene: LeaseScene, since mark: Int) async {
        await LeaseDriverPerFanTests.confirmed(target, in: scene, since: mark)
    }

    // MARK: - Releasing

    /// While a change of set releases, the `take` waiting on it is what is Custom: each verb
    /// changes that `take`, and the release goes on.
    @Test("While releasing, takeFan, adjustFan and releaseFan change the take waiting on it")
    func theVerbsWhileReleasing() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        await scene.helper.script(.release, .parked)
        await scene.driver.takeFan(1, at: try Self.speed(4000))
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        #expect(await scene.driver.state == .releasing)

        await scene.driver.takeFan(2, at: try Self.speed(4200))
        await scene.driver.adjustFan(1, to: try Self.speed(4500))
        await scene.driver.adjustFan(5, to: try Self.speed(5000))
        await scene.driver.releaseFan(0)
        #expect(await scene.driver.state == .releasing)

        let expected = try LeaseScene.target([1: 4500, 2: 4200])
        let mark = await scene.mark()
        await scene.helper.answerParked(.release)
        await Self.confirmed(expected, in: scene, since: mark)
        #expect(await scene.entries.acquires.last?.fanIndices == [1, 2])
        #expect(await scene.entries.applies.last == expected.settings)
        await scene.finish()
    }

    /// Auto's release has no `take` waiting: `takeFan` queues the fan alone, and `adjustFan` and
    /// `releaseFan` find nothing in Custom.
    @Test("While Auto releases, takeFan queues the fan alone; the others find nothing")
    func theVerbsWhileAutoReleases() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        await scene.helper.script(.release, .parked)
        await scene.driver.selectAutomatic()
        await scene.ledger.waitFor { !$0.releases.isEmpty }

        await scene.driver.adjustFan(0, to: try Self.speed(3500))
        await scene.driver.releaseFan(0)
        await scene.driver.takeFan(1, at: try Self.speed(4000))

        let expected = try LeaseScene.target([1: 4000])
        let mark = await scene.mark()
        await scene.helper.answerParked(.release)
        await Self.confirmed(expected, in: scene, since: mark)
        #expect(await scene.entries.acquires.last?.fanIndices == [1])
        await scene.finish()
    }

    /// Per-fan Auto on the last fan the waiting `take` names leaves nothing waiting.
    @Test("While releasing, releaseFan of the last waiting fan leaves nothing to acquire")
    func releaseFanOfTheLastWaitingFan() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        await scene.helper.script(.release, .parked)
        await scene.driver.takeFan(1, at: try Self.speed(4000))
        await scene.ledger.waitFor { !$0.releases.isEmpty }

        await scene.driver.releaseFan(0)
        await scene.driver.releaseFan(1)

        let mark = await scene.mark()
        await scene.helper.answerParked(.release)
        await scene.waitForState(since: mark) { $0.isReleased || $0.isHeld }
        await scene.settle()
        #expect(await scene.driver.state == .released)
        #expect(await scene.entries.acquires.count == 1)
        await scene.finish()
    }

    // MARK: - Nothing in Custom

    /// From a state with nothing in Custom, `takeFan` takes the fan alone. After a loss, nothing
    /// that was held is composed over: a loss is final.
    ///
    /// **Mutation (M11a, "composed after a loss"):** give `takeFan` a remembered target, set each
    /// time it takes and used when `custom` is `nil` (`custom ?? remembered`). Run: red at
    /// `acquiring(fans: [1])`, from `lost` and `released`.
    @Test(
        "takeFan from a state with nothing in Custom takes the fan alone",
        arguments: Start.allCases)
    func takeFanFromNothing(_ start: Start) async throws {
        let scene = await LeaseScene()
        // Reached through `takeFan` itself, so a verb that remembered what it took has something
        // to remember.
        if start == .lost || start == .released {
            try await Self.holdTwoFansByTakeFan(in: scene)
        }
        try await Self.reachWithoutTaking(start, in: scene)
        let mark = await scene.mark()

        await scene.driver.takeFan(1, at: try Self.speed(4000))
        try #require(
            await scene.driver.state == .acquiring(fans: [1]), "the fan alone, from \(start)")
        let expected = try LeaseScene.target([1: 4000])
        await Self.confirmed(expected, in: scene, since: mark)

        #expect(await scene.entries.acquires.last?.fanIndices == [1], "\(start)")
        #expect(await scene.entries.applies.last == expected.settings, "\(start)")
        await scene.finish()
    }

    /// **Mutation (M12):** red at the acquire count and the state, for every start.
    @Test(
        "adjustFan and releaseFan with nothing in Custom do nothing", arguments: Start.allCases)
    func adjustAndReleaseFanFromNothing(_ start: Start) async throws {
        let scene = await LeaseScene()
        try await LeaseDriverTakeAdjustTests.reach(start, in: scene)
        let before = await scene.driver.state
        let entriesBefore = await scene.entries

        await scene.driver.adjustFan(0, to: try Self.speed(3500))
        #expect(await scene.driver.state == before, "adjustFan moved \(start) on")
        await scene.driver.releaseFan(0)
        #expect(await scene.driver.state == before, "releaseFan moved \(start) on")

        await scene.settle()
        let entries = await scene.entries
        #expect(entries.acquires.count == entriesBefore.acquires.count, "no acquire from \(start)")
        #expect(entries.applies.count == entriesBefore.applies.count, "no apply from \(start)")
        #expect(entries.releases.count == entriesBefore.releases.count, "\(start)")
        await scene.finish()
    }

    // MARK: - Reaching a start

    /// Fan 0, then fan 1, each put in Custom with `takeFan`.
    static func holdTwoFansByTakeFan(in scene: LeaseScene) async throws {
        var mark = await scene.mark()
        await scene.driver.takeFan(0, at: try Self.speed(3000))
        await Self.confirmed(try LeaseScene.target([0: 3000]), in: scene, since: mark)
        mark = await scene.mark()
        await scene.driver.takeFan(1, at: try Self.speed(3200))
        await Self.confirmed(try LeaseScene.target([0: 3000, 1: 3200]), in: scene, since: mark)
    }

    /// `start` from a lease already held, or from nothing, without another take.
    static func reachWithoutTaking(_ start: Start, in scene: LeaseScene) async throws {
        switch start {
        case .idle, .refused:
            try await LeaseDriverTakeAdjustTests.reach(start, in: scene)
        case .lost:
            let held = try #require(await scene.driver.state.heldLease)
            await scene.driver.observe(
                LeaseDriverLossTests.snapshot([], listing: nil, emergency: true),
                readWith: await scene.driver.beginSnapshotRead())
            try #require(await scene.driver.state.isLost)
            await scene.ledger.waitFor { $0.releases.contains(held.lease.id) }
        case .released:
            await scene.run { await scene.driver.releaseFans() }
            try #require(await scene.driver.state == .released)
        }
    }
}
