import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// Per-fan Auto through the root: which driver verb it reaches, how the root records it, and two
/// quick clicks (#154's ruling Q5, as corrected in #515's first round). An extension, so these run
/// in `FanRowControlRootTests`, under its time limit.
extension FanRowControlRootTests {

    // MARK: - Per-fan Auto, and how it is recorded (Q5)

    /// The only fan in Custom back to Auto: a release, recorded as the user's Auto, so once the
    /// release is answered the state follows it.
    ///
    /// **Mutation (M17, "the record swapped"):** in `AppComposition.releaseFan`, swap
    /// `userAskedForAutomatic()` and `userAskedForControl()`. Run: red at
    /// `enteredAfterTheUsersAuto` here and in each test below that reads it.
    @Test("Auto on the only fan in Custom releases, recorded as the user's Auto")
    func autoOnTheOnlyFan() async throws {
        let scene = await CompositionScene()
        let held = try await Self.held([0: 3000], on: scene)
        let actions = FanRowControlActions(composition: scene.root)

        try await scene.click { actions.chooseAutomatic(fan: 0) }

        try await Root.published(on: scene) { $0 == .released }
        let entries = await scene.lease.entries
        #expect(entries.releases == [held.lease.id])
        #expect(entries.acquires.count == 1)
        #expect(scene.root.leaseState.enteredAfterTheUsersAuto)
        await scene.finish()
    }

    /// One of two fans back to Auto: the driver releases and takes the other again, at its own
    /// speed. That is not the user choosing Auto, so it is recorded as a request for control.
    @Test("Auto on one of two fans in Custom takes the other again, recorded as control")
    func autoOnOneOfTwo() async throws {
        let scene = await CompositionScene()
        let held = try await Self.held([0: 3000, 1: 3200], on: scene)
        let actions = FanRowControlActions(composition: scene.root)

        let mark = await scene.lease.mark()
        try await scene.click { actions.chooseAutomatic(fan: 0) }

        // Ends at either outcome, so a driver that released both is a red here and not a wait.
        await scene.lease.waitForState(since: mark) { state in
            if case .held(let now) = state { return now.fans == [1] }
            return state.isReleased || state.isLost
        }
        try await Root.published(on: scene) { state in
            if case .held(let now) = state {
                now.fans == [1] && now.lease.id != held.lease.id
            } else {
                false
            }
        }
        let entries = await scene.lease.entries
        #expect(entries.releases == [held.lease.id])
        #expect(entries.acquires.map(\.fanIndices) == [[0, 1], [1]])
        #expect(entries.applies.last == [Self.setting(1, 3200)])
        #expect(!scene.root.leaseState.enteredAfterTheUsersAuto)
        await scene.finish()
    }

    /// While releasing, the report cannot say what is in Custom, so per-fan Auto is recorded as a
    /// request for control, even on a one-fan Mac where no other fan could be in Custom, and even
    /// after the user's own Auto for all fans: once the release answers, the state does not
    /// follow an Auto.
    ///
    /// **Mutation (Q5c, "keyed on canRelease"):** in `automaticRoute`, answer `.releaseFan` when
    /// any other fan the report names has `canRelease` (an inlined copy of
    /// `FanControlPresentation.canRelease`), and `.selectAutomatic` otherwise. Run: red at
    /// `enteredAfterTheUsersAuto`. **Mutation (Q5d, "unreadable is nothing"):** in
    /// `automaticRoute`, read `state.fansInCustom ?? []`. Run: red at the same line.
    @Test("Auto on a fan while releasing is recorded as a request for control")
    func autoWhileReleasing() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(Support.snapshot(fans: [Rows.fan(0)]))
        let held = try await Self.held([0: 3000], on: scene)
        await scene.lease.helper.script(.release, .parked)
        try await scene.click { scene.root.selectAutomatic() }
        try await Root.published(on: scene) { $0 == .releasing }
        let drawn = try #require(
            FanRowControlPresentation.Inputs.onScreen(
                fan: 0, in: window.polling, driver: scene.root.leaseState.current))
        #expect(FanRowControlPresentation(drawn, field: .init()).automatic.isEnabled)

        try await scene.click {
            FanRowControlActions(composition: scene.root).chooseAutomatic(fan: 0)
        }
        await scene.lease.helper.answerParked(.release)

        try await Root.published(on: scene) { $0 == .released }
        #expect(await scene.lease.entries.releases == [held.lease.id])
        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "Auto was claimed as the user's choice from a report that cannot say what is in Custom")
        await window.close()
        await scene.finish()
    }

    // MARK: - Two quick clicks

    /// Both fans in Custom, and Auto clicked on each before the root has published anything in
    /// between: both are read against the same report, and each reaches the driver on a task of
    /// its own. The driver composes them one after the other, so the lease is released and
    /// nothing is held or asked for again. The release is parked until both clicks have reached
    /// the driver, as a release that takes longer than two clicks would be.
    ///
    /// **Mutation (Q5e, "the root composes"):** in `AppComposition.releaseFan`'s `.releaseFan`
    /// arm, call `driver.take` of the report's confirmed target without the fan, instead of
    /// `driver.releaseFan(index)`. Run: red at the final state, the acquire count and the held
    /// check.
    @Test("Two quick per-fan Autos over both fans in Custom end with nothing held")
    func twoQuickAutos() async throws {
        let scene = await CompositionScene()
        _ = try await Self.held([0: 3000, 1: 3200], on: scene)
        await scene.lease.helper.script(.release, .parked)
        let actions = FanRowControlActions(composition: scene.root)
        let mark = await scene.lease.mark()

        actions.chooseAutomatic(fan: 0)
        let first = try #require(scene.root.latestDriverCall)
        actions.chooseAutomatic(fan: 1)
        let second = try #require(scene.root.latestDriverCall)
        #expect(second.ordinal == first.ordinal + 1, "each click started its own call")
        await scene.lease.run { await first.finished() }
        await scene.lease.run { await second.finished() }
        #expect(!scene.root.leaseState.enteredAfterTheUsersAuto)
        await scene.lease.helper.answerParked(.release)

        await scene.lease.waitForState(since: mark) { $0.isReleased || $0.isHeld }
        await scene.lease.settle()
        #expect(await scene.lease.driver.state == .released)
        let entries = await scene.lease.entries
        #expect(entries.acquires.count == 1, "nothing was asked for after the first grant")
        #expect(Array(entries.dropFirst(mark)).states.allSatisfy { !$0.isHeld })
        await scene.finish()
    }

    /// The same two clicks, the second once the root has published the release: it reads
    /// `releasing`, which cannot say what is in Custom, and still ends with nothing held.
    @Test("A second per-fan Auto read against releasing still ends with nothing held")
    func aSecondAutoWhileReleasing() async throws {
        let scene = await CompositionScene()
        _ = try await Self.held([0: 3000, 1: 3200], on: scene)
        await scene.lease.helper.script(.release, .parked)
        let actions = FanRowControlActions(composition: scene.root)

        try await scene.click { actions.chooseAutomatic(fan: 0) }
        try await Root.published(on: scene) { $0 == .releasing }
        try await scene.click { actions.chooseAutomatic(fan: 1) }
        await scene.lease.helper.answerParked(.release)

        try await Root.published(on: scene) { $0 == .released }
        await scene.lease.settle()
        #expect(await scene.lease.driver.state == .released)
        #expect(await scene.lease.entries.acquires.count == 1)
        await scene.finish()
    }
}
