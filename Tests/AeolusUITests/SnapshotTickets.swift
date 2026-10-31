import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl

/// Snapshot tickets for the suites, every one minted by a real `LeaseDriver`: a ticket's count is
/// `fileprivate` to `LeaseDriver.swift`, so a suite can no more forge one than the app can.
/// Namespaced, so nothing here can shadow a global helper another suite in this target declares.
enum SnapshotTickets {

    /// A driver that never acts, for an observer double that needs a ticket to hand the source and
    /// whose order the test does not read.
    static let idleDriver = LeaseDriver(
        control: FakeLeaseHelper(clock: HandWoundClock(), ledger: LeaseLedger()),
        holderDescription: LeaseScene.holder)

    /// A ticket from `idleDriver`.
    static func any() async -> LeaseDriver.SnapshotTicket {
        await idleDriver.beginSnapshotRead()
    }

    /// One floor, and a ticket on each side of it.
    struct AroundAFloor: Sendable {
        /// Taken before the driver stopped acting.
        let before: LeaseDriver.SnapshotTicket
        /// What the driver published when it stopped acting: `.readFrom(floor)`.
        let evidence: LeaseDriverReport.AutomaticEvidence
        /// Taken after it.
        let after: LeaseDriver.SnapshotTicket
    }

    /// A driver taken from `idle` to `refused`, the shortest path into a state that sets a floor,
    /// with a ticket taken on each side. Every presentation suite that needs a read's timing uses
    /// these, so what it pins is the presentation's comparison and not a path; the driver's own
    /// suite (`LeaseDriverFloorTests`) pins the floor on every path.
    static func aroundAFloor() async throws -> AroundAFloor {
        let scene = await LeaseScene()
        let before = await scene.driver.beginSnapshotRead()
        await scene.helper.script(.acquire, .refuse(.leaseUnknown))
        await scene.driver.take(try LeaseScene.target([0: 3000]))
        await scene.waitForState { if case .refused = $0 { true } else { false } }
        let evidence = await scene.driver.report.automaticEvidence
        let after = await scene.driver.beginSnapshotRead()
        await scene.finish()
        try #require(!evidence.admits(before), "the floor is after the first ticket")
        try #require(evidence.admits(after), "and at or before the second")
        return AroundAFloor(before: before, evidence: evidence, after: after)
    }
}
