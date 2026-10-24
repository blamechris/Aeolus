import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusUI

/// `HelperSnapshotSource`: one request in flight, never cancelled; freshness measured from
/// arrival on its own clock; health that licenses rendering only while `.handshaken`; and no
/// client at all in a build with no helper (#156, ADR 0006, #419).
///
/// Every request is parked on `FakeSnapshotHelper` until the test answers it, so "one in
/// flight" is a count the fake keeps — `peakAtHelper` — and not something an actor hands out
/// for free. `.timeLimit` is a hang guard only: nothing here waits on a real clock, and a test
/// that reaches the limit has deadlocked.
@Suite("HelperSnapshotSource — one request at a time, fresh from arrival", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceTests {

    typealias Support = SnapshotTestSupport

    // MARK: - One in flight, never cancelled (#419)

    /// **Mutation:** in `HelperSnapshotSource.stop()`, add `outstanding?.cancel()` after
    /// `pause?.cancel()`. Run: red at the `cancellations == 0` expectation straight after
    /// `stop()`, and at `peakAtHelper == 1`, because the loop then sends a second request while
    /// the first is still at the helper.
    @Test("stop() leaves the request in flight alone, and a restart sends nothing until it ends")
    func stopDoesNotCancelAndRestartWaits() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)

        source.stop()
        #expect(helper.cancellations == 0, "stop() cancelled the request in flight")
        #expect(source.hasOutstandingRequest)

        source.start()
        // Let anything a second loop would do happen before the first reply is given.
        _ = await Support.settle(turns: 200) { false }
        #expect(await helper.requests == 1, "a restart sent a request beside the outstanding one")

        let first = Support.snapshot(fans: [Support.fan(actual: 2001)])
        await helper.reply(with: first)
        await helper.waitForRequests(2)

        #expect(await helper.peakAtHelper == 1)
        #expect(helper.cancellations == 0)
        #expect(Support.freshSnapshot(source) == first)

        await Support.tearDown(source, helper)
    }

    @Test("A reply that arrives after the last consumer stops is kept, and nothing more is sent")
    func aReplyAfterStopIsKept() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)
        source.stop()

        let late = Support.snapshot(fans: [Support.fan(actual: 3003)])
        await helper.reply(with: late)
        await source.waitUntilIdle()

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
        await helper.waitForRequests(1)

        source.stop()  // the window closes
        await helper.reply(with: Support.snapshot())
        await helper.waitForRequests(2)  // the menu bar's snapshots carry on

        source.stop()  // the menu bar goes too
        await helper.reply(with: Support.snapshot())
        await source.waitUntilIdle()
        #expect(await helper.requests == 2)
        #expect(await helper.peakAtHelper == 1)
    }

    // MARK: - Fresh, measured from arrival

    /// **Mutation:** delete the `freshnessBound` guard in `authority()`. Run: red at the
    /// `.snapshotStale` expectation.
    @Test("A snapshot is fresh until refreshInterval + gatedVerb after it arrived, then stale")
    func freshUntilTheBoundThenStale() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock, refreshInterval: 1)
        #expect(source.freshnessBound == .seconds(1) + HelperClientDeadlines.gatedVerb)

        source.start()
        await helper.waitForRequests(1)
        let reply = Support.snapshot()
        await helper.reply(with: reply)
        await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound - .milliseconds(1))
        #expect(Support.freshSnapshot(source) == reply)

        clock.advance(by: .milliseconds(1))
        #expect(Support.notTracked(source) == .snapshotStale)

        await Support.tearDown(source, helper)
    }

    /// The stamp is taken when the reply arrives, not when the request was sent. The clock moves
    /// four seconds while the request is parked, which is what makes the placement visible: a
    /// frozen clock reads the same at both instants.
    ///
    /// **Mutation:** in `run(_:)`, capture `let sentAt = now()` before the request is created
    /// and record it in place of the `now()` in `record(_:)`. Run: red at the `freshSnapshot`
    /// expectation.
    @Test("Age is counted from the reply's arrival, not from the request's send")
    func ageIsCountedFromArrival() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock)

        source.start()
        await helper.waitForRequests(1)
        clock.advance(by: .seconds(4))
        let reply = Support.snapshot()
        await helper.reply(with: reply)
        await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound - .milliseconds(1))
        #expect(Support.freshSnapshot(source) == reply)

        await Support.tearDown(source, helper)
    }

    /// `capturedAt` is the helper's wall clock. Here it says the snapshot is fifty-six years
    /// old, and the reply arrived just now.
    ///
    /// **Mutation:** in `authority()`, judge `Date().timeIntervalSince(snapshot.capturedAt)`
    /// against the bound instead of the arrival instant. Run: red here.
    @Test("A capturedAt far in the past does not make a snapshot that just arrived stale")
    func aPastCapturedAtIsNotTheAge() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)
        let reply = Support.snapshot(capturedAt: Date(timeIntervalSince1970: 0))
        await helper.reply(with: reply)
        await helper.waitForRequests(2)

        #expect(Support.freshSnapshot(source) == reply)

        await Support.tearDown(source, helper)
    }

    /// The other direction: a helper clock that has jumped ahead must not keep a snapshot fresh.
    ///
    /// **Mutation:** the same as `aPastCapturedAtIsNotTheAge`'s. Run: red here.
    @Test("A capturedAt in the future does not keep an old snapshot fresh")
    func aFutureCapturedAtIsNotTheAge() async throws {
        let helper = FakeSnapshotHelper()
        let clock = SnapshotTestClock()
        let source = try await Support.handshakenSource(helper, clock: clock)

        source.start()
        await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot(capturedAt: .distantFuture))
        await helper.waitForRequests(2)

        clock.advance(by: source.freshnessBound)
        #expect(Support.notTracked(source) == .snapshotStale)

        await Support.tearDown(source, helper)
    }

    // MARK: - Health

    /// **Mutation:** delete the `health == .handshaken` guard in `authority()` — keep rendering
    /// the last snapshot. Run: red for every argument.
    @Test(
        "A connection that leaves .handshaken withdraws the snapshot",
        arguments: [
            HelperConnectionHealth.idle, .unresponsive, .interrupted, .invalidated, .refused,
            .versionMismatched,
        ])
    func leavingHandshakenWithdrawsTheSnapshot(_ health: HelperConnectionHealth) async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        await helper.waitForRequests(2)
        #expect(Support.freshSnapshot(source) != nil)

        helper.report(health)
        try #require(await Support.settle { source.health == health })
        #expect(Support.notTracked(source) == .helperConnection(health))

        await Support.tearDown(source, helper)
    }

    @Test("Before the helper's health has been heard, a reply licenses nothing")
    func aReplyBeforeHandshakenLicensesNothing() async {
        let helper = FakeSnapshotHelper()
        let source = Support.source(helper)

        source.start()
        await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        await helper.waitForRequests(2)

        #expect(Support.notTracked(source) == .helperConnection(.idle))

        await Support.tearDown(source, helper)
    }

    // MARK: - Failures

    struct HostileError: Error, LocalizedError {
        var errorDescription: String? { "refused\u{202E}evil\nforged line" }
    }

    @Test("A failed request licenses nothing, and its description is cleaned")
    func aFailedRequestLicensesNothing() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)
        await helper.reply(with: Support.snapshot())
        await helper.waitForRequests(2)
        await helper.fail(with: HostileError())
        await helper.waitForRequests(3)

        #expect(
            Support.notTracked(source) == .snapshotRequestFailed(detail: "refusedevilforged line"))

        await Support.tearDown(source, helper)
    }

    /// **Mutation:** in `nextPause()`, change `guard consecutiveFailures > 0` to `guard
    /// consecutiveFailures > 1_000_000`, so every pause is `refreshInterval`. Run: red at the
    /// `sleptSeconds` expectation.
    @Test("Failures double the pause up to the ceiling, and a reply resets it")
    func failuresBackOffAndAReplyResets() async throws {
        let helper = FakeSnapshotHelper()
        let pacing = FakePollingClock()
        let source = try await Support.handshakenSource(helper, pacing: pacing, refreshInterval: 1)

        source.start()
        for request in 1...6 {
            await helper.waitForRequests(request)
            await helper.fail(with: HostileError())
        }
        await helper.waitForRequests(7)
        await helper.reply(with: Support.snapshot())
        await helper.waitForRequests(8)

        #expect(await pacing.sleptSeconds == [2, 4, 8, 16, 30, 30, 1])

        await Support.tearDown(source, helper)
    }

    @Test("A snapshot that lists one fan twice is not rendered")
    func aRepeatedFanIndexIsNotRendered() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        await helper.waitForRequests(1)
        await helper.reply(
            with: Support.snapshot(fans: [Support.fan(0), Support.fan(1), Support.fan(0)]))
        await helper.waitForRequests(2)

        #expect(
            Support.notTracked(source)
                == .snapshotRequestFailed(detail: "the helper's snapshot lists fan 0 twice"))

        await Support.tearDown(source, helper)
    }

    // MARK: - No helper in the build

    /// **Mutation:** in `HelperSnapshotSource.forBundle`, build the reader for `.absent` too —
    /// `case .absent: return HelperSnapshotSource(reader: makeReader(), refreshInterval:
    /// refreshInterval)`. Run: red at `built == 0` and at the `.noHelperInThisBuild`
    /// expectation.
    @Test("The Monitor build constructs no helper client at all")
    func theMonitorBuildConstructsNoClient() {
        var built = 0
        let source = HelperSnapshotSource.forBundle(.absent, refreshInterval: 1) {
            built += 1
            return FakeSnapshotHelper()
        }
        source.start()
        source.stop()

        #expect(built == 0)
        #expect(Support.notTracked(source) == .noHelperInThisBuild)
    }

    @Test(
        "A damaged bundle constructs no helper client either",
        arguments: [HelperEmbeddingDefect.missingExecutable, .missingDaemonPlist])
    func aDamagedBundleConstructsNoClient(_ defect: HelperEmbeddingDefect) {
        var built = 0
        let source = HelperSnapshotSource.forBundle(.incomplete(defect), refreshInterval: 1) {
            built += 1
            return FakeSnapshotHelper()
        }

        #expect(built == 0)
        #expect(Support.notTracked(source) == .helperInstallIncomplete)
    }

    /// The control: the factory is reachable, so `built == 0` above is a finding and not a
    /// closure nothing could call.
    @Test("A bundle that ships a helper constructs exactly one client")
    func anEmbeddedHelperConstructsOneClient() {
        var built = 0
        let source = HelperSnapshotSource.forBundle(.embedded, refreshInterval: 1) {
            built += 1
            return FakeSnapshotHelper()
        }

        #expect(built == 1)
        #expect(Support.notTracked(source) == .helperConnection(.idle))
    }
}
