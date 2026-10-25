import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import SMCCore
import Testing

@testable import AeolusUI

/// Two refresh loops with a direct read in flight, after `stop()` then `start()` (#485 S1), and
/// the watch leaving the snapshot on screen alone (R4). An extension, so these run in
/// `PollingViewModelWatchRenderTests`, under its time limit and on its fixture: a 60 s interval,
/// with the read clock and the watch's clock both held.
extension PollingViewModelWatchRenderTests {

    /// Whether every control claim on screen comes from one place: each fan reported, beneath a
    /// snapshot's header, or each fan untracked for the reason the header gives.
    private static func claimsAgree(_ viewModel: PollingViewModel) -> Bool {
        switch viewModel.controlSource {
        case .helperSnapshot:
            return viewModel.fans.allSatisfy {
                if case .reported = $0.control { return true }
                return false
            }
        case .notTracked(let why):
            return viewModel.fans.allSatisfy { $0.control == .notTracked(why) }
        }
    }

    /// The issue's probe. A tick is suspended in a direct read when `stop()` then `start()` run,
    /// so the new loop's first tick begins a second read beside it. The stopped loop's read lands
    /// first; then the source licenses a snapshot and the watch takes a step; then the running
    /// loop's read lands. Under one shared flag, the first read's end cleared it while the second
    /// was still in flight, the watch rendered the snapshot, and the second read's fans, which
    /// carry no claims, then landed beneath the snapshot's header: a mixed screen, which the
    /// watch's dedup kept.
    ///
    /// **Mutation (S1):** put back `5b324df`'s shared `isReadingDirectly` flag — set before each
    /// read, cleared after it, every result applied, the watch guarded on it. Run: red at the
    /// `claimsAgree` expectation and at the fans expectation after the next step.
    @Test("A read begun before stop() and start() cannot let the watch render into another read")
    func twoLoopsReadingDirectlyNeverMixTheScreen() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let provider = ParkedReadProvider(inner: Support.directProvider())
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try #require(await Support.eventually { await provider.parkedCount == 1 })
        viewModel.stop()
        viewModel.start()
        try #require(await Support.eventually { await provider.parkedCount == 2 })
        try #require(viewModel.runningRefreshLoops == 2)

        // The stopped loop's read lands, and that loop ends.
        await provider.releaseOldest()
        try #require(await Support.settle { viewModel.runningRefreshLoops == 1 })

        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        let snapshot = Support.snapshot()
        await helper.reply(with: snapshot)
        try await helper.waitForRequests(2)
        try #require(Support.freshSnapshot(source) == snapshot)
        await Self.step(watch)

        // The running loop's read lands, and its tick ends: the loop sleeps.
        await provider.releaseOldest()
        try await read.waitForSleeps(1)
        #expect(Self.claimsAgree(viewModel), "a direct read landed beneath a rendered snapshot")

        await Self.step(watch)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: false)])
        #expect(await provider.readsStarted == 2)

        viewModel.stop()
        await provider.releaseAll()
        await Support.tearDown(source, helper)
    }

    /// A tick is suspended in a direct read when `stop()` runs. By the next `start()` the source
    /// licenses a snapshot, so the new loop's first tick renders it, and only then does the
    /// stopped loop's read land. Its readings carry no claims and must not land beneath the
    /// snapshot. A count of reads in flight, the issue's other fix, would not stop this: the
    /// render came from a tick, which no guard on the watch can hold back, and nothing would tell
    /// the late read that a render had overtaken it.
    ///
    /// **Mutation (S1):** as above. Run: red at the `claimsAgree` expectation and at the fans
    /// expectation after the watch's step. **Mutation (S1c):** count the reads in flight instead,
    /// with every result applied and the watch held while the count is above zero. Run: red at
    /// the same two expectations. **Mutation (S1s):** stop clearing the token in `stop()`. Run:
    /// red at the same two: a render does not touch the token, so only `stop()` discards the
    /// stopped loop's read here.
    @Test("A read begun by a stopped loop never lands on a snapshot rendered after it")
    func aStoppedLoopsReadNeverLandsOnALaterRender() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let provider = ParkedReadProvider(inner: Support.directProvider())
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try #require(await Support.eventually { await provider.parkedCount == 1 })
        viewModel.stop()

        // With no consumer, the source ends its loop once this reply is recorded.
        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        let snapshot = Support.snapshot()
        await helper.reply(with: snapshot)
        try #require(await Support.settle { Support.freshSnapshot(source) == snapshot })

        viewModel.start()
        try await read.waitForSleeps(1)
        try #require(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        try #require(viewModel.runningRefreshLoops == 2)

        // The stopped loop's read lands, and that loop ends.
        await provider.releaseOldest()
        try #require(await Support.settle { viewModel.runningRefreshLoops == 1 })
        #expect(Self.claimsAgree(viewModel), "a stopped loop's read landed on a later render")

        await Self.step(watch)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: false)])
        #expect(await provider.readsStarted == 1)

        viewModel.stop()
        await provider.releaseAll()
        await Support.tearDown(source, helper)
    }

    /// A tick is suspended in a direct read when `stop()` runs, and the new loop's first tick
    /// finds a handshaken helper that owes its first answer, so it reads nothing and waits. The
    /// answer arrives. The stopped loop's read must not hold the watch back, and must not land
    /// either: its readings belong to a read the source no longer allows, beneath a header that
    /// says the app is waiting.
    ///
    /// **Mutation (S1s):** stop clearing the token in `stop()`. Run: red at the `controlSource`
    /// expectation after the step, at `claimsAgree` and at the fans expectation. **Mutation
    /// (S1)** and **(S1c)**, as above. Run, each: red at the same three.
    @Test("A read begun by a stopped loop holds nothing back while the new loop waits")
    func aStoppedLoopsReadHoldsNothingBack() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let provider = ParkedReadProvider(inner: Support.directProvider())
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try #require(await Support.eventually { await provider.parkedCount == 1 })
        viewModel.stop()

        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        viewModel.start()
        try await read.waitForSleeps(1)
        try #require(viewModel.controlSource == .notTracked(.awaitingSnapshot))
        try #require(viewModel.runningRefreshLoops == 2)

        let snapshot = Support.snapshot()
        await helper.reply(with: snapshot)
        try await helper.waitForRequests(2)
        try #require(Support.freshSnapshot(source) == snapshot)
        await Self.step(watch)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))

        // The stopped loop's read lands, and that loop ends.
        await provider.releaseOldest()
        try #require(await Support.settle { viewModel.runningRefreshLoops == 1 })
        #expect(Self.claimsAgree(viewModel), "a stopped loop's read landed")
        #expect(
            viewModel.fans.map(\.control) == [.reported(snapshot.fans[0], thermalEmergency: false)])
        #expect(await provider.readsStarted == 1)

        viewModel.stop()
        await provider.releaseAll()
        await Support.tearDown(source, helper)
    }

    /// The token a landing read finds must be its own, not merely a token. The stopped loop's
    /// read began while the helper refused; the new loop's began after the connection was
    /// invalidated, and is still in flight when the stopped loop's lands, so a token is set — the
    /// new read's. The stopped read's readings, untracked for the old reason, must not go on
    /// screen beneath a header giving the new one, and must not end the new tick's `.polling`.
    ///
    /// **Mutation (T1):** in `tick()`, `guard directRead != nil` instead of `guard directRead ==
    /// read`. Run: red at the `phase`, `claimsAgree` and fans expectations.
    @Test("A stopped loop's read is discarded while the new loop's read is in flight")
    func aStoppedLoopsReadIsNotTakenForTheRunningOnes() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        try await Support.report(.refused, to: source, from: helper)
        let provider = ParkedReadProvider(inner: Support.directProvider())
        let fixture = Self.fixture(on: source, provider: provider)
        let (viewModel, read) = (fixture.viewModel, fixture.read)
        let refused = ControlNotTracked.helperConnection(.refused)
        let invalidated = ControlNotTracked.helperConnection(.invalidated)

        // A first read lands, so there are rows for a header to disagree with.
        viewModel.start()
        try #require(await Support.eventually { await provider.parkedCount == 1 })
        await provider.releaseOldest()
        try await read.waitForSleeps(1)
        try #require(viewModel.fans.map(\.control) == [.notTracked(refused)])

        // The loop's next tick begins a read while the helper still refuses; then stop().
        await read.release()
        try #require(await Support.eventually { await provider.readsStarted == 2 })
        viewModel.stop()

        // The connection is invalidated, and the new loop's first tick reads under that reason.
        try await Support.report(.invalidated, to: source, from: helper)
        viewModel.start()
        try #require(await Support.eventually { await provider.readsStarted == 3 })
        try #require(viewModel.controlSource == .notTracked(invalidated))

        // The stopped loop's read lands, and that loop ends; the new loop's read is in flight.
        await provider.releaseOldest()
        try #require(await Support.settle { viewModel.runningRefreshLoops == 1 })
        #expect(viewModel.phase == .polling, "the stopped loop's read ended the new tick")
        #expect(Self.claimsAgree(viewModel), "the stopped loop's rows landed beneath the header")
        #expect(viewModel.fans.map(\.control) == [.notTracked(invalidated)])

        viewModel.stop()
        await provider.releaseAll()
        await Support.tearDown(source, helper)
    }

    /// The watch renders a licensed snapshot only when it is not the one on screen. Without that
    /// check it renders the same snapshot again at every step, and each render moves `revision`,
    /// which `MenuBarViewModel` follows: the menu bar would be woken twice a second for nothing.
    ///
    /// **Mutation (R4):** delete the early return for the snapshot on screen from
    /// `reassessAuthority()`. Run: red at the `revision` expectation.
    @Test("The watch leaves the snapshot on screen alone, and wakes nothing")
    func theWatchDoesNotRenderTheSnapshotOnScreenAgain() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.freshSource(helper, answering: Support.snapshot())
        let fixture = Self.fixture(on: source)
        let (viewModel, read, watch) = (fixture.viewModel, fixture.read, fixture.watch)

        viewModel.start()
        try await read.waitForSleeps(1)
        try #require(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        let revision = viewModel.revision

        for _ in 0..<3 { await Self.step(watch) }

        #expect(viewModel.revision == revision, "the watch rendered the snapshot on screen again")
        #expect(await watch.sleptSeconds.count >= 4, "the watch did not take its steps")

        viewModel.stop()
        await Support.tearDown(source, helper)
    }
}
