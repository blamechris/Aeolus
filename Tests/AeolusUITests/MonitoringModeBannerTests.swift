import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import SwiftUI
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The monitoring-mode banner in the shipping window (#157): the root records what the user asked
/// for, and `FanListView.body` draws `MonitoringModeDisplay`'s answer for what is on screen,
/// walked as SwiftUI would evaluate it (#497's `Mirror` walk, `AllFansControlViewTests`).
///
/// What no test here evaluates is `MonitoringModeBanner.body` itself, which draws the banner's
/// fields and decides nothing. Reaching it needs a hosted window.
@Suite("Monitoring mode — through the root, and FanListView's body", .timeLimit(.minutes(1)))
@MainActor
struct MonitoringModeBannerTests {

    typealias Support = SnapshotTestSupport
    typealias Fans = AllFansFixtures
    typealias Display = MonitoringModeDisplay
    typealias Reads = AutomaticAfterAReadTests

    // MARK: - FanListView's body, as SwiftUI evaluates it

    /// The `MonitoringModeBanner` `body` builds, found by walking the value it returns, or `nil`
    /// when it builds none.
    static func banner(in view: FanListView) -> MonitoringModeBanner? {
        find(view.body, depth: 0)
    }

    private static func find(_ value: Any, depth: Int) -> MonitoringModeBanner? {
        if let banner = value as? MonitoringModeBanner { return banner }
        guard depth < 24 else { return nil }
        for child in Mirror(reflecting: value).children {
            if let banner = find(child.value, depth: depth + 1) { return banner }
        }
        return nil
    }

    /// Waits for the driver to enter a state satisfying `matches` after `mark`, on the ledger, then
    /// for the root to publish it.
    static func reaches(
        _ scene: CompositionScene, since mark: Int,
        _ matches: @escaping @Sendable (LeaseDriverState) -> Bool
    ) async throws {
        await scene.lease.waitForState(since: mark, matches)
        let root = scene.root
        try #require(
            await Support.settle { matches(root.leaseState.current.state) },
            "the root published it: \(root.leaseState.current)")
    }

    static func confirmed(_ target: LeaseTarget) -> @Sendable (LeaseDriverState) -> Bool {
        { state in
            if case .held(let held) = state, held.phase == .confirmed(target) { return true }
            return false
        }
    }

    /// The root's own source at a 60 s interval, a window's view model over it showing a cleared
    /// snapshot with its read's ticket, and the lease taken through the root. The read the root
    /// asks for at the grant is answered with a snapshot showing the lease holding both fans, and
    /// is not rendered.
    static func heldThroughTheRoot() async throws -> (CompositionScene, PollingViewModel) {
        let (scene, polling) = try await Reads.rootAt60Seconds()
        await scene.reader.reply(with: Reads.cleared)
        try #require(await Support.settle { Reads.ticket(scene.root.snapshots) != nil })
        await Support.tickEnds(polling)
        let target = try LeaseScene.target([0: 3000, 1: 3000])
        let mark = await scene.lease.mark()
        try await scene.click { scene.root.take(target) }
        try await reaches(scene, since: mark, confirmed(target))
        let lease = try #require(await scene.lease.helper.heldLeases.values.first)
        try await Reads.answerTheGrantsRead(
            scene, asRequest: 2,
            with: Support.snapshot(
                fans: [Fans.held(0, at: 3000), Fans.held(1, at: 3000)], activeLease: lease))
        return (scene, polling)
    }

    /// Answers the read the root asks for once the driver has stopped acting, with a cleared
    /// snapshot, and renders it: D1's evidence, from the shipping path.
    static func readAfterTheStop(
        _ scene: CompositionScene, _ polling: PollingViewModel
    ) async throws {
        let source = scene.root.snapshots
        try #require(
            await Support.settle { scene.root.leaseState.current.automaticEvidence.isFloor },
            "the root published the floor")
        // The first request was answered before the grant, the second is the grant's.
        let sent = await Support.requestsReach(3, on: scene.reader)
        try #require(sent, "the root asked for a read after the stop")
        await scene.reader.reply(with: Reads.cleared)
        let evidence = scene.root.leaseState.current.automaticEvidence
        try #require(await Support.settle { evidence.admits(Reads.ticket(source)) })
        await Support.tickEnds(polling)
        try #require(
            AllFansControlPresentation(polling: polling, driver: scene.root.leaseState.current)
                .selection == .automatic,
            "the control reads Auto, so a banner could say 'as you chose'")
    }

    /// The user's own take, then Auto, through the root. The read on screen when the driver stops
    /// is from before the grant, so nothing is said; the read the root asks for after the stop is
    /// D1's evidence, and the body draws the formatter's "as you chose".
    ///
    /// **Mutation (B1, "the view ignores the formatter"):** in `FanListView.body`, make the
    /// banner's `if let` bind `Optional(MonitoringModeDisplay.banner(for: .noHelperInThisBuild))`.
    /// Run: red at both `nil`s and both comparisons here, at the `nil` in
    /// `aLifecycleReleaseIsNotAChoice`, and at the refusal's three expectations.
    /// **Mutation (B2, "the view reads another model"):** in `FanListView.body`, pass
    /// `LeaseStateModel()` for `lease`. Run: red at `drawn`. **Mutation (R1, "Auto unrecorded"):**
    /// in `AppComposition.selectAutomatic()`, delete `leaseState.userAskedForAutomatic()`. Run:
    /// red at `enteredAfterTheUsersAuto` and at `drawn`, and at `aTakeEndsTheAutosClaim`'s first
    /// expectation.
    @Test("The body draws 'as you chose' after the user's Auto, from a read after it")
    func theBodyDrawsTheUsersAuto() async throws {
        let (scene, polling) = try await Self.heldThroughTheRoot()
        let view = FanListView(viewModel: polling, composition: scene.root)
        #expect(Self.banner(in: view) == nil, "a held lease drew a banner")

        let mark = await scene.lease.mark()
        try await scene.click { scene.root.selectAutomatic() }
        try await Self.reaches(scene, since: mark) { $0 == .released }
        #expect(scene.root.leaseState.enteredAfterTheUsersAuto, "the root did not record the Auto")
        await Support.tickEnds(polling)
        #expect(Self.banner(in: view) == nil, "a read from before the grant said 'as you chose'")

        try await Self.readAfterTheStop(scene, polling)
        let drawn = try #require(Self.banner(in: view), "the body drew no banner")
        #expect(drawn.banner == Display.banner(for: .automaticAsChosen))
        #expect(drawn.banner == Display.banner(polling: polling, lease: scene.root.leaseState))

        scene.root.snapshots.stop()
        await scene.finish()
    }

    /// The same lease ended by fast user switching, read after the stop exactly as above: the
    /// control reads Auto, and nothing says the user chose it.
    ///
    /// **Mutation (V6, "released is a choice"):** red here as well as in
    /// `MonitoringModePrecedenceTests`.
    @Test(
        "A release the user did not ask for draws no 'as you chose', though the control reads Auto")
    func aLifecycleReleaseIsNotAChoice() async throws {
        let (scene, polling) = try await Self.heldThroughTheRoot()
        let view = FanListView(viewModel: polling, composition: scene.root)

        let mark = await scene.lease.mark()
        scene.post(NSWorkspace.sessionDidResignActiveNotification)
        try await Self.reaches(scene, since: mark) { $0 == .released }
        try await Self.readAfterTheStop(scene, polling)

        #expect(!scene.root.leaseState.enteredAfterTheUsersAuto)
        #expect(Self.banner(in: view) == nil)

        scene.root.snapshots.stop()
        await scene.finish()
    }

    /// The user's Auto, then a take, then a release the user did not ask for: the take ends the
    /// Auto's claim.
    ///
    /// **Mutation (R2, "a take unrecorded"):** in `AppComposition.take(_:)`, delete
    /// `leaseState.userAskedForControl()`. Run: red at the last expectation.
    @Test("A take through the root ends the Auto's claim, whatever releases next")
    func aTakeEndsTheAutosClaim() async throws {
        let scene = await CompositionScene()
        let target = try LeaseScene.target([0: 3000])
        var mark = await scene.lease.mark()
        try await scene.click { scene.root.take(target) }
        try await Self.reaches(scene, since: mark, Self.confirmed(target))

        mark = await scene.lease.mark()
        try await scene.click { scene.root.selectAutomatic() }
        try await Self.reaches(scene, since: mark) { $0 == .released }
        #expect(scene.root.leaseState.enteredAfterTheUsersAuto)

        mark = await scene.lease.mark()
        try await scene.click { scene.root.take(target) }
        try await Self.reaches(scene, since: mark, Self.confirmed(target))
        mark = await scene.lease.mark()
        scene.post(NSWorkspace.sessionDidResignActiveNotification)
        try await Self.reaches(scene, since: mark) { $0 == .released }

        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "a release after a take read as the user's Auto")
        await scene.finish()
    }

    /// Auto, then a percentage, clicked faster than the driver answers: the take is the user's last
    /// request, so the release fast user switching makes later is not "as you chose". It holds
    /// only because each entry point records its request synchronously, in click order, before it
    /// starts its task (#509's review, S1). A record made inside the task can land after the take
    /// recorded its own.
    ///
    /// **Mutation (O2', "the Auto recorded in its task"):** in `AppComposition.selectAutomatic()`,
    /// move `leaseState.userAskedForAutomatic()` into the `Task`, before the `await`. Run: red at
    /// the last expectation.
    @Test("Auto then a take, clicked back to back, leave the take as the last request")
    func autoThenATakeBackToBack() async throws {
        let scene = await CompositionScene()
        let target = try LeaseScene.target([0: 3000])
        var mark = await scene.lease.mark()
        try await scene.click { scene.root.take(target) }
        try await Self.reaches(scene, since: mark, Self.confirmed(target))

        mark = await scene.lease.mark()
        let before = scene.root.latestDriverCall?.ordinal ?? 0
        scene.root.selectAutomatic()
        scene.root.take(target)
        let call = try #require(scene.root.latestDriverCall, "the clicks started calls")
        try #require(call.ordinal == before + 2, "the two clicks started two calls")
        await scene.lease.run { await call.finished() }
        try await Self.reaches(scene, since: mark, Self.confirmed(target))

        mark = await scene.lease.mark()
        scene.post(NSWorkspace.sessionDidResignActiveNotification)
        try await Self.reaches(scene, since: mark) { $0 == .released }

        #expect(
            !scene.root.leaseState.enteredAfterTheUsersAuto,
            "a release after Auto-then-take read as the user's Auto")
        await scene.finish()
    }

    /// Every fan refused for want of a temperature, on a window whose driver is idle: the body
    /// draws the formatter's refusal, in the reason's own words.
    ///
    /// **Mutation (B3, "no banner drawn"):** in `FanListView.body`, delete the banner's `if let`.
    /// Run: red at `drawn` here, in `theBodyDrawsTheUsersAuto` and in the build with no helper.
    @Test("The body draws the helper's refusal, as the formatter words it")
    func theBodyDrawsTheRefusal() async throws {
        let scene = await CompositionScene()
        let window = try await ControlWindow.showing(
            Support.snapshot(fans: [
                Fans.refused(0, .noThermalTelemetry), Fans.refused(1, .noThermalTelemetry),
            ]))
        let view = FanListView(viewModel: window.polling, composition: scene.root)

        let drawn = try #require(Self.banner(in: view), "the body drew no banner")
        #expect(
            drawn.banner == Display.banner(polling: window.polling, lease: scene.root.leaseState))
        #expect(
            drawn.banner.headline
                == "Monitoring only: the helper refuses manual control of every fan.")
        #expect(drawn.banner.reasons.map(\.wireValue) == ["noThermalTelemetry"])
        await window.close()
        await scene.finish()
    }

    /// A build with no helper: the body says so, in the formatter's words.
    @Test("The body of a build with no helper draws 'monitoring only'")
    func theBodyOfABuildWithNoHelper() async throws {
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent,
            connect: { AppCompositionTests.doubles() },
            makeDriver: { LeaseDriver(control: $0, holderDescription: "unused") },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime(),
            mainRunLoop: TestMainRunLoop(.atOnce))
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(),
            snapshots: root.snapshots)
        await Support.tickEnds(polling)
        let view = FanListView(viewModel: polling, composition: root)

        let drawn = try #require(Self.banner(in: view), "the body drew no banner")
        #expect(drawn.banner == Display.banner(for: .noHelperInThisBuild))
    }
}
