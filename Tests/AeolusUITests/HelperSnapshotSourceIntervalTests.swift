import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// What `HelperSnapshotSource.refreshIntervalDidChange()` does besides cutting a pause, which
/// `HelperSnapshotSourcePacingTests.changingTheIntervalCutsThePause` pins: it waits for the
/// interval to hold still, it cuts a backoff's pause and keeps the failure count, and it never
/// cancels a request (#485 S2 and NX).
///
/// Every source here waits on two held clocks, one between requests and one for the interval to
/// hold still, so the test decides when each wait ends.
@Suite("HelperSnapshotSource — the refresh interval changing", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceIntervalTests {

    typealias Support = SnapshotTestSupport

    struct Failure: Error {}

    /// A started source on `helper`, handshaken, its interval in `interval`.
    private static func started(
        _ helper: FakeSnapshotHelper, interval: RefreshIntervalBox,
        pacing: GatedPollingClock, settling: GatedPollingClock
    ) async throws -> HelperSnapshotSource {
        let source = try await HelperSnapshotSourcePacingTests.source(
            helper, interval: interval, pacing: pacing, settling: settling)
        source.start()
        try await helper.waitForRequests(1)
        return source
    }

    /// Lets the interval's wait run its course, and waits (bounded) until its cut has been made.
    private static func settle(
        _ source: HelperSnapshotSource, on settling: GatedPollingClock
    ) async throws {
        try #require(await Support.eventually { await settling.parkedCount >= 1 })
        await settling.release()
        try #require(await Support.settle { !source.isWaitingForTheIntervalToSettle })
    }

    /// A drag through the Settings slider is a change at every 0.1 s step. A healthy helper
    /// answers each request at once, so a change that cut the pause left a new pause for the
    /// next change to cut: a request per step, each a whole snapshot from the helper. A drag must
    /// send nothing until the interval holds still, and then one request.
    ///
    /// **Mutation (S2):** remove the debounce — `refreshIntervalDidChange()` cuts the pause at
    /// once, as `5b324df` did. Run: red at the `requests == 1` expectation after the drag.
    @Test("Dragging the interval through twenty values sends one request, once it holds still")
    func aDragSendsOneRequest() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(60)
        let pacing = GatedPollingClock()
        let settling = GatedPollingClock()
        let source = try await Self.started(
            helper, interval: interval, pacing: pacing, settling: settling)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)

        // Twenty steps of a drag. Each step waits, boundedly, until its change is either waiting
        // to hold still or has sent a request; a request is answered before the next step, so a
        // step that cut the pause leaves another for the next one to cut.
        var answered = 1
        for step in 1...20 {
            interval.seconds = 60 - Double(step) * 0.1
            source.refreshIntervalDidChange()
            _ = await Support.eventually {
                let waiting = await settling.sleptSeconds.count
                let sent = await helper.requests
                return waiting >= step || sent > answered
            }
            if await helper.requests > answered {
                answered += 1
                await helper.reply(with: Support.snapshot())
                try await pacing.waitForSleeps(answered)
            }
        }
        #expect(await helper.requests == 1, "the drag sent a request per step")

        // The interval holds still: the last change's wait runs its course and cuts the pause.
        try await Self.settle(source, on: settling)
        let sent = await Support.requestsReach(2, on: helper)
        await pacing.release()
        try #require(sent, "the interval held still and the pause ran on")
        _ = await Support.settle(turns: 200) { false }
        #expect(await helper.requests == 2)
        #expect(await helper.peakAtHelper == 1)

        await Support.tearDown(source, helper)
    }

    /// #419's rule for the read side: nothing here cancels a request, because `HelperClient`
    /// keeps a cancelled caller's message in flight with its deadline running. A change that
    /// settles while a request is outstanding finds no pause to cut: it cancels nothing and sends
    /// nothing beside the request, and the pause after that request is the new length.
    ///
    /// **Mutation (NX):** in `intervalHasSettled()`, also call `outstanding?.cancel()`. Run: red
    /// at `cancellations == 0`.
    @Test("An interval change while a request is in flight cancels nothing and sends nothing")
    func anIntervalChangeNeverCancelsARequest() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(1)
        let pacing = GatedPollingClock()
        let settling = GatedPollingClock()
        let source = try await Self.started(
            helper, interval: interval, pacing: pacing, settling: settling)
        try #require(source.hasOutstandingRequest)

        interval.seconds = 5
        source.refreshIntervalDidChange()
        try await Self.settle(source, on: settling)

        #expect(helper.cancellations == 0)
        #expect(await helper.requests == 1)
        #expect(await helper.peakAtHelper == 1)

        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [5])

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// A changed interval cuts a backoff's pause as well as an ordinary one, and keeps the failure
    /// count: a failing helper is asked once more, and if that request fails too, the pause after
    /// it is the backoff's next step on the new interval. `retrySoon()` starts the count again;
    /// this does not.
    ///
    /// **Mutation (KC):** in `intervalHasSettled()`, also set `consecutiveFailures = 0`. Run: red
    /// at the second `sleptSeconds` expectation. **Mutation (BP):** cut only an ordinary pause —
    /// `guard consecutiveFailures == 0` in `intervalHasSettled()`. Run: red at the `sent`
    /// requirement.
    @Test("A changed interval cuts a backoff too, and keeps the failure count")
    func anIntervalChangeCutsABackoffAndKeepsTheCount() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(1)
        let pacing = GatedPollingClock()
        let settling = GatedPollingClock()
        let source = try await Self.started(
            helper, interval: interval, pacing: pacing, settling: settling)
        await helper.fail(with: Failure())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [2])

        interval.seconds = 3
        source.refreshIntervalDidChange()
        try await Self.settle(source, on: settling)
        let sent = await Support.requestsReach(2, on: helper)
        await pacing.release()
        try #require(sent, "the change left the backoff's pause running")
        #expect(await pacing.cancelledSleeps == 1)

        await helper.fail(with: Failure())
        try await pacing.waitForSleeps(2)
        // The second failure, at 3 s: 3 × 2² = 12. A count started again would give 3 × 2 = 6.
        #expect(await pacing.sleptSeconds == [2, 12], "the failure count was started again")

        await pacing.release()
        await Support.tearDown(source, helper)
    }
}
