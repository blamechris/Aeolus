import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// The authority watch judged against the snapshot **on screen** (#478's second delta, B1): a
/// newer licensed snapshot is rendered at once, and an older one's claims never outlive it. And
/// the edges of the watch: what it leaves alone, when it stops, and when it never starts.
///
/// Every view model here runs on a 60 s interval with its read clock held, so nothing but the
/// watch can change what is on screen after the first tick. The watch's own clock is held too
/// and released one step at a time.
@Suite("PollingViewModel — the watch follows the snapshot on screen", .timeLimit(.minutes(1)))
@MainActor
struct PollingViewModelWatchRenderTests {

    typealias Support = SnapshotTestSupport

    static let lease = Lease(holderDescription: "fanctl 0.3.0", expiresAt: Date())

    /// A view model on a 60 s interval, and the two clocks it waits on, both held.
    struct Fixture {
        let viewModel: PollingViewModel
        let read: GatedPollingClock
        let watch: GatedPollingClock
    }

    static func fixture(
        on source: HelperSnapshotSource,
        provider: some SensorProvider = Support.directProvider()
    ) -> Fixture {
        let read = GatedPollingClock()
        let watch = GatedPollingClock()
        let viewModel = PollingViewModel(
            provider: provider, clock: read, refreshInterval: 60, snapshots: source,
            authorityWatchClock: watch)
        return Fixture(viewModel: viewModel, read: read, watch: watch)
    }

    /// One step of the watch: wait (bounded) for it to be parked, let it go, and wait (bounded)
    /// for its next sleep — which it takes only after the step is done.
    static func step(_ watch: GatedPollingClock) async {
        let before = await watch.sleptSeconds.count
        _ = await Support.eventually { await watch.parkedCount >= 1 }
        await watch.release()
        _ = await Support.eventually { await watch.sleptSeconds.count > before }
    }

    /// P7's shape. X1 is on screen; its bound passes; X2 — the emergency fired, the lease is
    /// gone — is licensed at the source. One watch step must put X2 on screen, with no read.
    ///
    /// **Mutation (B1):** in `reassessAuthority()`, return from the `.fresh` case without
    /// rendering — judge only whether the source licenses anything, as `bae8007` did. Run: red
    /// at the control, emergency and fan expectations.
    @Test("A newer licensed snapshot replaces an expired one within one watch step")
    func aNewerSnapshotReplacesAnExpiredOne() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let first = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000)], activeLease: Self.lease,
            isThermalEmergencyActive: false)
        let source = try await Support.freshSource(helper, answering: first, clock: clock)
        let provider = Support.directProvider()
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: Self.lease))

        clock.advance(by: source.freshnessBound + .seconds(1))
        let second = Support.snapshot(
            fans: [Support.fan(0, mode: .automatic)], activeLease: nil,
            isThermalEmergencyActive: true)
        await helper.reply(with: second)
        try await helper.waitForRequests(3)
        #expect(Support.freshSnapshot(source) == second)

        await Self.step(watch)

        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(viewModel.thermalEmergency == .active)
        #expect(
            viewModel.fans.map(\.control) == [.reported(second.fans[0], thermalEmergency: true)])
        #expect(await read.sleptSeconds == [60], "a read tick ran")
        #expect(await Support.readCount(provider) == 0)

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// At a 60 s interval the first tick finds nothing to show, and waits. The first reply must
    /// be on screen within one watch step, not at the next tick a minute later.
    ///
    /// **Mutation (B1):** as above. Run: red at the phase and control expectations.
    @Test("The first snapshot is on screen within one watch step, not at the next tick")
    func theFirstSnapshotIsShownWithinTheWatch() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        #expect(viewModel.phase == .waitingForHelper)

        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        let first = Support.snapshot()
        await helper.reply(with: first)
        try await helper.waitForRequests(2)

        await Self.step(watch)

        #expect(viewModel.phase == .ready)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(
            viewModel.fans.map(\.control) == [.reported(first.fans[0], thermalEmergency: false)])
        #expect(await read.sleptSeconds == [60])

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// C1's reconnect, through the watch: the helper is replaced and the new one handshakes
    /// before answering. The old snapshot's claims must come down at the next watch step.
    ///
    /// **Mutation (MX2b):** in `reassessAuthority()`, leave `.awaitHelper(.awaitingSnapshot)`
    /// alone. Run: red at both expectations.
    @Test("After a reconnect the old snapshot's claims come down within one watch step")
    func aReconnectIsWithdrawnByTheWatch() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.freshSource(
            helper, answering: Support.snapshot(isThermalEmergencyActive: true))
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        #expect(viewModel.thermalEmergency == .active)

        try await Support.report(.interrupted, to: source, from: helper)
        try await Support.report(.handshaken, to: source, from: helper)
        await Self.step(watch)

        #expect(viewModel.controlSource == .notTracked(.awaitingSnapshot))
        #expect(viewModel.thermalEmergency == .unknown)

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// Readings the view model took itself carry no claims, and the watch has nothing to take
    /// down: it does not touch them, not even to relabel the reason.
    ///
    /// **Mutation (WD2):** delete `guard case .helperSnapshot = controlSource` from the
    /// withdrawal. Run: red at the `revision` and `controlSource` expectations.
    @Test("The watch leaves the view model's own readings alone")
    func theWatchLeavesDirectReadsAlone() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        #expect(viewModel.controlSource == .notTracked(.helperConnection(.refused)))
        let revision = viewModel.revision

        try await Support.report(.invalidated, to: source, from: helper)
        await Self.step(watch)

        #expect(viewModel.revision == revision)
        #expect(viewModel.controlSource == .notTracked(.helperConnection(.refused)))

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// A tick reading the SMC is suspended in its read when the source starts licensing a
    /// snapshot. A render then would be overwritten by the read — readings with no claims,
    /// under a `controlSource` that still names the snapshot. The watch waits a step instead.
    ///
    /// **Mutation (RG1):** delete `guard directRead == nil` from `reassessAuthority()`. Run:
    /// red at the expectations after the read finishes.
    @Test("The watch never renders into a direct read in progress, and renders after it")
    func theWatchNeverRendersIntoADirectRead() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let provider = GatedSensorProvider(inner: Support.directProvider())
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try #require(await Support.eventually { await provider.readsStarted >= 1 })

        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        let snapshot = Support.snapshot()
        await helper.reply(with: snapshot)
        try await helper.waitForRequests(2)
        try #require(Support.freshSnapshot(source) == snapshot)
        await Self.step(watch)

        await provider.open()
        try await read.waitForSleeps(1)

        let why = ControlNotTracked.helperConnection(.refused)
        #expect(viewModel.controlSource == .notTracked(why))
        #expect(viewModel.fans.allSatisfy { $0.control == .notTracked(why) })

        await Self.step(watch)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: false)])

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// **Mutation (WS1):** `stop()` no longer cancels the watch. Run: red here.
    @Test("stop() ends the authority watch")
    func stopEndsTheWatch() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.freshSource(helper, answering: Support.snapshot())
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        _ = await Support.eventually { await watch.parkedCount >= 1 }

        viewModel.stop()
        let ended = await Support.eventually { await watch.cancelledSleeps == 1 }
        await watch.release()
        #expect(ended, "the watch was still waiting after stop()")

        await Support.tearDown(source, helper)
    }

    /// In a build with no helper the source can never license anything, and the watch would
    /// wake twice a second to do nothing.
    ///
    /// **Mutation (N3):** start the watch whether or not the source has a reader. Run: red here.
    @Test("No authority watch runs in a build with no helper")
    func noWatchWithoutAHelper() async throws {
        let source = HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
        #expect(!source.hasReader)
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        // Bounded, and spent in full when the code is right: a watch started by mistake has
        // taken its first sleep long before this gives up.
        _ = await Support.eventually { await watch.sleptSeconds.count >= 1 }

        #expect(await watch.sleptSeconds.isEmpty)

        viewModel.stop()
    }
}
