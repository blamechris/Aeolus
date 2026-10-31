import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// Every event `AppComposition` routes to the lease: quit, logout, wake, fast user switching, the
/// last control window, and every read's snapshot (#155).
///
/// Each test takes a lease on the scene's driver itself, because nothing in the app does yet, and
/// then acts only through the root: its quit, its window reports, and posts to its workspace
/// centre. No test awaits a driver call or a task's value; each waits on the fake's ledger, which
/// a time limit can cancel, or for a bounded number of turns.
@Suite("AppComposition — every event that reaches the lease", .timeLimit(.minutes(1)))
@MainActor
struct AppCompositionLeaseTests {

    // MARK: - Quit

    /// The mapping is pure: a pending release is `.terminateLater`.
    ///
    /// **Mutation (Q1, ".terminateNow while a release is pending"):** in
    /// `LeaseLifecycle.TerminationAnswer.terminateReply`, return `.terminateNow` for `.later`. Red
    /// here, and at every `== .terminateLater` in the two quit tests below.
    @Test("A pending release is answered terminateLater")
    func laterIsTerminateLater() {
        #expect(LeaseLifecycle.TerminationAnswer.later.terminateReply == .terminateLater)
    }

    /// Quit answers `.terminateLater`, releases, tears the connection down, and only then hands the
    /// reply to the main run loop. Nothing replies while the release is still waiting for the
    /// helper, and the reply is delivered only when the run loop runs it.
    ///
    /// What this test pins is the first half of that order, from the run loop's own count of
    /// hand-overs, which the test does not control: `performed` is 0 while the release is parked,
    /// so nothing is handed over before the helper answers (the bound cannot pass: this clock is
    /// the test's). The second half, the teardown before the hand-over, is only sampled here: the
    /// ledger is read after a poll has seen `performed` reach 1, and the quit's task can finish
    /// its teardown in between, so a hand-over between the release and the teardown can pass.
    /// `LeaseLifecycleTests.quitIsBounded` is what catches that one.
    ///
    /// **Mutation (X19, "an early reply"):** in `AppComposition.applicationShouldTerminate`, reply
    /// through `Task { reply(true) }` and give the lifecycle a reply that does nothing. Red at
    /// `!early`.
    /// **Mutation (M3, "an early hand-over"):** in `LeaseLifecycle.applicationShouldTerminate`,
    /// call `mainRunLoop.perform { reply(true) }` above `await driver.shutDown()`. Red at
    /// `performed == 0`: the reply was handed to the run loop while the release was still parked.
    /// **Mutation (R1, "the reply through the main actor"):** in
    /// `LeaseLifecycle.applicationShouldTerminate`, deliver the reply with
    /// `Task { @MainActor in reply(true) }` instead of `mainRunLoop.perform`. Red at the
    /// requirement that the reply was handed to the run loop.
    @Test("Quit replies once, from the run loop, and only after the release is answered")
    func quitRepliesOnlyAfterTheRelease() async throws {
        let scene = await CompositionScene(runLoop: .parked)
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        await scene.lease.helper.script(.release, .parked)

        let answer = scene.root.applicationShouldTerminate(reply: scene.lease.recordReply)
        #expect(answer == .terminateLater)
        await scene.lease.ledger.waitFor { $0.releases == [held.lease.id] }
        let early = await SnapshotTestSupport.eventually(turns: 2_000) {
            !(await scene.lease.entries.terminationReplies.isEmpty)
        }
        #expect(!early, "a reply went out while the release was still waiting")
        // `early` cannot see a hand-over: the run loop is parked, so nothing is delivered whatever
        // was handed over. The count can.
        #expect(
            scene.runLoop.performed == 0,
            "the reply was handed to the run loop while the release was still waiting")

        await scene.lease.helper.answerParked(.release)
        try #require(
            await SnapshotTestSupport.eventually { scene.runLoop.performed == 1 },
            "the reply was handed to the main run loop")
        // Before the test delivers anything, but after the poll above: a sample, not a pin (see
        // the doc comment). Delivery is the test's choice (`runParked()`), so a read after it
        // would measure the test.
        #expect(
            await scene.lease.entries.index(of: .disconnect) != nil,
            "the connection was not torn down by the time the hand-over was seen")
        scene.runLoop.runParked()
        await scene.lease.ledger.waitFor { !$0.terminationReplies.isEmpty }

        let entries = await scene.lease.entries
        #expect(entries.terminationReplies == [true])
        let released = try #require(entries.index(of: .release(held.lease.id)))
        let disconnected = try #require(entries.index(of: .disconnect))
        #expect(released < disconnected, "released before the connection was torn down")
        #expect(entries.filter { $0.event == .disconnect }.count == 1, "one teardown")
        await scene.finish()
    }

    /// With no driver there is nothing to release: the quit is `.terminateNow`, and no reply is
    /// sent, because AppKit expects none after it.
    ///
    /// **Mutation (R2, "terminateLater with no driver"):** in
    /// `AppComposition.applicationShouldTerminate`, answer the no-driver arm with
    /// `Task { reply(true) }` and `.terminateLater`, as before #493's review. Red at
    /// `== .terminateNow` and at `!replied`.
    @Test("With no driver, quit is terminateNow and nothing replies")
    func quitWithNoDriverIsImmediate() async throws {
        let scene = await LeaseScene()
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent, connect: { AppCompositionTests.doubles() },
            makeDriver: { LeaseDriver(control: $0, holderDescription: "unused") },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime(),
            mainRunLoop: TestMainRunLoop(.atOnce))

        #expect(root.applicationShouldTerminate(reply: scene.recordReply) == .terminateNow)
        let replied = await SnapshotTestSupport.eventually(turns: 2_000) {
            !(await scene.entries.terminationReplies.isEmpty)
        }
        #expect(!replied, "AppKit expects no reply after terminateNow")
        await scene.finish()
    }

    // MARK: - Logout, wake, fast user switching

    /// **Mutation (W1):** in `AppComposition.observeWorkspace`, observe
    /// `NotificationCenter.default` instead of `center`. Red at the requirement: the post went to
    /// the centre `NSWorkspace` posts on, and nothing was listening there.
    @Test("Logout releases")
    func powerOffReleases() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))

        scene.post(NSWorkspace.willPowerOffNotification)

        try #require(
            await SnapshotTestSupport.eventually {
                await scene.lease.entries.releases == [held.lease.id]
            })
        #expect(await scene.lease.helper.heldLeases.isEmpty)
        await scene.finish()
    }

    /// **Mutation (W2, "session resign does not release"):** in `LeaseLifecycle`, make
    /// `sessionDidResignActive()` do nothing. Red at the requirement.
    @Test("Fast user switching away releases")
    func sessionResignReleases() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))

        scene.post(NSWorkspace.sessionDidResignActiveNotification)

        try #require(
            await SnapshotTestSupport.eventually {
                await scene.lease.entries.releases == [held.lease.id]
            })
        #expect(await scene.lease.helper.heldLeases.isEmpty)
        await scene.finish()
    }

    /// A wake renews at once, so a lease the sleep ended is reported lost at once, and nothing asks
    /// for the fans again.
    ///
    /// **Mutation (W3, "wake re-acquires"):** in `LeaseLifecycle.systemDidWake()`, after the
    /// driver's wake, take the last confirmed target again once the state is lost. Red at
    /// `!reacquired`.
    @Test("A wake renews at once and never acquires again")
    func wakeNeverReacquires() async throws {
        let scene = await CompositionScene()
        _ = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        await scene.lease.helper.script(.renew, .refuse(.leaseUnknown))

        scene.post(NSWorkspace.didWakeNotification)

        // The ledger keeps every state, so a driver that moved on from `lost` still shows it.
        try #require(
            await SnapshotTestSupport.eventually { await scene.lease.entries.lost != nil },
            "the wake renewed at once")
        let reacquired = await SnapshotTestSupport.eventually(turns: 2_000) {
            await scene.lease.entries.acquires.count > 1
        }
        #expect(!reacquired, "nothing asked for the fans again")
        let loss = try #require(await scene.lease.entries.lost)
        #expect(loss.afterWake)
        #expect(loss.cause == .renewal(.refused(.leaseUnknown)))
        await scene.finish()
    }

    /// A wake whose replaced renewal is still waiting does not hold up a logout behind it: each
    /// event is on a task of its own, and none is awaited on the path of another.
    ///
    /// **Mutation (W4, "wake awaited on the main actor"):** in `AppComposition.observeWorkspace`,
    /// send power-off and wake through one main-actor chain, each event awaiting the task of the
    /// one before. Red at the requirement: the logout waits for a wake that cannot return.
    @Test("A wake that has not returned does not hold up a logout")
    func aLongWakeHoldsUpNothing() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        await scene.lease.clock.untilParked { !$0.isEmpty }
        await scene.lease.helper.script(.renew, .parkedThroughCancellation, .parked)
        scene.lease.clock.advance(to: scene.lease.at(.seconds(10)))
        try #require(
            await SnapshotTestSupport.eventually { await scene.lease.entries.renewals.count == 1 })

        // The wake replaces the beat, whose renewal is deaf to its cancellation, so the wake waits.
        scene.post(NSWorkspace.didWakeNotification)
        try #require(
            await SnapshotTestSupport.eventually { await scene.lease.entries.renewals.count == 2 },
            "the wake renewed")

        scene.post(NSWorkspace.willPowerOffNotification)
        try #require(
            await SnapshotTestSupport.eventually {
                await scene.lease.entries.releases == [held.lease.id]
            })
        await scene.finish()
    }

    // MARK: - The last control window

    /// Two main windows: the first to close releases nothing; the second does.
    ///
    /// **Mutation (V1, "one of two windows closing releases"):** in
    /// `AppComposition.windowDisappeared`, delete `controlWindows.isEmpty` from the guard. Red at
    /// `!releasedEarly`.
    @Test("Only the last main window to close releases")
    func onlyTheLastMainWindowReleases() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let first = UUID()
        let second = UUID()
        scene.root.windowAppeared(.main, id: first)
        scene.root.windowAppeared(.main, id: second)

        scene.root.windowDisappeared(.main, id: first)
        scene.root.windowDisappeared(.main, id: UUID())  // never appeared
        let releasedEarly = await Self.releasesSoon(scene)
        #expect(!releasedEarly, "a main window is still open")

        scene.root.windowDisappeared(.main, id: second)
        try #require(
            await SnapshotTestSupport.eventually {
                await scene.lease.entries.releases == [held.lease.id]
            })
        await scene.finish()
    }

    /// The panel and the Settings window open and close with no main window open, and release
    /// nothing.
    ///
    /// **Mutation (V2, "the panel's close releases"):** in `AppWindow.isControlWindow`, answer
    /// `true` for `.menuBarPanel`. Red at `!released` for the panel.
    @Test(
        "Closing the menu bar panel or Settings releases nothing",
        arguments: [AppWindow.menuBarPanel, .settings])
    func otherWindowsNeverRelease(_ window: AppWindow) async throws {
        let scene = await CompositionScene()
        _ = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let id = UUID()

        scene.root.windowAppeared(window, id: id)
        scene.root.windowDisappeared(window, id: id)
        let released = await Self.releasesSoon(scene)

        #expect(!released)
        #expect(await scene.lease.driver.state.isHeld)
        await scene.finish()
    }

    /// An open panel or Settings window does not keep the lease once the last main window closes.
    /// The same mutation V2 is red here, the other way: the panel holds the release back.
    @Test(
        "An open panel does not keep the lease past the last main window",
        arguments: [AppWindow.menuBarPanel, .settings])
    func otherWindowsDoNotHoldTheLease(_ window: AppWindow) async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let main = UUID()
        scene.root.windowAppeared(.main, id: main)
        scene.root.windowAppeared(window, id: UUID())

        scene.root.windowDisappeared(.main, id: main)

        try #require(
            await SnapshotTestSupport.eventually {
                await scene.lease.entries.releases == [held.lease.id]
            })
        await scene.finish()
    }

    // MARK: - The read connection's snapshots

    /// The root's source reports every reply to the root's driver: a held lease the next snapshot
    /// does not list is lost.
    ///
    /// **Mutation (S1):** in `AppComposition.init`, pass `observer: nil` to the source. Red at the
    /// requirement.
    @Test("The root's snapshots reach the root's driver")
    func snapshotsReachTheDriver() async throws {
        let scene = await CompositionScene()
        _ = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        scene.reader.report(.handshaken)
        scene.root.snapshots.start()
        try await scene.reader.waitForRequests(1)

        await scene.reader.reply(with: SnapshotTestSupport.snapshot(activeLease: nil))

        try #require(await SnapshotTestSupport.eventually { await scene.lease.driver.state.isLost })
        scene.root.snapshots.stop()
        await scene.finish()
    }

    // MARK: - Fixtures

    /// Whether a release reaches the fake, or the driver leaves `held`, within a bounded number of
    /// turns: for a close that must not release, where a correct root gives no event to wait for.
    static func releasesSoon(_ scene: CompositionScene) async -> Bool {
        await SnapshotTestSupport.eventually(turns: 2_000) {
            if !(await scene.lease.entries.releases.isEmpty) { return true }
            return !(await scene.lease.driver.state.isHeld)
        }
    }
}
