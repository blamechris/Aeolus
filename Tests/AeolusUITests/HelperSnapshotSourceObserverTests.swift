import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing
import os

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `HelperSnapshotSource` reports every read to the lease driver: a ticket taken **before** the
/// request is sent, and each successful reply judged with it (#479's `SnapshotTicket`).
///
/// Every request is parked on `FakeSnapshotHelper` until the test answers it. Every wait is
/// bounded in turns or ends when the test is cancelled, and none awaits a task's value.
@Suite("HelperSnapshotSource — the lease driver's ticket and judgement", .timeLimit(.minutes(1)))
@MainActor
struct HelperSnapshotSourceObserverTests {

    typealias Support = SnapshotTestSupport

    /// Each ticket is taken before its request reaches the helper: ticket `k` sees `k` requests,
    /// the ones before it, and never its own.
    ///
    /// **The test sets the order, not the scheduler.** The recording observer does not take its
    /// ticket at once: it first gives a request already sent up to 200 turns to reach the helper,
    /// and only then records how many have. A correct source has sent nothing yet, so it records
    /// `k`; a source that sent first is caught however its request was scheduled.
    ///
    /// **Mutation (T1):** in `HelperSnapshotSource.run`, move
    /// `let judgement = await observer?.readWillBeSent()` (and the demand check after it) below
    /// `outstanding = request`. Red at `requestsSeenAtTicket`.
    @Test("The ticket is taken before the request is sent")
    func theTicketIsTakenBeforeTheRequest() async throws {
        let helper = FakeSnapshotHelper()
        let recorder = ReadRecorder()
        let source = try await Support.handshakenSource(helper, observer: recorder.observer(helper))

        source.start()
        try await helper.waitForRequests(1)
        #expect(source.hasOutstandingRequest, "the first request is parked at the helper")
        #expect(recorder.judged.isEmpty, "nothing is judged before its reply")

        let first = Support.snapshot(fans: [Support.fan(actual: 2001)])
        await helper.reply(with: first)
        try await helper.waitForRequests(2)

        #expect(recorder.requestsSeenAtTicket == [0, 1], "each ticket preceded its own request")
        #expect(recorder.judged == [first])
        await Support.tearDown(source, helper)
    }

    /// A successful reply is judged, with the ticket taken for it, before the next request goes
    /// out. A failed one is not: there is no snapshot to judge.
    ///
    /// **Mutation (T2):** in `HelperSnapshotSource.run`, delete `await judgement(snapshot)`. Red
    /// at `judged == [answered]`.
    @Test("A successful reply is judged before the next request, and a failed one is not")
    func aReplyIsJudged() async throws {
        let helper = FakeSnapshotHelper()
        let recorder = ReadRecorder()
        let source = try await Support.handshakenSource(helper, observer: recorder.observer(helper))

        source.start()
        try await helper.waitForRequests(1)
        await helper.fail(with: FakeSnapshotHelper.Closed())
        try await helper.waitForRequests(2)
        #expect(recorder.judged.isEmpty, "a failed request has nothing to judge")

        let answered = Support.snapshot(fans: [Support.fan(actual: 3003)])
        await helper.reply(with: answered)
        try await helper.waitForRequests(3)
        #expect(recorder.judged == [answered])
        #expect(recorder.requestsSeenAtTicket == [0, 1, 2])
        await Support.tearDown(source, helper)
    }

    /// The control: a source with no observer, as in a build with no driver, reads as before.
    @Test("A source with no observer still reads, one request at a time")
    func noObserverStillReads() async throws {
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(helper)

        source.start()
        try await helper.waitForRequests(1)
        let first = Support.snapshot()
        await helper.reply(with: first)
        try await helper.waitForRequests(2)

        #expect(Support.freshSnapshot(source) == first)
        #expect(await helper.peakAtHelper == 1)
        await Support.tearDown(source, helper)
    }

    // MARK: - With the real driver

    /// End to end with the real driver: a held lease that the next snapshot does not list ends as
    /// lost, and the snapshot the display shows is the same reply.
    @Test("A held lease the snapshot no longer lists is lost")
    func aSnapshotWithoutTheLeaseEndsIt() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(
            helper, observer: .judging(with: scene.driver))

        source.start()
        try await helper.waitForRequests(1)
        let revoked = Support.snapshot(activeLease: nil)
        await helper.reply(with: revoked)
        try await helper.waitForRequests(2)

        // The judgement is awaited before the next request is sent, so it has happened.
        let loss = try #require(await scene.driver.state.loss, "the lease was judged lost")
        #expect(loss.lease == held.lease)
        #expect(
            loss.cause == .snapshot(.leaseNotListed(listed: nil), isThermalEmergencyActive: false))
        #expect(Support.freshSnapshot(source) == revoked)
        await Support.tearDown(source, helper)
        await scene.finish()
    }

    /// A snapshot asked for before the grant was answered is not judged against the lease, even
    /// when it arrives after: its ticket is from before the grant. The next one, asked for after
    /// the grant, is.
    ///
    /// **Mutation (T3):** in `HelperSnapshotObserver.judging(with:)`, take the ticket inside the
    /// judgement, at the reply, instead of before the read. Red at the first `isHeld`.
    @Test("A snapshot asked for before the grant is not judged against it")
    func aReadFromBeforeTheGrantIsNotJudged() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.acquires.isEmpty }

        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(
            helper, observer: .judging(with: scene.driver))
        source.start()
        try await helper.waitForRequests(1)

        await scene.helper.answerParked(.acquire)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }
        await helper.reply(with: Support.snapshot(activeLease: nil))
        try await helper.waitForRequests(2)
        #expect(await scene.driver.state.isHeld, "a read from before the grant proves nothing")

        await helper.reply(with: Support.snapshot(activeLease: nil))
        try await helper.waitForRequests(3)
        #expect(await scene.driver.state.isLost, "a read from after the grant does")
        await Support.tearDown(source, helper)
        await scene.finish()
    }
}

/// What a recording observer saw: how many requests had reached the helper when each ticket was
/// taken, and every snapshot it was asked to judge.
final class ReadRecorder: Sendable {

    private struct State {
        var requestsSeenAtTicket: [Int] = []
        var judged: [SystemSnapshot] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var requestsSeenAtTicket: [Int] { state.withLock { $0.requestsSeenAtTicket } }
    var judged: [SystemSnapshot] { state.withLock { $0.judged } }

    /// An observer over `helper` that, before it takes ticket `k`, gives a request already sent
    /// up to 200 turns to reach the helper, then records how many have. A correct source has sent
    /// `k` by then, so the turns are spent only by a correct source and the record is exact for an
    /// incorrect one.
    func observer(_ helper: FakeSnapshotHelper) -> HelperSnapshotObserver {
        HelperSnapshotObserver { [self] in
            let ticket = state.withLock { $0.requestsSeenAtTicket.count }
            for _ in 0..<200 {
                if await helper.requests > ticket { break }
                await Task.yield()
            }
            let seen = await helper.requests
            state.withLock { $0.requestsSeenAtTicket.append(seen) }
            return { [self] snapshot in state.withLock { $0.judged.append(snapshot) } }
        }
    }
}

extension SnapshotTestSupport {

    /// A source on a helper that reports `.handshaken`, reporting every read to `observer`.
    @MainActor
    static func handshakenSource(
        _ helper: FakeSnapshotHelper, observer: HelperSnapshotObserver
    ) async throws -> HelperSnapshotSource {
        helper.report(.handshaken)
        let source = HelperSnapshotSource(
            reader: helper, refreshInterval: { 1 }, clock: SnapshotTestClock(),
            pacing: FakePollingClock(), observer: observer)
        try #require(await settle { source.health == .handshaken })
        return source
    }
}
