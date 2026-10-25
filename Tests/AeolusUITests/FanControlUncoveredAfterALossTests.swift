import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// ADR 0015 D5 through a loss, with a real driver (#515's panel: claim S1, completeness S3).
///
/// After a loss the floor is minted when the loss is found, before the lost lease's release
/// answers. So a read ticketed between the two is admitted by the evidence beside the next held
/// lease: the floor alone does not date that read after fan 1's handback. What refuses it is the
/// lease the read can list. The driver asks for the next grant only once the release has answered
/// (`LeaseDriverGuardTests.aTakeAfterALossWaitsForTheRelease`, the ordering this test depends on),
/// so a read served before that grant lists the lost lease or no lease, and D5 refuses both. A read
/// listing the new lease shows fan 1 Automatic only when the helper reports it cleared.
@Suite(
    "FanControlPresentation — D5 through a loss, with a real driver",
    .timeLimit(.minutes(1)))
struct FanControlUncoveredAfterALossTests {

    typealias Uncovered = FanControlUncoveredTests
    typealias Support = SnapshotTestSupport

    /// Fan 1's presentation over `snapshot`, read with `ticket`, beside `report`.
    static func fan1(
        _ report: LeaseDriverReport, readWith ticket: LeaseDriver.SnapshotTicket,
        over snapshot: SystemSnapshot
    ) throws -> FanControlPresentation {
        try Uncovered.present(
            1, report.state, report.automaticEvidence, readWith: ticket, over: snapshot)
    }

    /// Lease A over both fans; a snapshot shows it gone, with A's release parked; a read is
    /// ticketed after the loss's floor; fan 0 is put in Custom, and the acquire waits for A's
    /// release; then lease B is held over fan 0.
    ///
    /// **Mutation (M4b, "no lease or own lease"):** in
    /// `SystemSnapshot.showsAutomatic(_:besideLease:covering:)`, replace the `controlLoss` term
    /// with `(activeLease == nil || activeLease?.id == leaseID) && !isThermalEmergencyActive`.
    /// Run: red at the early read listing no lease. **M4a** ("any listed lease") is red at the one
    /// listing A, and **M8** ("no clearance check") at the handback in flight.
    @Test("Through a loss, a read before the next grant claims nothing for the uncovered fan")
    func throughALoss() async throws {
        let scene = await LeaseScene()
        let leaseA = try #require(await scene.take(try LeaseScene.target([0: 3000, 1: 3000])))
        await scene.helper.script(.release, .parked)
        await scene.driver.observe(
            LeaseDriverLossTests.snapshot([], listing: nil),
            readWith: await scene.driver.beginSnapshotRead())
        try #require(await scene.driver.state.isLost)
        await scene.ledger.waitFor { $0.releases == [leaseA.lease.id] }
        let early = await scene.driver.beginSnapshotRead()

        let mark = await scene.mark()
        await scene.driver.takeFan(0, at: try LeaseDriverPerFanTests.speed(3000))
        await scene.settle()
        try #require(await scene.entries.acquires.count == 1, "the acquire waits for A's release")
        await scene.helper.answerParked(.release)
        let rest = try LeaseScene.target([0: 3000])
        await LeaseDriverPerFanTests.confirmed(rest, in: scene, since: mark)
        let report = await scene.driver.report
        let leaseB = try #require(report.state.heldLease)
        try #require(leaseB.fans == [0])

        // (a) The floor was minted at the loss, so it admits the early read.
        #expect(report.automaticEvidence.admits(early), "the floor alone does not refuse it")
        // (b) Served before B's grant, that read can list A or no lease. D5 refuses both.
        for listed in [leaseA.lease, nil] as [Lease?] {
            let presented = try Self.fan1(
                report, readWith: early, over: Uncovered.snapshot(listing: listed))
            #expect(presented.selection == .unknown, "listing \(listed.map(\.holderDescription))")
        }

        // A read listing B shows fan 1 Automatic only when the helper has cleared it.
        let after = await scene.driver.beginSnapshotRead()
        let cleared = try Self.fan1(
            report, readWith: after, over: Uncovered.snapshot(listing: leaseB.lease))
        #expect(cleared.selection == .automatic)
        let handingBack = Support.fan(
            1, mode: .automatic, availability: .unavailable(.releaseInProgress))
        let inFlight = try Self.fan1(
            report, readWith: after,
            over: Uncovered.snapshot(listing: leaseB.lease, fan1: handingBack))
        #expect(inFlight.selection == .unknown, "a handback in flight is not cleared")
        await scene.finish()
    }
}
