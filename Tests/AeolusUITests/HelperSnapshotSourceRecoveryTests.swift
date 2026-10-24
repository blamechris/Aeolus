import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `HelperSnapshotSource` when the helper is not simply answering: which connection states
/// read the SMC directly and which wait (ADR 0006), how a failed or self-contradicting reply
/// is reported, and how a backoff grows and is cut short (#156, #478's review).
@Suite("HelperSnapshotSource — direct reads, failures and backoff", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceRecoveryTests {

    typealias Support = SnapshotTestSupport

    // MARK: - Health, and where direct reads are allowed (ADR 0006)

    /// `.idle` waits; every other state but `.handshaken` reads directly.
    ///
    /// **Mutation (M2):** delete the `health == .handshaken` guard in `authority()` — keep
    /// rendering the last snapshot. Run: red at the `notTracked` and authority expectations for
    /// every argument.
    @Test(
        "Leaving .handshaken withdraws the snapshot, and reads directly unless idle",
        arguments: HealthTag.departures)
    func leavingHandshakenWithdrawsTheSnapshot(_ health: HelperConnectionHealth) async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)
        #expect(Support.freshSnapshot(source) != nil)

        try await Support.report(health, to: source, from: helper)
        let why = ControlNotTracked.helperConnection(health)
        #expect(Support.notTracked(source) == why)
        #expect(source.authority() == (health == .idle ? .awaitHelper(why) : .readDirectly(why)))

        await Support.tearDown(source, helper)
    }

    /// **Mutation (I1):** in `authority()`, return `.readDirectly(why)` for `.idle` too. Run:
    /// red here and in `PollingViewModelSnapshotTests.noDirectReadsWhileTheHelperIsExpected`.
    @Test("Before the helper's health has been heard, the source asks for a wait, not a read")
    func aReplyBeforeHandshakenLicensesNothing() async throws {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)
        #expect(source.authority() == .awaitHelper(.helperConnection(.idle)))

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)

        #expect(source.authority() == .awaitHelper(.helperConnection(.idle)))

        await Support.tearDown(source, helper)
    }

    @Test("Handshaken with nothing yet in this episode, the source asks for a wait")
    func handshakenWithNoAnswerWaits() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        #expect(source.authority() == .awaitHelper(.awaitingSnapshot))
    }

    // MARK: - Failures and refusals

    struct HostileError: Error, LocalizedError {
        var errorDescription: String? { "refused\u{202E}evil\nforged line" }
    }

    @Test("A failed request licenses nothing, reads directly, and its description is cleaned")
    func aFailedRequestLicensesNothing() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(2)
        await helper.fail(with: HostileError())
        try await helper.waitForRequests(3)

        #expect(
            source.authority()
                == .readDirectly(.snapshotRequestFailed(detail: "refusedevilforged line")))

        await Support.tearDown(source, helper)
    }

    /// **Mutation (M11):** in `nextPause()`, change `guard consecutiveFailures > 0` to `guard
    /// consecutiveFailures > 1_000_000`, so every pause is `refreshInterval`. Run: red at the
    /// `sleptSeconds` expectation.
    @Test("Failures double the pause up to the ceiling, and a reply resets it")
    func failuresBackOffAndAReplyResets() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = FakePollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing, refreshInterval: 1)

        source.start()
        for request in 1...6 {
            try await helper.waitForRequests(request)
            await helper.fail(with: HostileError())
        }
        try await helper.waitForRequests(7)
        await helper.reply(with: Support.snapshot())
        try await helper.waitForRequests(8)

        #expect(await pacing.sleptSeconds == [2, 4, 8, 16, 30, 30, 1])

        await Support.tearDown(source, helper)
    }

    /// **Mutation (R1):** delete `pause?.cancel()` from `retrySoon()`. Run: red at the
    /// `requestsReach(2)` requirement. **Mutation (R2):** delete `consecutiveFailures = 0`
    /// there. Run: red at the second `sleptSeconds` expectation.
    @Test("retrySoon() ends a backoff pause at once, and starts the count again")
    func retrySoonEndsABackoff() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.fail(with: HostileError())
        try await pacing.waitForSleeps(1)
        #expect(await pacing.sleptSeconds == [2])

        source.retrySoon()
        let sent = await Support.requestsReach(2, on: helper)
        await pacing.release()
        try #require(sent, "retrySoon() did not end the backoff pause")
        #expect(await pacing.cancelledSleeps == 1)

        await helper.fail(with: HostileError())
        try await pacing.waitForSleeps(2)
        #expect(await pacing.sleptSeconds == [2, 2], "the failure count was not started again")

        await pacing.release()
        await Support.tearDown(source, helper)
    }

    /// **Mutation (R3):** in `retrySoon()`, also call `outstanding?.cancel()`. Run: red at
    /// `cancellations == 0`.
    @Test("retrySoon() while a request is in flight sends nothing beside it and cancels nothing")
    func retrySoonNeverDoublesARequest() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = GatedPollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing)

        source.start()
        try await helper.waitForRequests(1)
        await helper.fail(with: HostileError())
        try await pacing.waitForSleeps(1)
        await pacing.release()
        try await helper.waitForRequests(2)  // in flight, after a failure: a backoff is owed

        source.retrySoon()
        _ = await Support.settle(turns: 200) { false }
        #expect(helper.cancellations == 0)
        #expect(await helper.requests == 2)
        #expect(await helper.peakAtHelper == 1)

        await Support.tearDown(source, helper)
    }

    /// **Mutation (O10):** skip the contradiction check in `record(_:sentIn:)`. Run: red here.
    @Test("A snapshot that lists one fan twice is refused, not shown")
    func aRepeatedFanIndexIsNotRendered() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(
            with: Support.snapshot(fans: [Support.fan(0), Support.fan(1), Support.fan(0)]))
        try await helper.waitForRequests(2)

        #expect(
            source.authority()
                == .readDirectly(.snapshotContradicted(detail: "it lists fan 0 twice")))

        await Support.tearDown(source, helper)
    }

    @Test("A snapshot that lists one sensor key twice is refused, and the key is cleaned")
    func aRepeatedSensorKeyIsNotRendered() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)
        let twice = SensorSample(
            key: "T\u{202E}p0", label: nil, labelConfidence: nil, value: 40, unit: .celsius)

        source.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot(sensors: [twice, twice]))
        try await helper.waitForRequests(2)

        #expect(
            source.authority()
                == .readDirectly(.snapshotContradicted(detail: "it lists sensor Tp0 twice")))

        await Support.tearDown(source, helper)
    }
}
