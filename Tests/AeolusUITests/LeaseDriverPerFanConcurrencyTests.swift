import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// Two per-fan verbs at once (#515's panel, ordering S1). Each verb reads what is Custom and acts
/// on it in one turn of the driver's actor, with no suspension between, so two of them racing
/// compose one after the other: the second sees what the first asked for. A verb that suspended
/// between the read and the act would let both compose from the same Custom, and the later one
/// would undo the earlier one's change.
///
/// Both calls start from one task group, so neither is ordered before the other.
extension LeaseDriverPerFanTests {

    /// Both fans of a held lease back on Auto at once: whichever goes first takes the other fan
    /// alone, and the second finds that fan the last in Custom and releases. Nothing is acquired
    /// after the original grant.
    ///
    /// **Mutation (O13, "a suspension in releaseFan"):** make `releaseFan` `async` and put
    /// `await Task.yield()` after its guard. Run: red at `state == .released` and at the acquire
    /// count: both compose from both fans, and the later `take` of one fan is acquired.
    @Test("Two releaseFans at once over a held pair end released, acquiring nothing more")
    func twoReleaseFansAtOnce() async throws {
        let scene = await LeaseScene()
        try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3200])) != nil)
        // Parked, so the state both verbs leave can be read before the release answers.
        await scene.helper.script(.release, .parked)
        let mark = await scene.mark()

        let driver = scene.driver
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await driver.releaseFan(0) }
            group.addTask { await driver.releaseFan(1) }
        }
        try #require(await scene.driver.state == .releasing, "the first verb released the lease")
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        await scene.helper.answerParked(.release)
        await scene.waitForState(since: mark) { $0.isReleased || $0.isHeld }
        await scene.settle()

        #expect(await scene.driver.state == .released)
        #expect(await scene.entries.acquires.count == 1, "only the original grant was asked for")
        await scene.finish()
    }

    /// Two fans put in Custom at once from `idle`: the second composes over the first's request,
    /// so the acquisition asks for both.
    ///
    /// **Mutation (O14, "a suspension in takeFan"):** make `takeFan` `async`, compose the target,
    /// `await Task.yield()`, then `take` it. Run: red at `.acquiring(fans: [0, 1])`: both compose
    /// from nothing, and the later one asks for its fan alone.
    @Test("Two takeFans at once from idle ask for both fans")
    func twoTakeFansAtOnce() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)

        let driver = scene.driver
        let speed = try Self.speed(3000)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await driver.takeFan(0, at: speed) }
            group.addTask { await driver.takeFan(1, at: speed) }
        }

        #expect(await scene.driver.state == .acquiring(fans: [0, 1]))
        await scene.finish()
    }
}
