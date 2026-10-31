import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// How the root records a row's Custom and its stepper (#518's review, S1): each is a request for
/// control, so a release made after it is never the user's Auto, and the banner never says "Auto,
/// as you chose" for it. An extension, so these run in `FanRowControlRootTests`, under its time
/// limit.
extension FanRowControlRootTests {

    /// Waits, boundedly in turns, for the ledger to show a state after `mark` that `matches`, then
    /// for the root to publish one. A driver that never gets there, or does nothing at all, is a
    /// red here at once, not a wait until the suite's time limit.
    static func settles(
        _ scene: CompositionScene, since mark: Int,
        _ matches: @escaping @Sendable (LeaseDriverState) -> Bool
    ) async throws {
        try #require(
            await Support.eventually {
                Array(await scene.lease.entries.dropFirst(mark)).states.contains(where: matches)
            }, "the driver did not get there")
        let root = scene.root
        try #require(
            await Support.settle { matches(root.leaseState.current.state) },
            "the root did not publish it: \(root.leaseState.current.state)")
    }

    /// The review's probe. Per-fan Auto on the only fan in Custom is the user's Auto. Custom then
    /// takes the fan again, and fast user switching releases it. Neither the held lease nor that
    /// release follows the Auto.
    ///
    /// **Mutation (X1, "Custom unrecorded"):** in `AppComposition.takeFan`, delete
    /// `leaseState.userAskedForControl()`. Run: red at both expectations after the Auto's.
    @Test("Custom after the user's Auto is a request for control, whatever releases next")
    func customAfterAutoIsARequestForControl() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)
        _ = try await Self.held([0: 3000], on: scene)

        var mark = await scene.lease.mark()
        try await scene.click { actions.chooseAutomatic(fan: 0) }
        try await Self.settles(scene, since: mark) { $0 == .released }
        #expect(scene.root.leaseState.enteredAfterTheUsersAuto, "the Auto was the user's")

        mark = await scene.lease.mark()
        try await scene.click { actions.chooseCustom(fan: 0, on: window.polling) }
        try await Self.settles(scene, since: mark) { $0.isHeld }
        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "the lease Custom took read as following the user's Auto")

        mark = await scene.lease.mark()
        scene.post(NSWorkspace.sessionDidResignActiveNotification)
        try await Self.settles(scene, since: mark) { $0 == .released }
        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "a release after Custom read as the user's Auto")
        await window.close()
        await scene.finish()
    }

    /// Auto then the stepper, clicked back to back while fan 0 is held: the stepper is the user's
    /// last request, so the release the Auto makes is not "as you chose". As
    /// `MonitoringModeBannerTests.autoThenATakeBackToBack` is for a percentage, it holds because
    /// each entry point records its request synchronously, in click order, before its task.
    ///
    /// **Mutation (X2, "the stepper unrecorded"):** in `AppComposition.adjustFan`, delete
    /// `leaseState.userAskedForControl()`. Run: red at the last expectation.
    @Test("Auto then the stepper, clicked back to back, leave the stepper as the last request")
    func autoThenTheStepperBackToBack() async throws {
        let scene = await CompositionScene()
        let window = try await Self.window()
        let actions = FanRowControlActions(composition: scene.root)
        _ = try await Self.held([0: 3000], on: scene)

        let mark = await scene.lease.mark()
        let before = scene.root.latestDriverCall?.ordinal ?? 0
        actions.chooseAutomatic(fan: 0)
        actions.step(.up, from: .init(), fan: 0, on: window.polling)
        let call = try #require(scene.root.latestDriverCall, "the clicks started calls")
        try #require(call.ordinal == before + 2, "the two clicks started two calls")
        await scene.lease.run { await call.finished() }
        try await Self.settles(scene, since: mark) { $0 == .released }

        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "a release after Auto-then-stepper read as the user's Auto")
        await window.close()
        await scene.finish()
    }
}
