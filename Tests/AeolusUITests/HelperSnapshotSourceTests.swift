import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `HelperSnapshotSource`: one request in flight, never cancelled; only a snapshot from the
/// current handshaken episode; freshness measured from arrival on its own clock; direct reads
/// only where ADR 0006 allows them; and no client at all in a build with no helper (#156, #419).
///
/// Every request is parked on `FakeSnapshotHelper` until the test answers it, so "one in
/// flight" is a count the fake keeps — `peakAtHelper` — and not something an actor hands out
/// for free. Nothing here waits on a real clock. Every wait is either bounded (`settle`,
/// `requestsReach`) or ends by throwing when the test is cancelled, so `.timeLimit` ends a
/// hung test as a red rather than leaving `swift test` running.
@Suite("HelperSnapshotSource — one request at a time, fresh from arrival", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceTests {

    typealias Support = SnapshotTestSupport

    // MARK: - One in flight, never cancelled (#419)

    /// **Mutation (M1):** in `HelperSnapshotSource.stop()`, add `outstanding?.cancel()` after
    /// `pause?.cancel()`. Run: red at the `cancellations == 0` expectation straight after
    /// `stop()`, and at both `peakAtHelper == 1` expectations, because the loop then sends a
    /// second request while the first is still at the helper.
    @Test("stop() leaves the request in flight alone, and a restart sends nothing until it ends")
    func stopDoesNotCancelAndRestartWaits() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)

        source.stop()
        #expect(helper.cancellations == 0, "stop() cancelled the request in flight")
        #expect(source.hasOutstandingRequest)

        source.start()
        // Let anything a second loop would do happen before the first reply is given.
        _ = await Support.settle(turns: 200) { false }
        #expect(await helper.requests == 1, "a restart sent a request beside the outstanding one")

        let first = Support.snapshot(fans: [Support.fan(actual: 2001)])
        await helper.reply(with: first)
        try await helper.waitForRequests(2)

        #expect(await helper.peakAtHelper == 1)
        #expect(helper.cancellations == 0)
        #expect(Support.freshSnapshot(source) == first)

        await Support.tearDown(source, helper)
        // Again after the teardown, so the finding does not rest on the 200-turn window above.
        #expect(await helper.peakAtHelper == 1)
    }

    @Test("A reply that arrives after the last consumer stops is kept, and nothing more is sent")
    func aReplyAfterStopIsKept() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        source.stop()

        let late = Support.snapshot(fans: [Support.fan(actual: 3003)])
        await helper.reply(with: late)
        try #require(await Support.settle { !source.isLoopRunning })

        #expect(await helper.requests == 1)
        #expect(!source.hasOutstandingRequest)
        #expect(Support.freshSnapshot(source) == late)
    }

    @Test("The loop runs while any consumer wants it, and ends when the last one leaves")
    func theSourceRunsWhileAnyConsumerWantsIt() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()  // the window
        source.start()  // the menu bar
        try await helper.waitForRequests(1)

        source.stop()  // the window closes
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)  // the menu bar's snapshots carry on

        source.stop()  // the menu bar goes too
        await helper.reply(with: Support.snapshot())
        try #require(await Support.settle { !source.isLoopRunning })
        #expect(await helper.requests == 2)
        #expect(await helper.peakAtHelper == 1)
    }

    /// **Mutation (E):** delete `guard demand > 0 else { return }` from `stop()`. Run: red at
    /// `consumerCount == 0` after the second `stop()` (it reads -1) and at the `requestsReach`
    /// requirement, because the `start()` after it only brings the count back to zero.
    @Test("A stop() with no consumer left does nothing, so a later start() still runs the loop")
    func anExtraStopTakesNothingAway() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.stop()
        source.start()
        source.stop()
        source.stop()
        #expect(source.consumerCount == 0)

        source.start()
        #expect(source.consumerCount == 1)
        try #require(await Support.requestsReach(1, on: helper))

        await Support.tearDown(source, helper)
    }

    /// **Mutation (B):** delete `pause?.cancel()` from `stop()`. Run: red at the
    /// `isLoopRunning` requirement — the loop stays parked in a pause nothing ends.
    @Test("stop() cuts the pause between requests short")
    func stopCutsThePauseShort() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await pacing.waitForSleeps(1)

        source.stop()
        let ended = await Support.settle { !source.isLoopRunning }
        await pacing.release()  // so a mutated loop does not outlive the test
        try #require(ended, "the pause was not cut short")
        #expect(await pacing.cancelledSleeps == 1)
        #expect(await helper.requests == 1)

        await Support.tearDown(source, helper)
    }

    // MARK: - Only this episode's snapshot (C1)

    /// The helper process is replaced, or the connection drops and is rebuilt, during a pause:
    /// health leaves `.handshaken` and returns to it — `HelperClient` publishes `.handshaken`
    /// from the new `hello` before the next snapshot's reply. Nothing the old process said may
    /// be shown in the meantime, however young it is.
    ///
    /// **Mutation (M-C1a):** in `authority()`, drop `latest.episode == episode` from the guard.
    /// **Mutation (M-C1b):** delete the `episode &+= 1` in `observe(_:)`. Run, each: red at
    /// the `freshSnapshot == nil` expectation, and in the view model's emergency, control and
    /// lease expectations, for every argument.
    @Test(
        "A snapshot from before a departure is never rendered once the connection handshakes again",
        arguments: [HelperConnectionHealth.interrupted, .invalidated, .idle])
    func aReconnectNeverRevivesTheDeadProcessSnapshot(
        _ departure: HelperConnectionHealth
    ) async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        let viewModel = PollingViewModel(
            provider: FakeSensorProvider(isAvailable: false), clock: FakePollingClock(),
            snapshots: source)

        source.start()
        try await helper.waitForRequests(1)
        let old = Support.snapshot(
            fans: [Support.fan(0, mode: .manualFixed, target: 3000)],
            activeLease: Lease(holderDescription: "fanctl", expiresAt: Date()),
            isThermalEmergencyActive: true)
        await helper.reply(with: old)
        try await helper.waitForRequests(2)  // request 2 parked: the one that re-handshakes
        await Support.tickEnds(viewModel)
        #expect(viewModel.thermalEmergency == .active)

        try await Support.report(departure, to: source, from: helper)
        try await Support.report(.handshaken, to: source, from: helper)

        #expect(Support.freshSnapshot(source) == nil, "the dead process's snapshot is current")
        #expect(source.authority() == .awaitHelper(.awaitingSnapshot))

        await Support.tickEnds(viewModel)
        #expect(viewModel.thermalEmergency == .unknown)
        #expect(viewModel.fans.map(\.control) == [.notTracked(.awaitingSnapshot)])
        #expect(viewModel.controlSource == .notTracked(.awaitingSnapshot))

        await Support.tearDown(source, helper)
    }

    /// A request sent before a departure and answered after it is not this episode's answer.
    ///
    /// **Mutation (M-C1c):** in `run(_:)`, pass `sentIn: episode` read after the reply rather
    /// than the value taken before the request was sent. Run: red at `freshSnapshot == nil`.
    @Test("A reply that straddles a departure is not rendered")
    func aReplyThatStraddlesADepartureIsDropped() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        try await Support.report(.interrupted, to: source, from: helper)
        try await Support.report(.handshaken, to: source, from: helper)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)

        #expect(Support.freshSnapshot(source) == nil)
        #expect(Support.notTracked(source) == .awaitingSnapshot)

        await Support.tearDown(source, helper)
    }

    @Test("The first reply after the handshake that happened inside its own request is rendered")
    func theFirstReplyOfAConnectionIsRendered() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)  // still .idle, as before any connection

        source.start()
        try await helper.waitForRequests(1)
        try await Support.report(.handshaken, to: source, from: helper)
        let first = Support.snapshot()
        await helper.reply(with: first)
        try await helper.waitForRequests(2)

        #expect(Support.freshSnapshot(source) == first)

        await Support.tearDown(source, helper)
    }

    // MARK: - Fresh, measured from arrival

    /// **Mutation (M3a):** delete the `freshnessBound` guard in `authority()`. Run: red at the
    /// `.snapshotStale` expectation.
    @Test("A snapshot is fresh until refreshInterval + gatedVerb after it arrived, then stale")
    func freshUntilTheBoundThenStale() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock, refreshInterval: 1)
        #expect(source.freshnessBound == .seconds(1) + HelperClientDeadlines.gatedVerb)

        source.start()
        try await helper.waitForRequests(1)
        let reply = Support.snapshot()
        await helper.reply(with: reply)
        try await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound - .milliseconds(1))
        #expect(Support.freshSnapshot(source) == reply)

        clock.advance(by: .milliseconds(1))
        #expect(source.authority() == .awaitHelper(.snapshotStale))

        await Support.tearDown(source, helper)
    }

    /// The stamp is taken when the reply arrives, not when the request was sent. The clock moves
    /// four seconds while the request is parked, which is what makes the placement visible: a
    /// frozen clock reads the same at both instants.
    ///
    /// **Mutation (M3c):** in `run(_:)`, capture `let sentAt = now()` before the request is
    /// created and record it in place of the `now()` in `record(_:sentIn:)`. Run: red at the
    /// `freshSnapshot` expectation.
    @Test("Age is counted from the reply's arrival, not from the request's send")
    func ageIsCountedFromArrival() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock)

        source.start()
        try await helper.waitForRequests(1)
        clock.advance(by: .seconds(4))
        let reply = Support.snapshot()
        await helper.reply(with: reply)
        try await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound - .milliseconds(1))
        #expect(Support.freshSnapshot(source) == reply)

        await Support.tearDown(source, helper)
    }

    /// `capturedAt` is the helper's wall clock. Here it says the snapshot is fifty-six years
    /// old, and the reply arrived just now.
    ///
    /// **Mutation (M3b):** in `authority()`, judge `Date().timeIntervalSince(snapshot.capturedAt)`
    /// against the bound instead of the arrival instant. Run: red here.
    @Test("A capturedAt far in the past does not make a snapshot that just arrived stale")
    func aPastCapturedAtIsNotTheAge() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        let reply = Support.snapshot(capturedAt: Date(timeIntervalSince1970: 0))
        await helper.reply(with: reply)
        try await helper.waitForRequests(2)

        #expect(Support.freshSnapshot(source) == reply)

        await Support.tearDown(source, helper)
    }

    /// The other direction: a helper clock that has jumped ahead must not keep a snapshot fresh.
    ///
    /// **Mutation (M3b):** the same as `aPastCapturedAtIsNotTheAge`'s. Run: red here.
    @Test("A capturedAt in the future does not keep an old snapshot fresh")
    func aFutureCapturedAtIsNotTheAge() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot(capturedAt: .distantFuture))
        try await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound)
        #expect(Support.notTracked(source) == .snapshotStale)

        await Support.tearDown(source, helper)
    }

    /// **Mutation (I2):** read the interval once, in `init`, into a stored constant. Run: red at
    /// the second `freshnessBound` expectation and at the `sleptSeconds` one.
    @Test("The refresh interval is read live, for the pause and for the freshness bound")
    func theRefreshIntervalIsReadLive() async throws {
        let helper = FakeSnapshotHelper()
        let interval = RefreshIntervalBox(1)
        let pacing = FakePollingClock()
        helper.report(.handshaken)
        let source = HelperSnapshotSource(
            reader: helper, refreshInterval: { interval.seconds }, clock: SnapshotTestClock(),
            pacing: pacing)
        try #require(await Support.settle { source.health == .handshaken })
        #expect(source.freshnessBound == .seconds(1) + HelperClientDeadlines.gatedVerb)

        interval.seconds = 60
        #expect(source.freshnessBound == .seconds(60) + HelperClientDeadlines.gatedVerb)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)
        #expect(await pacing.sleptSeconds == [60])

        await Support.tearDown(source, helper)
    }
}
