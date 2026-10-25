import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// What a new handshake owes before anything is read (#501, ADR 0006): between a handshake and
/// the reply its request was sent for, the app reads **nothing**, even when the request before
/// it failed.
///
/// `HelperClient.snapshot()` handshakes inside its own request (`withHandshakenProxy`), and
/// `performHandshake` publishes `.handshaken` before that request's `snapshot` is sent. So a
/// source always hears a new handshake while the request it is for is still out. The request
/// before it can have failed on the connection before: a `hello` the replacement helper did not
/// answer, a helper not yet approved, a refusal. That connection is gone, and a failure recorded
/// before a handshake says nothing about the connection the handshake made.
///
/// Every request is parked on `FakeSnapshotHelper`, and every pause on a `GatedPollingClock`,
/// so the test, not a scheduler, decides what the source has heard when the view model ticks.
/// The fake publishes health only when the test reports it, in the order `HelperClient`
/// publishes it: the failure's health before the failure is thrown (`discardConnection`), a new
/// connection's `.idle`, then `.handshaken` from its `hello`.
@Suite(
    "HelperSnapshotSource — nothing is read between a handshake and its reply",
    .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceHandshakeTests {

    typealias Support = SnapshotTestSupport

    /// The failure a `hello` gives when nothing answers it: libxpc's 4099.
    static let unreachable = HelperClientError.helperUnreachable(code: 4099)

    /// The issue's sequence. The connection leaves `.handshaken`; the next request fails; the
    /// one after it handshakes; the view model ticks before that request's reply.
    ///
    /// **Mutation (HS1):** delete the `retireFailureFromBeforeTheHandshake()` call in
    /// `HelperSnapshotSource.observe(_:)`. Run: red at the window's `authority`, read-count,
    /// `phase` and `controlSource` expectations, for every argument.
    @Test(
        "After a failed request, a reconnect's handshake waits for its reply and reads nothing",
        arguments: HealthTag.departures.filter { $0 != .idle })
    func aFailureBeforeTheHandshakeLicensesNoReadAfterIt(
        _ departure: HelperConnectionHealth
    ) async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing)
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        // 1. Handshaken, answered, on screen, and nothing read.
        try await Self.answerOnce(source, helper, pacing)
        await Support.tickEnds(viewModel)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        let readsWhileAnswered = await Support.readCount(provider)
        #expect(readsWhileAnswered == 0)

        // 2. The connection leaves `.handshaken` during the pause. ADR 0006's fallback reads.
        try await Support.report(departure, to: source, from: helper)
        let gone = ControlNotTracked.helperConnection(departure)
        #expect(source.authority() == .readDirectly(gone))
        await Support.tickEnds(viewModel)
        #expect(viewModel.controlSource == .notTracked(gone))
        let readsWhileGone = await Support.readCount(provider)
        #expect(readsWhileGone > 0)

        // 3 and 4. The next request fails; the one after it handshakes.
        try await Self.failThenHandshake(source, helper, pacing)

        // 5. The window: handshaken, and request 3's reply not in yet.
        #expect(source.authority() == .awaitHelper(.awaitingSnapshot))
        let readsBefore = await Support.readCount(provider)
        await Support.tickEnds(viewModel)
        let readsInTheWindow = await Support.readCount(provider) - readsBefore
        #expect(readsInTheWindow == 0, "the SMC was read between the handshake and its reply")
        #expect(viewModel.phase == .waitingForHelper)
        #expect(viewModel.controlSource == .notTracked(.awaitingSnapshot))

        // 6. The reply the handshake was for is the first good one, and it is rendered.
        let second = Support.snapshot(fans: [Support.fan(0, actual: 3000)])
        await helper.reply(with: second)
        try await pacing.waitForSleeps(3)
        #expect(Support.freshSnapshot(source) == second)
        await Support.tickEnds(viewModel)
        #expect(viewModel.controlSource == .helperSnapshot(activeLease: nil))
        #expect(viewModel.renderedSnapshot == second)
        let readsSinceTheHandshake = await Support.readCount(provider) - readsBefore
        #expect(readsSinceTheHandshake == 0)

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// The same window with no departure at all: the first `hello` of the app's life failed
    /// because the helper was not approved yet, and the user has just approved it. The episode
    /// has never moved, so this is the case a rule about departures cannot reach.
    ///
    /// **Mutation (HS1)**, as above. Run: red at the window's `authority`, read-count and
    /// `controlSource` expectations.
    @Test("After a failed first request, the first handshake waits for its reply and reads nothing")
    func theFirstHandshakeAfterAFailureReadsNothing() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = Support.source(helper, pacing: pacing)  // `.idle`, as at launch
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        source.start()
        try await helper.waitForRequests(1)
        try await Support.report(.invalidated, to: source, from: helper)
        await helper.fail(with: Self.unreachable)
        try await pacing.waitForSleeps(1)
        #expect(source.authority() == .readDirectly(.helperConnection(.invalidated)))

        // Approved: `retrySoon()` cuts the backoff, as `AeolusApp` does on `.enabled`.
        source.retrySoon()
        try await helper.waitForRequests(2)
        try await Support.report(.idle, to: source, from: helper)
        try await Support.report(.handshaken, to: source, from: helper)

        #expect(source.authority() == .awaitHelper(.awaitingSnapshot))
        let readsBefore = await Support.readCount(provider)
        await Support.tickEnds(viewModel)
        let readsInTheWindow = await Support.readCount(provider) - readsBefore
        #expect(readsInTheWindow == 0)
        #expect(viewModel.controlSource == .notTracked(.awaitingSnapshot))

        let first = Support.snapshot()
        await helper.reply(with: first)
        try await pacing.waitForSleeps(2)
        #expect(Support.freshSnapshot(source) == first)

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// The other side of the line. A request that fails **after** the handshake was heard
    /// failed on the connection that is handshaken now, and the fallback reads, as it does for
    /// any failed request (`aFailedRequestLicensesNothing`). Retiring what came before the
    /// handshake must not retire this. The request was sent before the handshake, so a rule
    /// keyed on the send — its episode, or the health then — cannot keep this one and drop the
    /// one before it.
    ///
    /// **Mutation (HS2):** in `observe(_:)`, advance the episode on arriving at `.handshaken`
    /// too, the fix the issue warned against. Run: red at the `.readDirectly` expectation, the
    /// read count and `controlSource`, here, and at the first good reply in
    /// `aFailureBeforeTheHandshakeLicensesNoReadAfterIt` and in
    /// `theFirstReplyOfAConnectionIsRendered`.
    @Test("A request that fails after the new handshake still reads directly")
    func aFailureAfterTheHandshakeStillReadsDirectly() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing)
        let provider = Support.directProvider()
        let viewModel = PollingViewModel(
            provider: provider, clock: FakePollingClock(), snapshots: source)

        try await Self.answerOnce(source, helper, pacing)
        try await Support.report(.interrupted, to: source, from: helper)
        try await Self.failThenHandshake(source, helper, pacing)
        #expect(source.authority() == .awaitHelper(.awaitingSnapshot))

        // The `hello` succeeded; the `snapshot` behind it did not.
        await helper.fail(with: HelperClientError.replyNotDelivered)
        try await pacing.waitForSleeps(3)
        let failed = ControlNotTracked.snapshotRequestFailed(
            detail: HelperAuthoredText.sanitised(
                HelperClientError.replyNotDelivered.errorDescription ?? ""))
        #expect(source.authority() == .readDirectly(failed))

        let readsBefore = await Support.readCount(provider)
        await Support.tickEnds(viewModel)
        let readsAfterTheFailure = await Support.readCount(provider) - readsBefore
        #expect(readsAfterTheFailure > 0)
        #expect(viewModel.controlSource == .notTracked(failed))

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// Only a failure is retired. A reply came through a handshake of its own, so it is this
    /// handshake's answer even when it is recorded before the source hears `.handshaken`.
    /// `HelperClient` publishes `.handshaken` before it sends the `snapshot`, so the source
    /// normally hears the handshake first; this pins the rule for the other order rather than
    /// leaning on that one.
    ///
    /// **Mutation (HS3):** delete the `guard case .failed` line in
    /// `retireFailureFromBeforeTheHandshake()`, so every answer is retired. Run: red at
    /// `freshSnapshot == reply`.
    @Test("A reply recorded before its handshake is heard is not retired by it")
    func aReplyIsNeverRetired() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = Support.source(helper, pacing: pacing)  // `.idle`, as at launch

        source.start()
        try await helper.waitForRequests(1)
        let reply = Support.snapshot()
        await helper.reply(with: reply)
        try await pacing.waitForSleeps(1)
        #expect(source.authority() == .awaitHelper(.helperConnection(.idle)))

        try await Support.report(.handshaken, to: source, from: helper)
        #expect(Support.freshSnapshot(source) == reply)

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    // MARK: - The sequence

    /// Starts `source`, answers its first request, and returns with the pause after it parked.
    static func answerOnce(
        _ source: HelperSnapshotSource, _ helper: FakeSnapshotHelper, _ pacing: GatedPollingClock
    ) async throws {
        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot(fans: [Support.fan(0, actual: 2000)]))
        try await pacing.waitForSleeps(1)
    }

    /// From `answerOnce`, with the connection already gone: the next request fails on it, after
    /// the client has given it up, and the one after builds a new connection whose `hello`
    /// succeeds. Returns with that third request parked and `.handshaken` heard.
    static func failThenHandshake(
        _ source: HelperSnapshotSource, _ helper: FakeSnapshotHelper,
        _ pacing: GatedPollingClock, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        await pacing.release()
        try await helper.waitForRequests(2)
        try await Support.report(.invalidated, to: source, from: helper)
        await helper.fail(with: unreachable)
        try await pacing.waitForSleeps(2)
        #expect(
            source.authority() == .readDirectly(.helperConnection(.invalidated)),
            sourceLocation: sourceLocation)

        await pacing.release()
        try await helper.waitForRequests(3)
        try await Support.report(.idle, to: source, from: helper)
        #expect(
            source.authority() == .awaitHelper(.helperConnection(.idle)),
            sourceLocation: sourceLocation)
        try await Support.report(.handshaken, to: source, from: helper)
    }
}
