import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// ADR 0015 D2 end to end: the source keeps each read's ticket beside its reply, the view model
/// keeps it beside the snapshot on screen, and the root reads soon after the driver stops acting,
/// so the user's own Auto reads selected within about one round trip, and never from a snapshot
/// read before it.
///
/// Every request is parked on `FakeSnapshotHelper` until the test answers it, and every wait is
/// bounded in turns or ends when the test is cancelled.
@Suite(
    "Automatic after the driver stops acting, from the read to the control", .timeLimit(.minutes(1))
)
@MainActor
struct AutomaticAfterAReadTests {

    typealias Support = SnapshotTestSupport
    typealias Fixtures = FanControlFixtures
    typealias Fans = AllFansFixtures

    /// No lease listed, both fans offered and on automatic: what a snapshot read before the grant
    /// shows, and what one read after the release shows too.
    static let cleared = Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)])

    /// The ticket beside the snapshot `source` licenses now, or `nil` when it licenses none or the
    /// snapshot carries none.
    static func ticket(_ source: HelperSnapshotSource) -> LeaseDriver.SnapshotTicket? {
        guard case .fresh(_, _, let ticket) = source.authority() else { return nil }
        return ticket
    }

    // MARK: - The source

    /// A read sent while the lease was held, and answered after the driver stopped acting, keeps
    /// the ticket taken before it was sent: it can have been served before the release, so it is
    /// not evidence. The next read, sent after, is.
    ///
    /// **Mutation (F4, "the ticket at arrival"):** in `HelperSnapshotSource.run`, move
    /// `let read = await observer?.readWillBeSent()` and the demand check after it below
    /// `outstanding = nil`, so the ticket is taken when the reply has arrived. Run: red at
    /// `!admits(parked)`.
    @Test("A read parked across the driver's stop keeps the ticket taken before it was sent")
    func aParkedReadKeepsItsEarlierTicket() async throws {
        let scene = await LeaseScene()
        try await scene.take(LeaseScene.target([0: 3000, 1: 3000]))
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(
            helper, observer: .judging(with: scene.driver))
        source.start()
        try await helper.waitForRequests(1)

        let mark = await scene.mark()
        await scene.driver.selectAutomatic()
        await scene.waitForState(since: mark) { $0.isReleased }
        let evidence = await scene.driver.report.automaticEvidence
        await helper.reply(with: Self.cleared)
        try await helper.waitForRequests(2)
        let parked = try #require(Self.ticket(source), "the reply carries the ticket of its read")
        #expect(!evidence.admits(parked), "a read sent while the lease was held is evidence")

        await helper.reply(with: Self.cleared)
        try await helper.waitForRequests(3)
        let next = try #require(Self.ticket(source))
        #expect(evidence.admits(next), "the read sent after the driver stopped is not")
        await Support.tearDown(source, helper)
        await scene.finish()
    }

    // MARK: - The root, the view model and the control

    /// The user's own Auto, through the root, at a 60 s refresh interval:
    ///
    /// 1. Before the grant, a read shows no lease and the fans cleared, and `.idle` reads it as
    ///    Automatic.
    /// 2. The lease is taken, and the root asks for a read at the grant (`LeaseStateModel`, "The
    ///    reads it asks for"), which stays unanswered. Auto releases the lease. The snapshot on
    ///    screen is still that first one: no lease, the fans cleared, and only its ticket says it
    ///    is from before. Nothing is selected.
    /// 3. The grant's read, sent before the Auto, is answered with the same: it is not evidence
    ///    either. The root asked for a read at the stop while that one was in flight, so the next
    ///    is sent at once, not in 60 s. Its reply shows the same, and the control reads Automatic.
    /// 4. The connection goes, and the snapshot and its ticket go with it.
    ///
    /// **Mutation (F9):** red at step 3's Automatic. **Mutation (F10, "no nudge"):** in
    /// `AppComposition.init`, pass `askForARead: {}`. Run: red at step 2's grant read.
    /// **Mutation (F5a, "a stale ticket"):** in `PollingViewModel.render`, keep the ticket already
    /// on screen, `rendered?.ticket ?? ticket`. Run: red at step 3's ticket and Automatic.
    /// **Mutation (F5b, "a withdrawal keeps it"):** in `withdrawControlClaims`, keep `rendered`
    /// set (the ticket cannot be kept apart from it). Run: red at step 4's
    /// `renderedReadTicket == nil`. **Mutation (F6):** red at step 2.
    @Test("The user's Auto reads Automatic after one more read, and never from the read before")
    func theUsersAutoReadsAutomaticFromTheNextRead() async throws {
        let (scene, polling) = try await Self.rootAt60Seconds()
        let source = scene.root.snapshots
        let control = {
            AllFansControlPresentation(polling: polling, driver: scene.root.leaseState.current)
        }

        // 1. Before the grant.
        await scene.reader.reply(with: Self.cleared)
        try #require(await Support.settle { Self.ticket(source) != nil })
        await Support.tickEnds(polling)
        let first = try #require(polling.renderedReadTicket, "the read's ticket is on screen")
        #expect(control().selection == .automatic)

        // 2. The lease, its grant's read sent and left unanswered, then Auto.
        try await scene.lease.take(LeaseScene.target([0: 3000, 1: 3000]))
        let grantRead = await Support.requestsReach(2, on: scene.reader)
        try #require(grantRead, "the root asked for a read at the grant")
        let mark = await scene.lease.mark()
        scene.root.selectAutomatic()
        await scene.lease.waitForState(since: mark) { $0.isReleased }
        try #require(
            await Support.settle { scene.root.leaseState.current.automaticEvidence != .anyRead },
            "the root published the floor")
        await Support.tickEnds(polling)
        #expect(polling.renderedReadTicket == first, "still the snapshot from before")
        #expect(control().selection == .none, "a read from before the grant is not evidence")

        // 3. The grant's read, ticketed before the Auto, then the read the root asked for after.
        await scene.reader.reply(with: Self.cleared)
        try #require(await Support.settle { Self.ticket(source).map { $0 != first } ?? false })
        await Support.tickEnds(polling)
        let grantsTicket = polling.renderedReadTicket
        #expect(control().selection == .none, "a read sent before the Auto is not evidence")
        let sent = await Support.requestsReach(3, on: scene.reader)
        try #require(sent, "the root waited out the 60 s pause after Auto")
        await scene.reader.reply(with: Self.cleared)
        try #require(
            await Support.settle { Self.ticket(source).map { $0 != grantsTicket } ?? false })
        await Support.tickEnds(polling)
        let evidence = scene.root.leaseState.current.automaticEvidence
        #expect(evidence.admits(polling.renderedReadTicket), "the new read's ticket is on screen")
        #expect(control().selection == .automatic)
        #expect(control().statusLines.map(\.value.text) == ["Aeolus is renewing no lease."])

        // 4. The connection goes.
        try await Support.report(.unresponsive, to: source, from: scene.reader)
        await Support.tickEnds(polling)
        #expect(polling.renderedSnapshot == nil)
        #expect(polling.renderedReadTicket == nil, "the withdrawal left the ticket on screen")
        #expect(control().selection == .none)

        source.stop()
        await scene.finish()
    }

    /// Auto during an `apply`, through the root, at a 60 s refresh interval. The driver is
    /// `released` with the `apply` still at the helper, so no read is evidence and none is asked
    /// for. When the `apply` answers, the floor is published as a second report with the state
    /// unchanged, the root asks for a read at once, and its reply reads Automatic.
    ///
    /// **Mutation (M-G):** red at `!early`. **Mutation (M-B):** red at the floor's requirement,
    /// the evidence-only report dropped. **Mutation (M-C, a read asked at any change of state):**
    /// red at `!early`, the stop asking for one, and at the new read's ticket. **Mutation (MC2, a
    /// read asked only at a change of state carrying a floor):** red at `sent`, no read asked when
    /// only the evidence moved. **Mutation (S2m):** red at `.noRead`.
    @Test("Auto during an apply reads Automatic once the apply has answered and a read follows")
    func autoDuringAnApplyReadsAutomaticAfterItAnswers() async throws {
        let (scene, polling) = try await Self.rootAt60Seconds()
        let source = scene.root.snapshots
        let control = {
            AllFansControlPresentation(polling: polling, driver: scene.root.leaseState.current)
        }
        await scene.reader.reply(with: Self.cleared)
        try #require(await Support.settle { Self.ticket(source) != nil })
        await scene.lease.helper.script(.apply, .parked)
        await scene.lease.driver.take(try LeaseScene.target([0: 3000, 1: 3000]))
        await scene.lease.ledger.waitFor { !$0.applies.isEmpty }
        let lease = try #require(await scene.lease.helper.heldLeases.values.first)
        try await Self.answerTheGrantsRead(
            scene, asRequest: 2,
            with: Support.snapshot(fans: [Fans.offered(0), Fans.offered(1)], activeLease: lease))

        let mark = await scene.lease.mark()
        try await scene.click { scene.root.selectAutomatic() }
        await scene.lease.waitForState(since: mark) { $0.isReleased }
        try #require(await Support.settle { scene.root.leaseState.current.state == .released })
        #expect(scene.root.leaseState.current.automaticEvidence == .noRead)
        let early = await Support.eventually(turns: 2_000) { await scene.reader.requests >= 3 }
        #expect(!early, "a read was asked for while no read could be evidence")
        await Support.tickEnds(polling)
        #expect(control().selection == .none)
        #expect(
            control().statusLines.map(\.value) == [
                Self.released, FanControlAwaitingApplyTests.awaiting,
            ],
            "the control says why Auto is not shown (#505)")

        await scene.lease.helper.answerParked(.apply)
        try #require(
            await Support.settle { scene.root.leaseState.current.automaticEvidence.isFloor },
            "the root published the floor the apply's answer minted")
        let sent = await Support.requestsReach(3, on: scene.reader)
        try #require(sent, "the root waited out the 60 s pause after the apply answered")
        await scene.reader.reply(with: Self.cleared)
        let evidence = scene.root.leaseState.current.automaticEvidence
        try #require(await Support.settle { evidence.admits(Self.ticket(source)) })
        await Support.tickEnds(polling)
        #expect(control().selection == .automatic)
        #expect(scene.root.leaseState.current.state == .released, "the state did not move")
        #expect(control().statusLines.map(\.value) == [Self.released], "the wait is over (#505)")

        source.stop()
        await scene.finish()
    }

    /// What `.released` says beneath the control.
    private static let released = FanControlPresentation.StatusLine(
        text: "Aeolus is renewing no lease.",
        detail: "Each fan's row shows what the helper reports.")

    /// A reply the authority watch renders, rather than a tick, carries its read's ticket too.
    ///
    /// **Mutation (O19b):** in `PollingViewModel.reassessAuthority()`, build the snapshot to render
    /// with `ticket: nil`. Run: red at `renderedReadTicket != nil`.
    @Test("A reply the authority watch renders keeps the ticket of its read")
    func theWatchRenderKeepsTheTicket() async throws {
        let scene = await LeaseScene()
        let helper = FakeSnapshotHelper()
        let source = try await Support.handshakenSource(
            helper, observer: .judging(with: scene.driver))
        let ticks = GatedPollingClock()
        let watch = GatedPollingClock()
        let viewModel = PollingViewModel(
            provider: Support.directProvider(), clock: ticks, refreshInterval: 60,
            snapshots: source, authorityWatchClock: watch)
        viewModel.start()
        try await helper.waitForRequests(1)
        await helper.reply(with: Self.cleared)
        try #require(await Support.settle { Self.ticket(source) != nil })
        await PollingViewModelWatchRenderTests.step(watch)

        try #require(viewModel.renderedSnapshot == Self.cleared, "the watch rendered the reply")
        #expect(viewModel.renderedReadTicket != nil, "and dropped the ticket of its read")
        #expect(viewModel.renderedReadTicket == Self.ticket(source))
        viewModel.stop()
        await ticks.release()
        await watch.release()
        await Support.tearDown(source, helper)
        await scene.finish()
    }

    /// The read the root asks for when a lease is granted (`LeaseStateModel`, "The reads it asks
    /// for"): waits for it to be sent, as the reader's request `number`, and answers it with
    /// `snapshot`, which must list the granted lease, or the driver judges the lease lost from it.
    static func answerTheGrantsRead(
        _ scene: CompositionScene, asRequest number: Int, with snapshot: SystemSnapshot
    ) async throws {
        let sent = await Support.requestsReach(number, on: scene.reader)
        try #require(sent, "the root asked for a read at the grant")
        await scene.reader.reply(with: snapshot)
        let source = scene.root.snapshots
        try #require(
            await Support.settle {
                if case .fresh(let shown, _, _) = source.authority() {
                    shown == snapshot
                } else {
                    false
                }
            }, "the source holds the grant's read")
    }

    /// A root whose source reads at a 60 s interval on the real pacing clock, handshaken, with its
    /// first request parked, and a window's view model over it that the test ticks by hand.
    static func rootAt60Seconds() async throws -> (CompositionScene, PollingViewModel) {
        let scene = await CompositionScene()
        scene.root.preferencesController.setRefreshInterval(60)
        scene.reader.report(.handshaken)
        let source = scene.root.snapshots
        try #require(await Support.settle { source.health == .handshaken })
        let polling = PollingViewModel(
            provider: Support.directProvider(), clock: FakePollingClock(), snapshots: source)
        source.start()
        try await scene.reader.waitForRequests(1)
        return (scene, polling)
    }

    /// The ticket on screen is the view model's own, read-only: a dynamic cast cannot make its key
    /// path writable (SR-5218), as `renderedSnapshot`'s cannot.
    ///
    /// **Mutation (KP2):** give `renderedReadTicket` a `private(set)` setter. Run: red at the first
    /// expectation.
    @Test("The ticket on screen cannot be written through a key path")
    func theTicketOnScreenIsReadOnly() {
        let path: AnyKeyPath = \PollingViewModel.renderedReadTicket

        #expect(!(path is ReferenceWritableKeyPath<PollingViewModel, LeaseDriver.SnapshotTicket?>))
        #expect(path is KeyPath<PollingViewModel, LeaseDriver.SnapshotTicket?>)
    }
}
