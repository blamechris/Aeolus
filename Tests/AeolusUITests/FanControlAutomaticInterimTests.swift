import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// ADR 0015 D3, the fail-closed interim until #498: Automatic only while the driver is `.idle`,
/// with no lease listed and the fan cleared; never after the app has acted.
///
/// The driver scenarios are #497's delta-review probes, kept as regressions. Each reaches a state
/// in which the driver holds nothing, by a path on which no release answer is kept, and each must
/// end with nothing selected over a snapshot that shows no lease and every fan cleared: the kind
/// of snapshot that can predate the grant.
@Suite(
    "FanControlPresentation — Automatic only before the app has acted (ADR 0015 D3)",
    .timeLimit(.minutes(1)))
struct FanControlAutomaticInterimTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport

    /// No lease listed, both fans cleared: what a snapshot read before any grant shows, and what
    /// one read after a handback shows too.
    static let cleared = Support.snapshot(fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)])

    /// The control and fan 0's presentation, over `snapshot`, beside `driver`.
    static func claims(
        _ driver: LeaseDriverState, over snapshot: SystemSnapshot = cleared
    ) throws -> (fan: FanControlPresentation.Selection, all: AllFansControlPresentation.Selection) {
        let screen = Fixtures.screen(snapshot, driver: driver)
        let fans = AllFansControlPresentationTests.fans(screen)
        return (
            try Fixtures.present(0, on: screen).selection,
            AllFansControlPresentation(fans: fans, snapshot: snapshot).selection
        )
    }

    // MARK: - I1 to I4

    /// **Mutation (I4, the positive control):** make `automaticBeforeAnyLease` always answer
    /// `.unknown`. Run: red here, so the tests below can see the predicate say yes.
    @Test("Idle, no lease listed, every fan cleared: Automatic")
    func idleBeforeAnyLeaseIsAutomatic() throws {
        #expect(Self.cleared.fans.allSatisfy { $0.isClearedToAutomatic })
        let claims = try Self.claims(.idle)

        #expect(claims.fan == .automatic)
        #expect(claims.all == .automatic)
    }

    /// **Mutation (I1):** in `claim`, return `automaticBeforeAnyLease(licence)` for `.released`.
    /// Run: red here.
    @Test("Released, over a snapshot with no lease and every fan cleared: nothing selected")
    func releasedIsNeverAutomatic() throws {
        let claims = try Self.claims(.released)

        #expect(claims.fan == .unknown)
        #expect(claims.all == .none)
    }

    /// **Mutation (I2):** in `claim`, return `automaticBeforeAnyLease(licence)` for `.refused`.
    /// Run: red here, for every fault.
    @Test(
        "Refused, over a snapshot with no lease and every fan cleared: nothing selected",
        arguments: Fixtures.FaultTag.allCases)
    func refusedIsNeverAutomatic(_ tag: Fixtures.FaultTag) throws {
        let claims = try Self.claims(.refused(tag.fault(carrying: "detail")))

        #expect(claims.fan == .unknown)
        #expect(claims.all == .none)
    }

    /// Fans cleared, and a lease listed: the app's own, and another client's. Before any grant
    /// lands its `apply`, a fan under a live lease reads available and automatic, because the
    /// helper cannot state `.leaseHeldByAnotherClient` per fan.
    ///
    /// **Mutation (I3):** delete the `activeLease == nil` condition from `automaticBeforeAnyLease`.
    /// Run: red here, for both leases.
    @Test(
        "Idle beside a listed lease, with every fan cleared: nothing selected",
        arguments: [Fixtures.ours, Fixtures.theirs])
    func idleBesideAListedLeaseIsNotAutomatic(_ lease: Lease) throws {
        let listed = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)], activeLease: lease)
        #expect(
            listed.fans.allSatisfy { $0.isClearedToAutomatic },
            "the fans are cleared, so only the listed lease can refuse Automatic")
        let claims = try Self.claims(.idle, over: listed)

        #expect(claims.fan == .unknown)
        #expect(claims.all == .none)
    }

    // MARK: - The delta review's probes, as regressions

    /// The driver's state once a scenario has settled.
    static func settled(_ scene: LeaseScene, since mark: Int) async -> LeaseDriverState {
        await scene.waitForState(since: mark) { $0.isReleased || $0.isLost }
        await scene.settle()
        return await scene.driver.state
    }

    /// Probe 1. A loss, whose release R1 is parked; a take, queued behind R1; Auto, a release on
    /// arrival; then R1 fails unanswered. The only release sent was never answered, and the driver
    /// holds nothing. Nothing may be selected.
    ///
    /// **Mutation (I1):** brings Automatic back for `.released`, the state this ends in. Run: red
    /// at the claims.
    @Test("A loss, a take, Auto, and the loss's release unanswered: nothing selected")
    func probeOne() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.helper.pushHealth(.unresponsive)
        await scene.waitForState { $0.isLost }
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }

        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.driver.selectAutomatic()
        #expect(await scene.driver.state == .releasing)
        let mark = await scene.mark()
        await scene.helper.answerParked(
            .release, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
        let end = await Self.settled(scene, since: mark)

        #expect(await scene.entries.acquires.count == 1, "no second acquire was sent")
        let claims = try Self.claims(end)
        #expect(claims.fan == .unknown, "\(end)")
        #expect(claims.all == .none, "\(end)")
        await scene.finish()
    }

    /// Probe 2, I2's shape after a loss. A loss whose release fails unanswered; then a take the
    /// helper refuses `.leaseHeldByAnotherClient`, because the lost lease is still in its table.
    @Test("A loss, its release unanswered, then a refused take: nothing selected")
    func probeTwo() async throws {
        let scene = await LeaseScene()
        _ = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .fail(.helperNeverAnswered(after: .seconds(5))))
        await scene.helper.pushHealth(.unresponsive)
        await scene.waitForState { $0.isLost }
        await scene.ledger.waitFor { !$0.releases.isEmpty }
        await scene.settle()
        await scene.helper.script(
            .acquire, .refuse(.manualControlUnavailable(reason: .leaseHeldByAnotherClient)))

        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.waitForState { if case .refused = $0 { true } else { false } }
        let end = await scene.driver.state

        guard case .refused = end else {
            Issue.record("not refused: \(end)")
            await scene.finish()
            return
        }
        let claims = try Self.claims(end)
        #expect(claims.fan == .unknown)
        #expect(claims.all == .none)
        await scene.finish()
    }

    /// Probe 3. A held lease that sent an `apply`; Auto, whose release R1 is parked; a take queued
    /// behind it; R1 fails unanswered, so the queued take acquires, parked; Auto again, a release
    /// on arrival; then the acquire fails unanswered. The driver holds nothing, and the lease that
    /// did apply was never confirmed released. Nothing may be selected.
    ///
    /// **Mutation (I1):** brings Automatic back for `.released`, the state this ends in. Run: red
    /// at the claims.
    @Test(
        "An unconfirmed release, a queued take, Auto, and the acquire unanswered: nothing selected")
    func probeThree() async throws {
        let scene = await LeaseScene()
        let held = try #require(await scene.take(LeaseScene.target([0: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.selectAutomatic()
        await scene.ledger.waitFor { $0.releases == [held.lease.id] }
        await scene.driver.take(try LeaseScene.target([0: 3500]))
        await scene.helper.script(.acquire, .parked)
        await scene.helper.answerParked(
            .release, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
        await scene.ledger.waitFor { $0.acquires.count == 2 }
        await scene.driver.selectAutomatic()
        let mark = await scene.mark()
        await scene.helper.answerParked(
            .acquire, throwing: HelperClientError.helperNeverAnswered(after: .seconds(5)))
        let end = await Self.settled(scene, since: mark)

        #expect(await scene.entries.applies.count == 1, "the first lease did apply")
        let claims = try Self.claims(end)
        #expect(claims.fan == .unknown, "\(end)")
        #expect(claims.all == .none, "\(end)")
        await scene.finish()
    }
}
