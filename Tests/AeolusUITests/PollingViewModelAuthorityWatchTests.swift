import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// `PollingViewModel`'s authority watch, and its place among the shared source's consumers: a
/// claim leaves the screen within one watch step of losing its licence, whatever the refresh
/// interval, without a read; and a view model takes one place at the source and gives back one
/// (#478's review, C2 and items 8 and 13).
@Suite(
    "PollingViewModel — the authority watch, and the source's consumers",
    .timeLimit(.minutes(1)))
@MainActor
struct PollingViewModelAuthorityWatchTests {

    typealias Support = SnapshotTestSupport

    static let lease = Lease(holderDescription: "fanctl 0.3.0", expiresAt: Date())

    // MARK: - Withdrawn within a second, whatever the refresh interval (C2)

    /// A view model on a 60 s interval with its read clock held: after the first tick nothing
    /// else is read. The helper stops answering; one step of the authority watch must take the
    /// claims down, without a read and without waiting for the next tick.
    ///
    /// **Mutation (W1):** delete `startAuthorityWatch()` from `start()`. Run: red at the
    /// control, fan and emergency expectations after the health change.
    @Test("A health change takes the claims down within one authority-watch step, with no read")
    func aHealthChangeIsWithdrawnByTheWatch() async throws {
        let helper = FakeSnapshotHelper()
        let snapshot = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000)], activeLease: Self.lease,
            isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot)
        let provider = Support.directProvider()
        let readClock = GatedPollingClock()
        let watchClock = GatedPollingClock()
        let viewModel = PollingViewModel(
            provider: provider, clock: readClock, refreshInterval: 60, snapshots: source,
            authorityWatchClock: watchClock)

        viewModel.start()
        try await readClock.waitForSleeps(1)  // the first tick is done; the next is 60 s away
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: Self.lease))
        #expect(viewModel.thermalEmergency == .active)
        _ = await Support.eventually { await watchClock.parkedCount >= 1 }

        try await Support.report(.unresponsive, to: source, from: helper)
        await watchClock.release()
        _ = await Support.eventually { await watchClock.sleptSeconds.count >= 2 }

        let why = ControlNotTracked.helperConnection(.unresponsive)
        #expect(viewModel.controlSource == .notTracked(why))
        #expect(viewModel.fans.map(\.control) == [.notTracked(why)])
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(await readClock.sleptSeconds == [60], "a read tick ran")
        #expect(await Support.readCount(provider) == 0, "the withdrawal read the SMC")
        #expect(
            await watchClock.sleptSeconds.allSatisfy {
                $0 == PollingViewModel.authorityWatchInterval
            })
        #expect(PollingViewModel.authorityWatchInterval <= 1)

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    /// The same, with no health change at all: the bound runs out between two read ticks.
    ///
    /// **Mutation (W1):** as above. Run: red at the control and emergency expectations.
    @Test("An expired snapshot's claims come down within one authority-watch step, with no read")
    func anExpiryIsWithdrawnByTheWatch() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let snapshot = Support.snapshot(isThermalEmergencyActive: true)
        let source = try await Support.freshSource(helper, answering: snapshot, clock: clock)
        let provider = Support.directProvider()
        let readClock = GatedPollingClock()
        let watchClock = GatedPollingClock()
        let viewModel = PollingViewModel(
            provider: provider, clock: readClock, refreshInterval: 60, snapshots: source,
            authorityWatchClock: watchClock)

        viewModel.start()
        try await readClock.waitForSleeps(1)
        #expect(viewModel.thermalEmergency == .active)
        _ = await Support.eventually { await watchClock.parkedCount >= 1 }

        clock.advance(by: source.freshnessBound)
        await watchClock.release()
        _ = await Support.eventually { await watchClock.sleptSeconds.count >= 2 }

        #expect(viewModel.controlSource == .notTracked(.snapshotStale))
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(await readClock.sleptSeconds == [60])
        #expect(await Support.readCount(provider) == 0)

        viewModel.stop()
        await Support.tearDown(source, helper)
    }

    // MARK: - Consumers

    /// **Mutation (O26):** `start()` stops calling `snapshots.start()`. **Mutation (O12):**
    /// `stop()` stops calling `snapshots.stop()`. Run, each: red at the matching
    /// `consumerCount` requirement — an assertion, not a wait that never ends.
    @Test("start() and stop() tell the shared source a consumer came and went")
    func theViewModelIsASourceConsumer() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(cancelAfterSleeps: 1),
            snapshots: source, authorityWatchClock: GatedPollingClock())

        viewModel.start()
        try #require(source.consumerCount == 1, "start() did not reach the source")
        try await helper.waitForRequests(1)
        let ended = await Support.refreshLoopEnds(viewModel)
        viewModel.stop()
        #expect(ended, "the refresh loop did not end")
        try #require(source.consumerCount == 0, "stop() did not reach the source")

        await helper.reply(with: Support.snapshot())
        try #require(await Support.settle { !source.isLoopRunning })
        #expect(await helper.requests == 1)
    }

    /// The window and the menu bar share the source. A window whose `onDisappear` fires twice
    /// must not take the menu bar's place away.
    ///
    /// **Mutation (F2):** in `PollingViewModel.stop()`, move `snapshots.stop()` above `guard let
    /// loopTask`. Run: red at `consumerCount == 1`.
    @Test("A view model stopped twice gives up one place at the source, not two")
    func aDoubleStopKeepsTheOtherConsumer() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        let window = PollingViewModel(
            provider: Support.directProvider(), clock: GatedPollingClock(), snapshots: source,
            authorityWatchClock: GatedPollingClock())
        let menuBar = PollingViewModel(
            provider: Support.directProvider(), clock: GatedPollingClock(), snapshots: source,
            authorityWatchClock: GatedPollingClock())

        window.start()
        menuBar.start()
        #expect(source.consumerCount == 2)

        window.stop()
        window.stop()
        #expect(source.consumerCount == 1)

        menuBar.stop()
        #expect(source.consumerCount == 0)

        await Support.tearDown(source, helper)
    }
}
