import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// ADR 0015 D2's driver half: every state in which the driver has stopped acting sets a
/// read-timing floor in `transition(to:)`, published with the state as one `LeaseDriverReport`,
/// and an `apply` still unanswered holds the floor back until it answers (#498's S2).
///
/// Each path ends with a ticket taken **immediately before** the event that moves the driver into
/// the state, and every assertion is on the report the driver **published** with that state, read
/// from the ledger, never on `driver.report` afterwards, which a mutant that publishes first would
/// still get right.
@Suite(
    "LeaseDriver — the floor for Automatic, set where the driver stops acting",
    .timeLimit(.minutes(1)))
struct LeaseDriverFloorTests {

    typealias Ticket = LeaseDriver.SnapshotTicket

    /// The first report published after `mark` whose state ends `path`.
    static func published(
        _ scene: LeaseScene, since mark: Int, ending path: FloorPath
    ) async -> LeaseDriverReport? {
        await scene.firstReport(since: mark) { path.ends(in: $0) }
    }

    /// **Mutation (F1, "no floor"):** in `LeaseDriver.transition(to:)`, delete the assignment to
    /// `evidence`. Run: red at `!admits(before)` for every path, the evidence still `.anyRead`.
    /// **Mutation (F2, "the floor at the start of a release"):** mint it in `beginRelease` and in
    /// `releaseOnArrival` instead. Run: red at `!admits(before)` for every path whose ticket is
    /// taken while releasing.
    /// **Mutation (F3, "published before the floor"):** in `transition(to:)`, publish the report
    /// before setting `evidence`. Run: red at `!admits(before)` for every path, from the report
    /// the driver published, though `driver.report` is right by then.
    @Test(
        "Every path into a state that stops acting publishes a floor past a read before it",
        arguments: FloorPath.allCases)
    func everyPathSetsAFloor(_ path: FloorPath) async throws {
        let scene = await LeaseScene()
        let mark = await scene.mark()
        let before = try await path.drive(scene)
        let report = try #require(await Self.published(scene, since: mark, ending: path))
        let after = await scene.driver.beginSnapshotRead()

        #expect(
            !report.automaticEvidence.admits(before),
            "\(path): a read ticketed before the driver stopped is evidence: \(report)")
        #expect(
            report.automaticEvidence.admits(after),
            "\(path): a read ticketed after it is not: \(report)")
        await scene.finish()
    }

    /// The control: a driver that has done nothing reports `.idle` with every read admitted, and
    /// a read with no ticket is admitted only there.
    @Test("An idle driver reports any read, and only it admits a read with no ticket")
    func idleAdmitsAnyRead() async throws {
        let scene = await LeaseScene()
        #expect(await scene.driver.report == .idle)
        #expect(await scene.entries.reports == [.idle], "the stream starts with the value now")
        #expect(LeaseDriverReport.idle.automaticEvidence.admits(nil))
        let floor = try await SnapshotTickets.aroundAFloor()
        #expect(!floor.evidence.admits(nil), "a read with no ticket passes no floor")
        #expect(!LeaseDriverReport.AutomaticEvidence.noRead.admits(floor.after))
        await scene.finish()
    }

    /// #498's S2. Auto during the first `apply` releases at once, and the `apply` is left to
    /// answer: the driver is `released` with it still at the helper. No read is evidence until it
    /// answers. Then the floor is minted and published as a new report with the state unchanged,
    /// and a read ticketed between the release and that answer is still not evidence.
    ///
    /// **Mutation (S2m, "the floor ignores an apply in flight"):** in `transition(to:)`, set
    /// `.readFrom(mintFloor())` whatever `appliesUnanswered` is. Run: red at `.noRead`, and at
    /// `!admits(during)`.
    /// **Mutation (S2n, "the answer mints nothing"):** delete the body of `applyAnswered()` after
    /// the decrement. Run: red at the floor's `#require`, once `LeaseScene.firstFloor(since:)`'s
    /// patience is spent with no floor published.
    @Test("Auto during an apply sets no floor until the apply has answered")
    func anApplyInFlightHoldsTheFloorBack() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }

        let mark = await scene.mark()
        await scene.driver.selectAutomatic()
        let released = try #require(await scene.firstReport(since: mark) { $0.isReleased })
        // The state too, so that it is in the ledger before `answered` below: the check that no
        // state is published again counts states after that mark.
        await scene.waitForState(since: mark) { $0.isReleased }
        #expect(released.automaticEvidence == .noRead, "\(released)")
        let during = await scene.driver.beginSnapshotRead()

        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        let published = await scene.firstFloor(since: answered)
        let now = await scene.driver.report
        let floor = try #require(
            published,
            "the apply answered, and no report with a floor was published; the driver's now: \(now)"
        )
        let after = await scene.driver.beginSnapshotRead()

        #expect(floor.state == .released, "the state did not move")
        #expect(!floor.automaticEvidence.admits(during), "a read before the apply answered")
        #expect(floor.automaticEvidence.admits(after))
        let current = await scene.driver.report
        #expect(current == floor, "the driver's report is the one it published: \(current)")
        #expect(
            Array(await scene.entries.dropFirst(answered)).states.isEmpty,
            "the evidence moved alone: no state was published again")
        await scene.finish()
    }

    /// A loss during the first `apply` holds the floor back the same way: the helper may still
    /// finish the `apply` (#497's review, C1).
    @Test("A loss during an apply sets no floor until the apply has answered")
    func aLossDuringAnApplyHoldsTheFloorBack() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.apply, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { !$0.applies.isEmpty }

        let mark = await scene.mark()
        await scene.helper.pushHealth(.unresponsive)
        let lost = try #require(await scene.firstReport(since: mark) { $0.isLost })
        #expect(lost.automaticEvidence == .noRead, "\(lost)")

        let answered = await scene.mark()
        await scene.helper.answerParked(.apply)
        let published = await scene.firstFloor(since: answered)
        let now = await scene.driver.report
        try #require(
            published != nil,
            "the apply answered, and no report with a floor was published; the driver's now: \(now)"
        )
        #expect(await scene.driver.report.state.isLost)
        await scene.finish()
    }

    /// A floor never makes a snapshot evidence against the next lease: a read ticketed after the
    /// floor and before the next grant is not judged against that grant. Minting at every stop
    /// leaves `observe`'s judging as it was (see "When a snapshot may show the fans automatic").
    @Test("A read between a floor and the next grant is not judged against the grant")
    func theFloorLeavesObserveAlone() async throws {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .refuse(.leaseUnknown))
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.waitForState { if case .refused = $0 { true } else { false } }
        await scene.helper.script(.acquire, .parked)
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.ledger.waitFor { $0.acquires.count == 2 }

        let betweenTheFloorAndTheGrant = await scene.driver.beginSnapshotRead()
        await scene.helper.answerParked(.acquire)
        await scene.waitForState {
            if case .held(let held) = $0 { held.isConfirmed } else { false }
        }
        await scene.driver.observe(
            SnapshotTestSupport.snapshot(activeLease: nil), readWith: betweenTheFloorAndTheGrant)

        #expect(await scene.driver.state.isHeld, "a read from before the grant proves nothing")
        await scene.finish()
    }

    /// A heartbeat whose wait fails ends the lease as `lost(.heartbeatFailed)`, through the same
    /// `lose(_:_:)` as every other loss of a held lease, and it sets a floor too. The wait fails as
    /// the grant arrives. Whether the first `apply` has answered by then is not ordered here: the
    /// floor is set at the loss or when that `apply` answers, and the test waits for it either way.
    @Test("A failed heartbeat sets a floor once the apply has answered")
    func aFailedHeartbeatSetsAFloor() async throws {
        let clock = HandWoundClock()
        let ledger = LeaseLedger()
        let helper = FakeLeaseHelper(clock: clock, ledger: ledger)
        let driver = LeaseDriver(
            control: helper, holderDescription: LeaseScene.holder, clock: FailingHeartbeatClock())
        let before = await driver.beginSnapshotRead()

        await driver.take(try LeaseScene.target([0: 3000]))

        // Bounded in turns, so a floor that never comes is a red and not a hung run.
        var ended = false
        for _ in 0..<10_000 {
            if await driver.report.automaticEvidence.isFloor {
                ended = true
                break
            }
            await Task.yield()
        }
        let report = await driver.report
        try #require(ended, "no floor: \(report)")
        #expect(report.state.loss?.cause == .heartbeatFailed, "\(report)")
        #expect(!report.automaticEvidence.admits(before))
        #expect(report.automaticEvidence.admits(await driver.beginSnapshotRead()))
        await helper.disconnect()
    }
}

/// A heartbeat clock whose every wait fails with something other than a cancellation.
struct FailingHeartbeatClock: HeartbeatClock {
    struct Failed: Error {}

    var now: ContinuousClock.Instant { ContinuousClock.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        throw Failed()
    }
}
