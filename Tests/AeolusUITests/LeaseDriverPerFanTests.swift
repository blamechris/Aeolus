import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// `takeFan(_:at:)`, `adjustFan(_:to:)` and `releaseFan(_:)` (#154), row by row through the
/// architect's table. Each composes over `take`, `adjust` or `selectAutomatic()` from what is
/// Custom now: the target queued or else in flight or confirmed while held, the acquisition's while
/// acquiring, the `take` waiting on the release while releasing, and nothing otherwise.
///
/// Every assertion is on what reached the fake helper, in the order it handled it, or on the
/// driver's state: never on a call the verb was expected to make. This suite holds the held and
/// acquiring rows; `LeaseDriverPerFanReleasingTests` the rest.
@Suite("Lease driver: one fan at a time", .timeLimit(.minutes(1)))
struct LeaseDriverPerFanTests {

    static func speed(_ rpm: Double) throws -> FanTargetRPM {
        try #require(try LeaseScene.target([0: rpm]).speeds[0])
    }

    /// Waits until the driver holds `target` confirmed, under a lease granted after `mark`.
    static func confirmed(_ target: LeaseTarget, in scene: LeaseScene, since mark: Int) async {
        await scene.waitForState(since: mark) { state in
            if case .held(let held) = state, held.phase == .confirmed(target) { return true }
            return false
        }
    }

    /// The index of each acquire, release answer and apply after `mark`, in the order the helper
    /// handled them.
    static func order(_ entries: [LeaseLedger.Entry]) -> [String] {
        entries.compactMap { entry in
            switch entry.event {
            case .acquire(let request): return "acquire \(request.fanIndices)"
            case .releaseAnswered: return "released"
            case .apply(let settings, _): return "apply \(settings.map(\.fanIndex))"
            default: return nil
            }
        }
    }

    // MARK: - Held

    /// A fan the held lease covers: a re-`apply` under the same lease, the other fan's speed kept.
    @Test("takeFan over a held fan re-applies under the same lease")
    func takeFanOverAHeldFan() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3000])))
        let mark = await scene.mark()

        await scene.driver.takeFan(1, at: try Self.speed(4000))
        let expected = try LeaseScene.target([0: 3000, 1: 4000])
        await Self.confirmed(expected, in: scene, since: mark)

        let entries = await scene.entries
        #expect(entries.applies.last == expected.settings)
        #expect(entries.acquires.count == 1, "the same lease")
        #expect(entries.releases.isEmpty)
        #expect(await scene.driver.state.heldLease?.lease.id == held.lease.id)
        await scene.finish()
    }

    /// A fan the held lease does not cover: a change of which fans are held, release first.
    @Test("takeFan over a new fan is a release, then an acquire over both, then an apply")
    func takeFanOverANewFan() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        let mark = await scene.mark()

        await scene.driver.takeFan(1, at: try Self.speed(4000))
        let expected = try LeaseScene.target([0: 3000, 1: 4000])
        await Self.confirmed(expected, in: scene, since: mark)

        #expect(
            Self.order(Array(await scene.entries.dropFirst(mark)))
                == ["released", "acquire [0, 1]", "apply [0, 1]"])
        #expect(await scene.entries.applies.last == expected.settings)
        await scene.finish()
    }

    /// While an `apply` is in flight with a newer target queued, Custom is the queued target: a
    /// `takeFan` keeps the adjust the user already made.
    ///
    /// **Mutation (M11b, "from sending"):** in `LeaseDriver.custom`, answer `sending` for
    /// `.applying(let sending, _)`. Run: red at the queued target.
    @Test("takeFan composes from the queued target, not the one in flight")
    func takeFanComposesFromTheQueuedTarget() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        let sent = try LeaseScene.target([0: 3000, 1: 3000])
        await scene.driver.take(sent)
        await scene.ledger.waitFor { $0.applies.count == 1 }
        await scene.driver.adjust(try LeaseScene.target([0: 3500, 1: 3000]))

        await scene.driver.takeFan(1, at: try Self.speed(4000))

        let expected = try LeaseScene.target([0: 3500, 1: 4000])
        let phase = await scene.driver.state.heldLease?.phase
        try #require(phase == .applying(sent, queued: expected), "the adjust to 3500 is kept")
        let mark = await scene.mark()
        await scene.helper.answerParked(.apply)
        await Self.confirmed(expected, in: scene, since: mark)
        #expect(await scene.entries.applies.last == expected.settings)
        await scene.finish()
    }

    /// **Mutation (M12, "adjustFan falls back to take"):** in `adjustFan`, call
    /// `takeFan(index, at: speed)` in the guard's `else`. Run: red at `state == before`, for the
    /// fan the lease does not cover.
    @Test("adjustFan moves a held fan, and never changes which fans are held")
    func adjustFanWhileHeld() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        let mark = await scene.mark()

        await scene.driver.adjustFan(0, to: try Self.speed(3500))
        let moved = try LeaseScene.target([0: 3500])
        await Self.confirmed(moved, in: scene, since: mark)
        let before = await scene.driver.state

        await scene.driver.adjustFan(1, to: try Self.speed(4000))

        #expect(await scene.driver.state == before, "a fan the lease does not cover")
        await scene.settle()
        let entries = await scene.entries
        #expect(entries.releases.isEmpty)
        #expect(entries.acquires.count == 1)
        #expect(entries.applies == [try LeaseScene.target([0: 3000]).settings, moved.settings])
        await scene.finish()
    }

    /// Per-fan Auto on one of two held fans: the rest is a new lease, release first.
    ///
    /// **Mutation (M13a, "narrowed through adjust"):** in `releaseFan`, call `adjust(rest)` for
    /// `take(rest)`. Run: red at `state == .releasing`: nothing was released.
    @Test("releaseFan on one of two held fans is a release, then an acquire over the other")
    func releaseFanOfTwo() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3200])) != nil)
        let mark = await scene.mark()

        await scene.driver.releaseFan(1)
        // Set in the verb's own turn, so a verb that sent nothing is red here, not at a time limit.
        try #require(await scene.driver.state == .releasing, "the lease is released first")
        let rest = try LeaseScene.target([0: 3000])
        await Self.confirmed(rest, in: scene, since: mark)

        #expect(
            Self.order(Array(await scene.entries.dropFirst(mark)))
                == ["released", "acquire [0]", "apply [0]"])
        #expect(await scene.driver.state.heldLease?.phase == .confirmed(rest))
        await scene.finish()
    }

    /// Per-fan Auto on the last held fan is Auto: the lease is released and nothing is acquired.
    ///
    /// **Mutation (M13b, "an empty rest does nothing"):** in `releaseFan`, drop the
    /// `selectAutomatic()` call. Run: red at `state == .releasing`.
    @Test("releaseFan on the last held fan releases the lease")
    func releaseFanOfTheLast() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(try LeaseScene.target([0: 3000])))
        let mark = await scene.mark()

        await scene.driver.releaseFan(0)
        try #require(await scene.driver.state == .releasing, "Auto: the lease is released")
        await scene.waitForState(since: mark) { $0.isReleased }
        await scene.settle()

        #expect(await scene.entries.releases == [held.lease.id])
        #expect(await scene.driver.state == .released)
        #expect(await scene.entries.acquires.count == 1)
        await scene.finish()
    }

    @Test("releaseFan on a fan the held lease does not cover does nothing")
    func releaseFanOfAnUncoveredFan() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000])) != nil)
        let before = await scene.driver.state

        await scene.driver.releaseFan(1)

        #expect(await scene.driver.state == before)
        await scene.settle()
        #expect(await scene.entries.releases.isEmpty)
        await scene.finish()
    }

    // MARK: - Acquiring

    /// While acquiring, `takeFan` replaces the acquisition's target with the fan added. The grant
    /// over the old fans is then a change of set.
    @Test("takeFan while acquiring widens the request the grant is applied with")
    func takeFanWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        await scene.driver.takeFan(1, at: try Self.speed(4000))
        #expect(await scene.driver.state == .acquiring(fans: [0, 1]))

        let expected = try LeaseScene.target([0: 3000, 1: 4000])
        let mark = await scene.mark()
        await scene.helper.answerParked(.acquire)
        await Self.confirmed(expected, in: scene, since: mark)
        #expect(await scene.entries.acquires.map(\.fanIndices) == [[0], [0, 1]])
        #expect(await scene.entries.applies == [expected.settings])
        await scene.finish()
    }

    @Test("adjustFan while acquiring refines a requested fan and ignores the others")
    func adjustFanWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        await scene.driver.adjustFan(0, to: try Self.speed(3500))
        await scene.driver.adjustFan(1, to: try Self.speed(4000))
        #expect(await scene.driver.state == .acquiring(fans: [0]))

        let expected = try LeaseScene.target([0: 3500])
        let mark = await scene.mark()
        await scene.helper.answerParked(.acquire)
        await Self.confirmed(expected, in: scene, since: mark)
        #expect(await scene.entries.acquires.map(\.fanIndices) == [[0]])
        #expect(await scene.entries.applies == [expected.settings])
        await scene.finish()
    }

    @Test("releaseFan while acquiring narrows the request, or releases it when none is left")
    func releaseFanWhileAcquiring() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000, 1: 3200]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        await scene.driver.releaseFan(1)
        #expect(await scene.driver.state == .acquiring(fans: [0]))
        await scene.driver.releaseFan(0)
        #expect(await scene.driver.state == .releasing, "nothing is left: Auto")

        let mark = await scene.mark()
        await scene.helper.answerParked(.acquire)
        await scene.waitForState(since: mark) { $0.isReleased }
        await scene.settle()
        let entries = await scene.entries
        #expect(entries.acquires.count == 1)
        #expect(entries.applies.isEmpty, "the grant was given straight back")
        #expect(entries.releases.count == 1)
        await scene.finish()
    }

}

extension LeaseDriverState {

    /// The lease held, when this state holds one.
    var heldLease: HeldLease? {
        if case .held(let held) = self { return held }
        return nil
    }
}
