import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// ADR 0015 D1, one condition at a time: Automatic only when the driver holds nothing and is not
/// acquiring or releasing, a licensed snapshot is on screen whose read was ticketed after the
/// driver last stopped acting, that snapshot lists no lease, and it reports the fan cleared.
///
/// Every test that refuses Automatic for one condition meets every other: no lease listed, both
/// fans cleared (checked, not assumed), a licensed snapshot, and a read past the floor, so nothing
/// but the condition under test can refuse it. The tickets are a real driver's
/// (`SnapshotTickets.aroundAFloor()`).
///
/// The driver scenarios at the end are #497's delta-review probes, which reach a state that stops
/// acting by paths on which no release answer is kept, now judged with the report the driver
/// published there.
@Suite(
    "FanControlPresentation — Automatic only from a snapshot read after the driver stopped acting",
    .timeLimit(.minutes(1)))
struct FanControlAutomaticTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Evidence = LeaseDriverReport.AutomaticEvidence
    typealias Ticket = LeaseDriver.SnapshotTicket

    /// No lease listed, both fans cleared: what a snapshot read before any grant shows, and what
    /// one read after a handback shows too.
    static let cleared = Support.snapshot(fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)])

    /// Every state in which the driver has stopped acting: `released`, `lost` for every cause and
    /// `refused` for every fault.
    static let stopped: [LeaseDriverState] =
        [.released]
        + Fixtures.CauseTag.allCases.flatMap(\.causes).map {
            .lost(LeaseLoss(lease: Fixtures.ours, cause: $0, afterWake: false))
        }
        + Fixtures.FaultTag.allCases.map { .refused($0.fault(carrying: "detail")) }

    /// The control and fan 0's presentation, over `snapshot` read with `ticket`, beside `driver`
    /// and the `evidence` published with it.
    static func claims(
        _ driver: LeaseDriverState, _ evidence: Evidence, readWith ticket: Ticket?,
        over snapshot: SystemSnapshot = cleared
    ) throws -> (fan: FanControlPresentation.Selection, all: AllFansControlPresentation.Selection) {
        let screen = Fixtures.screen(snapshot, driver: driver, evidence: evidence, readWith: ticket)
        let fans = AllFansControlPresentationTests.fans(screen)
        return (
            try Fixtures.present(0, on: screen).selection,
            AllFansControlPresentation(fans: fans, snapshot: snapshot).selection
        )
    }

    // MARK: - The positive controls

    /// **Mutation (I4, the positive control):** make `automaticClaim` always answer `.unknown`.
    /// Run: red here, so the tests below can see the rule say yes.
    @Test("Idle, no lease listed, every fan cleared: Automatic, from any read")
    func idleIsAutomatic() throws {
        #expect(Self.cleared.fans.allSatisfy { $0.isClearedToAutomatic })
        let claims = try Self.claims(.idle, .anyRead, readWith: nil)

        #expect(claims.fan == .automatic)
        #expect(claims.all == .automatic)
    }

    /// Auto detection after the app has acted: a read past the floor that lists no lease and
    /// shows the fans cleared is Automatic under every state that stops acting, the user's own
    /// answered Auto first among them.
    ///
    /// **Mutation (F9, "D3's interim back"):** in `claim`, return `.unknown` for `.released`,
    /// `.lost` and `.refused`, as ADR 0015 D3 did. Run: red here, for every argument.
    @Test(
        "A read after the driver stopped, no lease, every fan cleared: Automatic",
        arguments: stopped)
    func aReadAfterTheFloorIsAutomatic(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let claims = try Self.claims(driver, floor.evidence, readWith: floor.after)

        #expect(claims.fan == .automatic, "\(driver)")
        #expect(claims.all == .automatic, "\(driver)")
    }

    // MARK: - Condition 2: the read's timing

    /// The snapshot that predates the floor shows exactly what one after it does: no lease, the
    /// fans cleared. Only its ticket tells it apart.
    ///
    /// **Mutation (F6, "no ticket guard"):** delete `inputs.automaticEvidence.admits(...)` from
    /// `automaticClaim`. Run: red here, for every argument.
    @Test(
        "A read from before the driver stopped, however clear it looks: nothing selected",
        arguments: stopped)
    func aReadBeforeTheFloorIsNot(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let claims = try Self.claims(driver, floor.evidence, readWith: floor.before)

        #expect(claims.fan == .unknown, "\(driver)")
        #expect(claims.all == .none, "\(driver)")
    }

    /// A snapshot from a source with no observer carries no ticket, and passes no floor.
    ///
    /// **Mutation (F8, "a nil ticket passes"):** in `AutomaticEvidence.admits(_:)`, answer `true`
    /// for a `nil` ticket. Run: red here, for every argument.
    @Test("A read with no ticket passes no floor", arguments: stopped)
    func aReadWithNoTicketIsNot(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let claims = try Self.claims(driver, floor.evidence, readWith: nil)

        #expect(claims.fan == .unknown, "\(driver)")
        #expect(claims.all == .none, "\(driver)")
    }

    /// While an `apply` sent before the driver stopped is unanswered, no read is evidence, however
    /// late (#498's S2).
    ///
    /// **Mutation (S2a, "noRead admits"):** in `AutomaticEvidence.admits(_:)`, answer `true` for
    /// `.noRead`. Run: red here, for every argument.
    @Test("While an apply is unanswered, no read is evidence", arguments: stopped)
    func noReadIsEvidenceWhileAnApplyIsUnanswered(_ driver: LeaseDriverState) async throws {
        let floor = try await SnapshotTickets.aroundAFloor()
        let claims = try Self.claims(driver, .noRead, readWith: floor.after)

        #expect(claims.fan == .unknown, "\(driver)")
        #expect(claims.all == .none, "\(driver)")
    }

    // MARK: - Condition 3: no lease listed

    /// Fans cleared, a read past the floor, and a lease listed: the app's own, and another
    /// client's. A fan under a live lease whose `apply` has not landed reads available and
    /// automatic, because the helper cannot state `.leaseHeldByAnotherClient` per fan; and the
    /// helper can still list the app's lease after a release it did not confirm.
    ///
    /// **Mutation (F7 and I3, "no lease guard"):** delete `activeLease == nil` from
    /// `SystemSnapshot.showsAutomatic(_:)`, the one place it is decided (ADR 0015 D4). Run: red
    /// here, for both leases and both drivers, and in `SafeStateTests` (see F11).
    @Test(
        "Beside a listed lease, with every fan cleared and a read past the floor: nothing selected",
        arguments: [Fixtures.ours, Fixtures.theirs])
    func aListedLeaseRefusesAutomatic(_ lease: Lease) async throws {
        let listed = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)], activeLease: lease)
        #expect(
            listed.fans.allSatisfy { $0.isClearedToAutomatic },
            "the fans are cleared, so only the listed lease can refuse Automatic")
        let floor = try await SnapshotTickets.aroundAFloor()
        #expect(floor.evidence.admits(floor.after), "and the read is past the floor")

        for (driver, evidence) in [
            (LeaseDriverState.idle, Evidence.anyRead), (.released, floor.evidence),
        ] {
            let claims = try Self.claims(driver, evidence, readWith: floor.after, over: listed)
            #expect(claims.fan == .unknown, "\(driver)")
            #expect(claims.all == .none, "\(driver)")
        }
    }

    // MARK: - The licence (#497's delta review, S3)

    /// `.idle` admits any read, so the licence is all that stands between a cleared row and
    /// Automatic when no snapshot is on screen. Each source of "not tracked" is pinned, and a
    /// reported, cleared row with nothing on screen to judge it.
    ///
    /// **Mutation (S3, "idle claims Automatic with no snapshot on screen"):** in `automaticClaim`,
    /// answer `.automatic` when the licence is not `.licensed`. Run: red here, for every reason,
    /// and at the row with nothing on screen.
    @Test(
        "Idle with no licensed snapshot on screen claims no Automatic",
        arguments: ControlSourceDisplayTests.everyReason)
    func idleNeedsALicensedSnapshot(_ why: ControlNotTracked) throws {
        let withdrawn = Fixtures.withdrawn(why, driver: .idle, from: Self.cleared)
        #expect(try Fixtures.present(0, on: withdrawn).selection == .unknown, "\(why)")

        let shown = Fixtures.screen(Self.cleared, driver: .idle)
        let nothingOnScreen = Fixtures.Screen(
            inputs: FanControlPresentation.Inputs(
                controlSource: .helperSnapshot(activeLease: nil), thermalEmergency: .inactive,
                renderedSnapshot: nil, renderedReadTicket: nil, driver: .idle,
                automaticEvidence: .anyRead),
            rows: shown.rows)
        #expect(
            try Fixtures.present(0, on: nothingOnScreen).affordance == .disabled(.nothingOnScreen))
        #expect(try Fixtures.present(0, on: nothingOnScreen).selection == .unknown)
        #expect(try Fixtures.present(0, on: shown).selection == .automatic, "the control")
    }

    // MARK: - The delta review's probes, with the driver's own reports

    /// The three paths #497's delta review found ending in a state that stops acting with no
    /// release answer kept. A snapshot read just before the last event claims nothing; one read
    /// after it claims Automatic only when it lists no lease.
    ///
    /// The third reaches `released` after a lease that did send an `apply` was never confirmed
    /// released, so the helper can still list it: the probe-3 shape, where read timing alone is
    /// not enough and the no-lease condition (F7) is what refuses.
    static let probes: [FloorPath] = [
        .lossTakeAutoReleaseUnanswered, .lossThenRefusedTake,
        .releaseUnconfirmedThenAutoAcquireFails,
    ]

    /// **Mutation (F1):** red here too, at the read from before. **Mutation (F7):** red at the
    /// listed lease, for every probe.
    @Test(
        "The delta review's probes claim Automatic only from a later read listing no lease",
        arguments: probes)
    func theProbes(_ path: FloorPath) async throws {
        let scene = await LeaseScene()
        let mark = await scene.mark()
        let before = try await path.drive(scene)
        let report = try #require(
            await LeaseDriverFloorTests.published(scene, since: mark, ending: path))
        let after = await scene.driver.beginSnapshotRead()
        let listed = Support.snapshot(
            fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)], activeLease: Fixtures.ours)

        let early = try Self.claims(report.state, report.automaticEvidence, readWith: before)
        #expect(early.fan == .unknown, "\(path): \(report)")
        #expect(early.all == .none, "\(path)")
        let late = try Self.claims(report.state, report.automaticEvidence, readWith: after)
        #expect(late.fan == .automatic, "\(path): \(report)")
        #expect(late.all == .automatic, "\(path)")
        let stillListed = try Self.claims(
            report.state, report.automaticEvidence, readWith: after, over: listed)
        #expect(stillListed.fan == .unknown, "\(path): the lease is still listed")
        #expect(stillListed.all == .none, "\(path)")
        await scene.finish()
    }
}
