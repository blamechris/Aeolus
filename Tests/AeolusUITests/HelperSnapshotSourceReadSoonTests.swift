import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `HelperSnapshotSource.readSoon()`, the read the app asks for when the lease driver stops acting
/// (ADR 0015 D2): it cuts an ordinary pause by the cut a settled interval change makes, and it
/// keeps #419's rule, #478's backoff and #485's debounce as they were.
///
/// Every source here waits on held clocks, one between requests and one for the interval to hold
/// still, so the test decides when each wait ends, and every request is parked until it answers.
@Suite("HelperSnapshotSource — a read soon after the driver stops acting", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceReadSoonTests {

    typealias Support = SnapshotTestSupport

    struct Failure: Error {}

    /// A started source at a 60 s interval whose first request is parked.
    private static func started(
        _ helper: FakeSnapshotHelper, interval: RefreshIntervalBox = RefreshIntervalBox(60),
        pacing: GatedPollingClock, settling: GatedPollingClock = GatedPollingClock()
    ) async throws -> HelperSnapshotSource {
        let source = try await HelperSnapshotSourcePacingTests.source(
            helper, interval: interval, pacing: pacing, settling: settling)
        source.start()
        try await helper.waitForRequests(1)
        return source
    }

    /// **Mutation (F10a, "no read soon"):** make `readSoon()` do nothing. Run: red at the
    /// `requestsReach(2)` requirement, here and in `AutomaticAfterAReadTests`.
    @Test("readSoon() cuts an ordinary pause, and the pause after the read is the interval's")
    func readSoonCutsAnOrdinaryPause() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Self.started(helper, pacing: pacing)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [60])

        source.readSoon()
        let sent = await Support.requestsReach(2, on: helper)
        try #require(sent, "the 60 s pause ran on after readSoon()")
        #expect(await pacing.cancelledSleeps == 1)
        #expect(await helper.peakAtHelper == 1)

        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(2)
        #expect(await pacing.sleptSeconds == [60, 60], "one read, then the interval again")
        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// With a request in flight there is no pause to cut. The request is left alone, and no second
    /// one is sent beside it (#419), but its ticket may predate what the read is for, so the pause
    /// after it is skipped, once.
    ///
    /// **Mutation (F10b, "a request in flight drops the read"):** in `readSoon()`, delete
    /// `readOwed = true`. Run: red at the `requestsReach(2)` requirement.
    /// **Mutation (F10c, "the request cancelled"):** in `readSoon()`, call `outstanding?.cancel()`
    /// first. Run: red at `cancellations == 0`.
    @Test("readSoon() with a request in flight leaves it, and skips the pause after it once")
    func readSoonWithARequestInFlight() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Self.started(helper, pacing: pacing)

        source.readSoon()
        #expect(source.hasOutstandingRequest, "the request in flight is left alone")
        #expect(helper.cancellations == 0, "and not cancelled")
        await helper.reply(with: Support.snapshot())
        let sent = await Support.requestsReach(2, on: helper)
        try #require(sent, "the pause after the request in flight ran")
        #expect(await pacing.sleptSeconds.isEmpty, "no pause between the two")
        #expect(await helper.peakAtHelper == 1)

        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [60], "skipped once, then paced again")
        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// A failing helper is not asked again sooner for it, and its count is not touched.
    ///
    /// **Mutation (F10d, "a backoff cut"):** delete `consecutiveFailures == 0` from `readSoon()`'s
    /// guard. Run: red at `!sent`.
    @Test("readSoon() leaves a backoff alone")
    func readSoonLeavesABackoff() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Self.started(helper, pacing: pacing)
        await helper.fail(with: Failure())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [60], "a backoff at 60 s is 60 s")

        source.readSoon()
        let sent = await Support.eventually(turns: 2_000) { await helper.requests >= 2 }
        #expect(!sent, "a backoff was cut")
        #expect(await pacing.cancelledSleeps == 0)
        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// The interval's wait to hold still goes on, and its cut lands as before.
    ///
    /// **Mutation (F10e, "the debounce ended"):** in `readSoon()`, call `intervalSettle?.cancel()`
    /// first. Run: red at `isWaitingForTheIntervalToSettle`.
    @Test("readSoon() leaves the interval's debounce alone")
    func readSoonLeavesTheDebounce() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(60)
        let pacing = GatedPollingClock()
        let settling = GatedPollingClock()
        let source = try await Self.started(
            helper, interval: interval, pacing: pacing, settling: settling)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)
        interval.seconds = 30
        source.refreshIntervalDidChange()
        try #require(await Support.eventually { await settling.parkedCount == 1 })

        source.readSoon()
        try #require(await Support.requestsReach(2, on: helper))
        #expect(source.isWaitingForTheIntervalToSettle, "the slider's wait was ended")
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(2)
        #expect(await pacing.sleptSeconds == [60, 30])

        await settling.release()
        try #require(await Support.settle { !source.isWaitingForTheIntervalToSettle })
        let cut = await Support.requestsReach(3, on: helper)
        await pacing.release()
        #expect(cut, "the settled change's cut landed")
        await Support.tearDown(source, helper)
    }
}
