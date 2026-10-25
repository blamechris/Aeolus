import AeolusXPC
import AeolusXPCClient
import AppKit
import Combine
import FanKit
import Foundation
import SwiftUI
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The all-fans control through the root: what a click sends, what the window then draws, and
/// that every entry point is the root's own, on a task of its own (#153's PR 6b, #419).
///
/// Every scene is `CompositionScene`, so the root, its driver and the fake control helper are the
/// ones `AppCompositionLeaseTests` drives. No test awaits a driver call or a task's value: each
/// waits on the fake's ledger, boundedly, or for the root's published state.
@Suite("All fans — through the root", .timeLimit(.minutes(1)))
@MainActor
struct AllFansControlRootTests {

    typealias Fans = AllFansFixtures
    typealias Support = SnapshotTestSupport

    // MARK: - A click takes; Auto releases

    /// From `idle`, a segment acquires every fan on screen and applies the percentage's speed to
    /// each, from the snapshot on screen.
    ///
    /// **Mutation (M1, "a segment adjusts"):** in `AllFansControlActions.choose`, call
    /// `composition.adjust(target)` instead of `take`. Run: red at the acquire: `adjust` never
    /// acquires, so the click does nothing from `idle`.
    @Test("A percentage from idle takes every fan, at the speed it names")
    func aPercentageTakesEveryFan() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        #expect(window.control(scene.root.leaseState.current).percentsAreEnabled)

        AllFansControlActions(composition: scene.root).choose(.seventyFive, on: window.polling)

        try #require(
            await Support.eventually { await scene.lease.entries.acquires.count == 1 },
            "the click asked for the fans")
        #expect(await scene.lease.entries.acquires.map(\.fanIndices) == [[0, 1]])
        try #require(
            await Support.eventually { await !scene.lease.entries.applies.isEmpty },
            "the grant was applied")
        #expect(
            await scene.lease.entries.applies == [try Fans.settings(.seventyFive, fans: [0, 1])])
        await window.close()
        await scene.finish()
    }

    /// 50 %, then 75 %: the second click is a `take` too, and while the same fans are held it is a
    /// re-apply under the same lease.
    @Test("A second percentage re-applies under the same lease")
    func aSecondPercentageReapplies() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let actions = AllFansControlActions(composition: scene.root)
        actions.choose(.fifty, on: window.polling)
        let held = try await Self.confirmed(.fifty, fans: [0, 1], on: scene)
        try await window.show(Fans.holding(held.lease, [0, 1], at: .fifty))
        try await Self.published(on: scene) { $0 == .held(held) }
        #expect(window.control(scene.root.leaseState.current).selection == .percent(.fifty))

        actions.choose(.seventyFive, on: window.polling)

        _ = try await Self.confirmed(.seventyFive, fans: [0, 1], on: scene)
        let entries = await scene.lease.entries
        #expect(entries.acquires.count == 1, "one lease")
        #expect(
            entries.applies
                == [
                    try Fans.settings(.fifty, fans: [0, 1]),
                    try Fans.settings(.seventyFive, fans: [0, 1]),
                ])
        await window.close()
        await scene.finish()
    }

    @Test("Auto releases the lease through the root")
    func autoReleases() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0])))

        AllFansControlActions(composition: scene.root).chooseAutomatic()

        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] })
        await scene.lease.waitForState { $0.isReleased }
        await scene.finish()
    }

    /// A held lease, and the window's snapshot withdrawn: every fan's control is disabled, the
    /// release is still offered, and it reaches the driver through the root.
    @Test("The release offer reaches the driver while the control is disabled")
    func theReleaseOfferWorksWhileDisabled() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let held = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0, 1])))
        try await Self.published(on: scene) { $0 == .held(held) }
        try await SnapshotTestSupport.report(.unresponsive, to: window.source, from: window.helper)
        window.polling.reassessAuthority()

        let control = window.control(scene.root.leaseState.current)
        #expect(control.affordance != .enabled)
        #expect(control.offersRelease)
        #expect(control.automaticIsEnabled)
        AllFansControlActions(composition: scene.root).chooseAutomatic()

        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] })
        await window.close()
        await scene.finish()
    }

    // MARK: - The root's three entry points

    @Test("take from the root acquires and applies")
    func rootTake() async throws {
        let scene = await CompositionScene()
        let target = try Fans.target(.hundred, fans: [0])

        scene.root.take(target)

        _ = try await Self.confirmed(.hundred, fans: [0], on: scene)
        #expect(await scene.lease.entries.acquires.count == 1)
        await scene.finish()
    }

    /// `adjust` has no caller until PR 8's slider. It moves a held lease's speed, and from `idle`
    /// it acquires nothing.
    @Test("adjust from the root moves a held speed, and never acquires")
    func rootAdjust() async throws {
        let scene = await CompositionScene()
        scene.root.adjust(try Fans.target(.fifty, fans: [0]))
        let acquired = await Support.eventually(turns: 2_000) {
            await !scene.lease.entries.acquires.isEmpty
        }
        #expect(!acquired, "adjust never acquires")

        _ = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0])))
        scene.root.adjust(try Fans.target(.seventyFive, fans: [0]))

        _ = try await Self.confirmed(.seventyFive, fans: [0], on: scene)
        #expect(await scene.lease.entries.acquires.count == 1)
        await scene.finish()
    }

    @Test("selectAutomatic from the root releases")
    func rootSelectAutomatic() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0])))

        scene.root.selectAutomatic()

        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] })
        await scene.finish()
    }

    // MARK: - #419: the UI never cancels a sequenced verb

    /// The caller is cancelled before it calls `take`, and both sequenced verbs are parked so that
    /// a cancelled caller would be answered at once with `CancellationError`. The acquire and the
    /// apply are still each answered by the test, neither caller cancelled, and the lease is held.
    ///
    /// What holds it is two facts, and this test can see only their sum. The root's entry point
    /// starts a task of its own, and a caller's cancellation does not reach an unstructured task.
    /// The driver then sends `acquireLease` and `apply` from tasks of its own too
    /// (`LeaseDriver.startAcquisition`, `granted`, `requestApply`). Either alone keeps the verbs
    /// off the cancelled task, so a mutation of the root alone is masked by the driver.
    ///
    /// **Mutation (M7, "the root awaits in the caller's task"):** make `AppComposition.take`
    /// `async`, awaiting `driver.take(target)`, and await it here. Run: green, as reasoned: the
    /// driver's own tasks still carry the verbs. The root's half is held by the compiler instead:
    /// `AllFansControlActions.choose` and every view action are synchronous and call the entry
    /// points without `await`, so an `async` entry point does not compile there.
    /// **Mutation (M7′, "the verbs on the caller's task"):** as M7, and in `LeaseDriver.take`'s
    /// first arm run the acquisition inline (`await acquire(id, after: previous)`) instead of on
    /// `acquiring`'s task. Run: red at `!early`: the parked acquire is answered with
    /// `CancellationError`, and the driver reports the acquire unanswered.
    @Test("A take from a cancelled caller still acquires and applies (#419)")
    func aCancelledCallerCancelsNothing() async throws {
        let scene = await CompositionScene()
        await scene.lease.helper.script(.acquire, .parked)
        await scene.lease.helper.script(.apply, .parked)
        let target = try Fans.target(.fifty, fans: [0, 1])
        let root = scene.root
        let cancelledAtTheCall = ResultBox<Bool>()

        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            cancelledAtTheCall.set(Task.isCancelled)
            root.take(target)
        }
        try #require(await Support.eventually { cancelledAtTheCall.value != nil })
        #expect(cancelledAtTheCall.value == true, "the caller was cancelled when it called take")
        caller.cancel()

        try #require(
            await Support.eventually { await scene.lease.entries.acquires.count == 1 },
            "the acquire was sent")
        let early = await Support.eventually(turns: 2_000) {
            let entries = await scene.lease.entries
            return entries.contains { $0.event == .acquireAnswered } || entries.lost != nil
        }
        #expect(!early, "the parked acquire was not answered by the caller's cancellation")
        await scene.lease.helper.answerParked(.acquire)
        try #require(
            await Support.eventually { await !scene.lease.entries.applies.isEmpty },
            "the grant was applied")
        await scene.lease.helper.answerParked(.apply)
        _ = try await Self.confirmed(.fifty, fans: [0, 1], on: scene)

        let entries = await scene.lease.entries
        let answered = entries.compactMap { entry -> Bool? in
            if case .applyAnswered(_, let cancelled) = entry.event { cancelled } else { nil }
        }
        #expect(answered == [false], "the apply was answered to a caller nobody cancelled")
        #expect(entries.lost == nil, "nothing was lost")
        #expect(entries.acquires.count == 1)
        await scene.finish()
    }

    // MARK: - The driver's state reaches the window through the root

    /// Held at 50 % with the window showing it, then a refused renewal ends the lease, and **no
    /// snapshot arrives**. The root's published state moves to `lost`, it announces the change, so
    /// a view observing it is redrawn, and the control drawn from it no longer selects 50 %.
    ///
    /// **Mutation (M6a, "no state task"):** in `AppComposition.init`'s `.embedded` arm, build
    /// `LeaseStateModel()` instead of following the driver. Run: red at `published(held)`.
    /// **Mutation (M6b, "the change is not announced"):** in `LeaseStateModel.publish`, delete
    /// `objectWillChange.send()`. Run: red at `announced`, with `current` correct: the state moved
    /// and no view would have been told.
    /// **Mutation (M5, "the last click is the selection"):** have `AllFansControlActions.choose`
    /// record the percentage, and `AllFansControlPresentation.selection` return it when one is
    /// recorded. Run: red at the selection after the loss.
    @Test("A loss with no new snapshot re-renders the control, and selects nothing")
    func aLossWithNoSnapshotRerenders() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        AllFansControlActions(composition: scene.root).choose(.fifty, on: window.polling)
        let held = try await Self.confirmed(.fifty, fans: [0, 1], on: scene)
        try await window.show(Fans.holding(held.lease, [0, 1], at: .fifty))
        try await Self.published(on: scene) { $0 == .held(held) }
        #expect(window.control(scene.root.leaseState.current).selection == .percent(.fifty))
        let revision = window.polling.revision
        let snapshot = window.polling.renderedSnapshot

        var announcements = 0
        let sink = scene.root.leaseState.objectWillChange.sink { announcements += 1 }
        await scene.lease.helper.script(.renew, .refuse(.leaseUnknown))
        await scene.lease.clock.untilParked { !$0.isEmpty }
        scene.lease.clock.advance(to: scene.lease.at(.seconds(10)))
        try await Self.published(on: scene) { $0.isLost }
        sink.cancel()

        #expect(window.polling.revision == revision, "no snapshot moved the window")
        #expect(window.polling.renderedSnapshot == snapshot)
        #expect(announcements > 0, "announced: the change of state re-renders an observer")
        let control = window.control(scene.root.leaseState.current)
        #expect(control.selection == .none)
        #expect(control.statusLines.map(\.value.text) == ["Control ended."])
        #expect(!control.percentsAreEnabled, "the snapshot on screen still lists the lost lease")
        await window.close()
        await scene.finish()
    }

    // MARK: - Fail closed at the click

    /// Drawn enabled, then a snapshot in which fan 1 is refused renders before the click. The click
    /// reads the screen again and sends nothing.
    ///
    /// **Mutation (M10, "the click trusts the drawing"):** delete the
    /// `allSatisfy { ... == .enabled }` guard in `AllFansControlPresentation.target`. Run: red at
    /// `!sent`: the click acquires both fans, one of them a fan the helper refuses.
    @Test("A fan disabled between drawing and the click sends nothing")
    func aFanDisabledBeforeTheClickSendsNothing() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let drawn = window.control(scene.root.leaseState.current)
        #expect(drawn.percentsAreEnabled)

        try await window.show(
            Support.snapshot(fans: [Fans.offered(0), Fans.refused(1, .foreignManualControl)]))
        AllFansControlActions(composition: scene.root).choose(.fifty, on: window.polling)

        let sent = await Support.eventually(turns: 2_000) {
            await !scene.lease.entries.acquires.isEmpty
        }
        #expect(!sent, "nothing was asked for")
        #expect(scene.root.leaseState.current == .idle)
        await window.close()
        await scene.finish()
    }

    // MARK: - The Monitor build

    /// No helper in this build: the control is hidden with the build's reason, and nothing any
    /// entry point is given reaches anything.
    ///
    /// **Mutation (M8b, "Monitor gets a driver"):** in `AppComposition.init`, give `.absent` the
    /// `.embedded` arm's body. Run: red at the affordance, at `!sent`, at `connected == 0` and at
    /// the lease state.
    @Test("The Monitor build hides the control, and nothing is sent")
    func theMonitorBuildSendsNothing() async throws {
        var connected = 0
        let ledger = LeaseLedger()
        let control = FakeLeaseHelper(clock: HandWoundClock(), ledger: ledger)
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent,
            connect: {
                connected += 1
                return HelperConnections(read: FakeSnapshotHelper(), control: control)
            },
            makeDriver: { LeaseDriver(control: $0, holderDescription: LeaseScene.holder) },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime(),
            mainRunLoop: TestMainRunLoop(.atOnce))
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: root.snapshots)
        await polling.tick()

        let presentation = AllFansControlPresentation(
            polling: polling, driver: root.leaseState.current)
        #expect(presentation.affordance == .hidden(.noHelperInThisBuild))
        #expect(!presentation.drawsControl)
        #expect(!presentation.percentsAreEnabled)
        #expect(!presentation.automaticIsEnabled)

        // Releases first and the take last: a release after it would mark a take still in
        // flight to be given back on arrival, and the driver would then send nothing at all, so
        // `!sent` could not see a driver that should not exist.
        let actions = AllFansControlActions(composition: root)
        actions.chooseAutomatic()
        root.selectAutomatic()
        for percent in FanSpeedPercent.allCases { actions.choose(percent, on: polling) }
        let target = try Fans.target(.hundred, fans: [0])
        root.adjust(target)
        root.take(target)

        let sent = await Support.eventually(turns: 2_000) { await !ledger.entries.isEmpty }
        #expect(!sent, "nothing reached a control connection")
        #expect(connected == 0)
        #expect(root.leaseState.current == .idle)
    }

    // MARK: - Releasing, with a take queued behind it

    /// Reachable from this control: while a release is unanswered, a snapshot that no longer lists
    /// the lease enables the control, a click queues a `take` behind the release, and Auto, enabled
    /// with the control, cancels it. That is the user's latest choice, so the pin is that nothing
    /// is acquired once the release answers.
    @Test("Auto while releasing cancels a take queued behind the release")
    func autoWhileReleasingCancelsAQueuedTake() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let actions = AllFansControlActions(composition: scene.root)
        let held = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0, 1])))
        await scene.lease.helper.script(.release, .parked)
        actions.chooseAutomatic()
        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] })
        try await Self.published(on: scene) { $0 == .releasing }

        // The window still shows a snapshot with no lease listed: the control is enabled.
        let control = window.control(scene.root.leaseState.current)
        #expect(control.affordance == .enabled)
        #expect(control.automaticIsEnabled)
        actions.choose(.seventyFive, on: window.polling)
        await scene.lease.settle()
        actions.chooseAutomatic()
        await scene.lease.settle()

        await scene.lease.helper.answerParked(.release)
        await scene.lease.waitForState { $0.isReleased }
        let reacquired = await Support.eventually(turns: 2_000) {
            await scene.lease.entries.acquires.count > 1
        }
        #expect(!reacquired, "the queued take was cancelled by Auto")
        #expect(await scene.lease.driver.state == .released)
        await window.close()
        await scene.finish()
    }

    /// The control: without the second Auto, the queued take is acquired once the release answers,
    /// so the test above can see a cancellation.
    @Test("Without Auto, a take queued behind a release is acquired once it answers")
    func aQueuedTakeIsAcquired() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)]))
        let actions = AllFansControlActions(composition: scene.root)
        let held = try #require(await scene.lease.take(try Fans.target(.fifty, fans: [0, 1])))
        await scene.lease.helper.script(.release, .parked)
        actions.chooseAutomatic()
        try #require(
            await Support.eventually { await scene.lease.entries.releases == [held.lease.id] })
        try await Self.published(on: scene) { $0 == .releasing }

        actions.choose(.seventyFive, on: window.polling)
        await scene.lease.settle()
        await scene.lease.helper.answerParked(.release)

        try #require(
            await Support.eventually { await scene.lease.entries.acquires.count == 2 })
        await window.close()
        await scene.finish()
    }

    // MARK: - The view is built with the root's

    /// `FanListView` reads the control's state and its actions from the root it is given, so the
    /// window's `MainView`, which passes its own root, draws that root's lease and acts through it.
    /// What no test here can see is `body` drawing from these, or a button's closure calling them:
    /// that needs a hosted window (#493's review, probe B).
    ///
    /// **Mutation (V, "a view of its own"):** in `FanListView.init`, observe a new
    /// `LeaseStateModel()`. Run: red at the identity.
    @Test("The fan list observes the root's lease state and acts through the root")
    func theViewIsBuiltWithTheRoots() async throws {
        let scene = await CompositionScene()
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: scene.root.snapshots)
        let view = FanListView(viewModel: polling, composition: scene.root)

        let observed =
            Reflection.value(of: view, at: "_leaseState") as? ObservedObject<LeaseStateModel>
        #expect(observed?.wrappedValue === scene.root.leaseState)
        let actions = Reflection.value(of: view, at: "actions") as? AllFansControlActions
        #expect(actions?.composition === scene.root)
        await scene.finish()
    }

    // MARK: - Waits

    /// Waits for the ledger to show `percent` confirmed over `fans`, and returns the lease held.
    static func confirmed(
        _ percent: FanSpeedPercent, fans: [Int], on scene: CompositionScene
    ) async throws -> HeldLease {
        let target = try Fans.target(percent, fans: fans)
        try #require(
            await Support.eventually {
                await scene.lease.entries.states.contains { state in
                    if case .held(let held) = state, held.phase == .confirmed(target) {
                        return true
                    }
                    return false
                }
            }, "\(percent) confirmed")
        guard case .held(let held) = await scene.lease.driver.state else {
            Issue.record("not held")
            throw LeaseScene.TargetError.envelopeRefused
        }
        return held
    }

    /// Waits for the driver to reach a state satisfying `matches`, on the ledger, then, boundedly,
    /// for the root's published state to reach it too. The second wait needs only main-actor turns:
    /// the driver hands every subscriber its state in the same step, so once the ledger has it, the
    /// root's stream has it as well.
    static func published(
        on scene: CompositionScene, _ matches: @escaping @Sendable (LeaseDriverState) -> Bool
    ) async throws {
        await scene.lease.waitForState(matches)
        let root = scene.root
        try #require(
            await Support.settle { matches(root.leaseState.current) },
            "the root published it: \(root.leaseState.current)")
    }
}
