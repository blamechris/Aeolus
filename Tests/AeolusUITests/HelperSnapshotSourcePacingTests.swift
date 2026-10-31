import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// How `HelperSnapshotSource` paces its requests at the edges: a preference changed during a
/// pause, an activation that must not cut a healthy pause, a backoff at a long interval, a
/// contradiction backed off like a failure, and the interval clamp (#478's second delta). The
/// interval change's own duties — a debounce, a backoff cut with its count kept, and no request
/// cancelled — are `HelperSnapshotSourceIntervalTests` (#485).
@Suite("HelperSnapshotSource — pacing at the edges", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourcePacingTests {

    typealias Support = SnapshotTestSupport

    struct Failure: Error {}

    /// A source on `helper` whose interval the test can change, handshaken. An interval change
    /// settles on `settling`, which by default lets it through at once.
    static func source(
        _ helper: FakeSnapshotHelper, interval: RefreshIntervalBox, pacing: any PollingClock,
        settling: any PollingClock = FakePollingClock()
    ) async throws -> HelperSnapshotSource {
        helper.report(.handshaken)
        let source = HelperSnapshotSource(
            reader: helper, refreshInterval: { interval.seconds }, clock: SnapshotTestClock(),
            pacing: pacing, settling: settling)
        try #require(await Support.settle { source.health == .handshaken })
        return source
    }

    /// The pause under way was begun on 60 s. Lowered to 1 s, it must end now, or a healthy
    /// helper's snapshot goes stale and the window waits, reading nothing, for most of a minute.
    ///
    /// **Mutation (N1):** make `refreshIntervalDidChange()` do nothing. Run: red at the settle
    /// wait's `sleptSeconds` expectation and at the `requestsReach` requirement.
    @Test("Changing the interval cuts the pause under way, and the next pause is the new length")
    func changingTheIntervalCutsThePause() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(60)
        let pacing = GatedPollingClock()
        let settling = GatedPollingClock()
        let source = try await Self.source(
            helper, interval: interval, pacing: pacing, settling: settling)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [60])

        interval.seconds = 1
        source.refreshIntervalDidChange()
        _ = await Support.eventually { await settling.parkedCount == 1 }
        #expect(await settling.sleptSeconds == [HelperSnapshotSource.intervalSettleDelay])
        await settling.release()
        let sent = await Support.requestsReach(2, on: helper)
        await pacing.release()
        try #require(sent, "the 60 s pause ran on after the interval became 1 s")
        #expect(await pacing.cancelledSleeps == 1)
        #expect(await helper.peakAtHelper == 1)

        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(2)
        #expect(await pacing.sleptSeconds == [60, 1])

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// The app becomes active all the time; a healthy helper must not be polled faster for it.
    ///
    /// **Mutation (RS1 / MX3):** delete `retrySoon()`'s `consecutiveFailures > 0` guard. Run:
    /// red at both expectations.
    @Test("retrySoon() leaves an ordinary pause alone")
    func retrySoonLeavesAnOrdinaryPause() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Self.source(helper, interval: RefreshIntervalBox(1), pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)

        source.retrySoon()
        let cut = await Support.requestsReach(2, on: helper)
        #expect(!cut, "retrySoon() cut an ordinary pause")
        #expect(await pacing.cancelledSleeps == 0)

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// At 60 s the first backoff step is 120 s, past the 30 s ceiling — and a failing helper
    /// must still never be asked more often than a healthy one is.
    ///
    /// **Mutation (BO1):** `return min(doubled, Self.retryCeiling)` in `nextPause()`. Run: red.
    @Test("A backoff at a long interval is never shorter than the interval")
    func aBackoffIsNeverShorterThanTheInterval() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = FakePollingClock()
        let source = try await Self.source(helper, interval: RefreshIntervalBox(60), pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.fail(with: Failure())
        try await helper.waitForRequests(2)

        #expect(await pacing.sleptSeconds == [60])

        await Support.tearDown(source, helper)
    }

    /// A reply that contradicts itself is answered like a failure: the source falls back to
    /// direct reads, and backs off rather than asking the same helper again at full rate.
    ///
    /// **Mutation (CT3):** don't count a contradiction toward `consecutiveFailures`. Run: red.
    @Test("A self-contradicting reply is backed off like a failure")
    func aContradictionIsBackedOff() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = FakePollingClock()
        let source = try await Self.source(helper, interval: RefreshIntervalBox(1), pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot(fans: [Support.fan(0), Support.fan(0)]))
        try await helper.waitForRequests(2)

        #expect(await pacing.sleptSeconds == [2])

        await Support.tearDown(source, helper)
    }

    /// The interval is clamped as `PollingViewModel` clamps its own: a zero or negative
    /// preference becomes the minimum, for the pause and for the bound alike.
    ///
    /// **Mutation (IC1):** return the interval unclamped. Run: red at both expectations, for both
    /// arguments. (The non-finite cases below are not run under IC1: an unclamped NaN traps in
    /// `Duration.seconds(_:)` rather than failing an expectation.)
    @Test("A zero or negative interval is clamped to the minimum", arguments: [0.0, -5.0])
    func theIntervalIsClamped(_ seconds: Double) async throws {
        try await Self.expectClampedToTheMinimum(seconds)
    }

    @Test(
        "A non-finite interval is clamped to the minimum",
        arguments: [Double.nan, Double.infinity])
    func aNonFiniteIntervalIsClamped(_ seconds: Double) async throws {
        try await Self.expectClampedToTheMinimum(seconds)
    }

    private static func expectClampedToTheMinimum(_ seconds: Double) async throws {
        let helper = FakeSnapshotHelper()
        let pacing = FakePollingClock()
        let source = try await source(helper, interval: RefreshIntervalBox(seconds), pacing: pacing)
        let minimum = PollingViewModel.minimumRefreshInterval
        #expect(source.freshnessBound == .seconds(minimum) + HelperClientDeadlines.gatedVerb)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)
        #expect(await pacing.sleptSeconds == [minimum])

        await Support.tearDown(source, helper)
    }

    @Test("A source has a reader exactly when it was given one")
    func hasReaderSaysWhetherThereIsAHelper() {
        #expect(!HelperSnapshotSource(withoutHelper: .noHelperInThisBuild).hasReader)
        #expect(!HelperSnapshotSource(withoutHelper: .helperInstallIncomplete).hasReader)
        #expect(Support.source(FakeSnapshotHelper()).hasReader)
    }
}
