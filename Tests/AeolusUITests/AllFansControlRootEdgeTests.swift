import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The Monitor build, and a release with a take queued behind it: the edges of
/// `AllFansControlRootTests`. An extension, so these run in that suite, under its time limit.
extension AllFansControlRootTests {

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
        try #require(
            await Support.eventually { await scene.lease.driver.state.isReleased },
            "the release was answered")
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
}
