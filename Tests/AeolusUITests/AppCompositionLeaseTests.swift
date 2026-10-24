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
    /// here, and at `quitRepliesOnceAfterTheRelease`'s first expectation.
    @Test("A pending release is answered terminateLater")
    func laterIsTerminateLater() {
        #expect(LeaseLifecycle.TerminationAnswer.later.terminateReply == .terminateLater)
    }

    /// Quit answers `.terminateLater`, releases, tears the connection down, and only then replies,
    /// once. A second quit while the first is waiting changes nothing.
    ///
    /// **Mutation (Q2, "a second reply"):** in `AppComposition.applicationShouldTerminate`, delete
    /// `guard !quitting else { … }`. Red at `replies.count == 1` after the second quit.
    @Test("Quit replies once, after the release and the teardown")
    func quitRepliesOnceAfterTheRelease() async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let counter = ReplyCounter()

        #expect(scene.root.applicationShouldTerminate(reply: counter.reply) == .terminateLater)
        #expect(scene.root.applicationShouldTerminate(reply: counter.reply) == .terminateLater)
        try #require(await becomes { counter.replies.count == 1 }, "the quit was answered")
        let extra = await becomes(turns: 2_000) { counter.replies.count > 1 }

        #expect(!extra)
        #expect(counter.replies == [true])
        let entries = await scene.lease.entries
        let released = try #require(entries.index(of: .release(held.lease.id)))
        let disconnected = try #require(entries.index(of: .disconnect))
        #expect(released < disconnected, "released before the connection was torn down")
        #expect(entries.filter { $0.event == .disconnect }.count == 1, "one teardown")
        await scene.finish()
    }

    /// With no driver, the quit is still answered `.terminateLater` and replied to exactly once.
    ///
    /// **Mutation (Q3):** in `AppComposition.applicationShouldTerminate`, delete
    /// `Task { reply(true) }` from the no-driver arm. Red at the first requirement: a quit nothing
    /// ever answers.
    @Test("With no driver, quit is answered once")
    func quitWithNoDriverRepliesOnce() async throws {
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent, connect: { AppCompositionTests.doubles() },
            makeDriver: { LeaseDriver(control: $0, holderDescription: "unused") },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime())
        let counter = ReplyCounter()

        #expect(root.applicationShouldTerminate(reply: counter.reply) == .terminateLater)
        try #require(await becomes { counter.replies.count == 1 }, "the quit was answered")
        #expect(root.applicationShouldTerminate(reply: counter.reply) == .terminateLater)
        let extra = await becomes(turns: 2_000) { counter.replies.count > 1 }

        #expect(!extra)
        #expect(counter.replies == [true])
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

        try #require(await becomes { await scene.lease.entries.releases == [held.lease.id] })
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

        try #require(await becomes { await scene.lease.entries.releases == [held.lease.id] })
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

        try #require(await becomes { await scene.lease.driver.state.isLost }, "the wake renewed")
        let reacquired = await becomes(turns: 2_000) { await scene.lease.entries.acquires.count > 1 }
        #expect(!reacquired, "nothing asked for the fans again")
        let loss = try #require(await scene.lease.driver.state.loss)
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
        await scene.lease.ledger.waitFor { $0.renewals.count == 1 }

        // The wake replaces the beat, whose renewal is deaf to its cancellation, so the wake waits.
        scene.post(NSWorkspace.didWakeNotification)
        await scene.lease.ledger.waitFor { $0.renewals.count == 2 }

        scene.post(NSWorkspace.willPowerOffNotification)
        try #require(await becomes { await scene.lease.entries.releases == [held.lease.id] })
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
        try #require(await becomes { await scene.lease.entries.releases == [held.lease.id] })
        await scene.finish()
    }

    /// The panel and the Settings window open and close with no main window open, and release
    /// nothing.
    ///
    /// **Mutation (V2, "the panel's close releases"):** in `AppWindow.isControlWindow`, answer
    /// `true` for `.menuBarPanel`. Red at `!released` for the panel.
    @Test("Closing the menu bar panel or Settings releases nothing", arguments: [AppWindow.menuBarPanel, .settings])
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
    @Test("An open panel does not keep the lease past the last main window", arguments: [AppWindow.menuBarPanel, .settings])
    func otherWindowsDoNotHoldTheLease(_ window: AppWindow) async throws {
        let scene = await CompositionScene()
        let held = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let main = UUID()
        scene.root.windowAppeared(.main, id: main)
        scene.root.windowAppeared(window, id: UUID())

        scene.root.windowDisappeared(.main, id: main)

        try #require(await becomes { await scene.lease.entries.releases == [held.lease.id] })
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

        try #require(await becomes { await scene.lease.driver.state.isLost })
        scene.root.snapshots.stop()
        await scene.finish()
    }

    // MARK: - Fixtures

    /// Whether a release reaches the fake, or the driver leaves `held`, within a bounded number of
    /// turns: for a close that must not release, where a correct root gives no event to wait for.
    static func releasesSoon(_ scene: CompositionScene) async -> Bool {
        await becomes(turns: 2_000) {
            if !(await scene.lease.entries.releases.isEmpty) { return true }
            return !(await scene.lease.driver.state.isHeld)
        }
    }
}
