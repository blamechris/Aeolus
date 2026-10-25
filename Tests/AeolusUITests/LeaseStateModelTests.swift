import AeolusXPC
import AeolusXPCClient
import Combine
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `LeaseStateModel` over a scripted report stream: it publishes a report when any part of it
/// changes, the evidence included, and it asks for a read once per new floor and at no other
/// report (ADR 0015 D2's nudge).
///
/// Each step yields one report and waits, boundedly, for the model to hold it. A report the model
/// must ignore has nothing to wait for, so the step after it carries a report that differs, and
/// the counts are read once that one has landed: the stream delivers in order.
@Suite(
    "LeaseStateModel — every change published, one read asked per new floor",
    .timeLimit(.minutes(1)))
@MainActor
struct LeaseStateModelTests {

    typealias Support = SnapshotTestSupport
    typealias Ticket = LeaseDriver.SnapshotTicket

    /// What the model did: how many times it announced a change, and how many reads it asked for.
    final class Counts {
        var publishes = 0
        var nudges = 0
    }

    /// Two floors from one driver, the second later than the first: two refused acquisitions.
    static func twoFloors() async throws -> (Ticket, Ticket) {
        let scene = await LeaseScene()
        await scene.helper.script(.acquire, .refuse(.leaseUnknown), .refuse(.leaseUnknown))
        var floors: [Ticket] = []
        for _ in 0..<2 {
            let mark = await scene.mark()
            await scene.driver.take(try LeaseScene.target([0: 3000]))
            await scene.waitForState(since: mark) { if case .refused = $0 { true } else { false } }
            guard case .readFrom(let floor) = await scene.driver.report.automaticEvidence else {
                throw FloorMissing()
            }
            floors.append(floor)
        }
        await scene.finish()
        try #require(floors[0] < floors[1], "the second floor is later")
        return (floors[0], floors[1])
    }

    struct FloorMissing: Error {}

    /// **Mutation (M-B, "the state alone"):** in `LeaseStateModel.publish`, compare
    /// `report.state != stored.state`. Run: red at the floor's step, which the model never holds.
    /// **Mutation (M-C, "a state change nudges"):** nudge when the state changes, not the
    /// evidence. Run: red at `acquiring`'s and `noRead`'s zero nudges, and at the floor's one.
    /// **Mutation (M-E, "every report nudges"):** call `whenTheDriverStopsActing()` for every
    /// report. Run: red at the first zero.
    /// **Mutation (M-G, "noRead nudges"):** treat `.noRead` as a floor in `isFloor`. Run: red at
    /// `noRead`'s zero.
    @Test("A report is published when it changes, and a read asked only for a new floor")
    func publishesEveryChangeAndNudgesOncePerFloor() async throws {
        let (floor, laterFloor) = try await Self.twoFloors()
        let (stream, feed) = AsyncStream.makeStream(of: LeaseDriverReport.self)
        let counts = Counts()
        let model = LeaseStateModel(
            following: stream, whenTheDriverStopsActing: { counts.nudges += 1 })
        let sink = model.objectWillChange.sink { counts.publishes += 1 }
        defer { sink.cancel() }

        func step(_ report: LeaseDriverReport) async throws {
            feed.yield(report)
            try #require(await Support.settle { model.current == report }, "\(report)")
        }
        let fault = AeolusXPCFault.manualControlUnavailable(reason: .writePathNotBuilt)

        // `idle` again, then the driver acting: published, and no read asked for.
        feed.yield(.idle)
        try await step(LeaseDriverReport(state: .acquiring(fans: [0]), automaticEvidence: .anyRead))
        #expect(counts.publishes == 1, "the repeated idle was published")
        #expect(counts.nudges == 0, "a read was asked for with no floor")

        // Stopped with an apply unanswered: published, and no read asked for.
        try await step(LeaseDriverReport(state: .released, automaticEvidence: .noRead))
        #expect(counts.publishes == 2)
        #expect(counts.nudges == 0, "a read was asked for with no read admitted")

        // The same state, the evidence moving to a floor: published, and one read.
        let floored = LeaseDriverReport(state: .released, automaticEvidence: .readFrom(floor))
        try await step(floored)
        #expect(counts.publishes == 3, "the floor was not published: the evidence alone moved")
        #expect(counts.nudges == 1, "no read was asked for at the floor")

        // The same report again, then the driver acting with the same floor: one publish, no read.
        feed.yield(floored)
        try await step(
            LeaseDriverReport(state: .acquiring(fans: [0]), automaticEvidence: .readFrom(floor)))
        #expect(counts.publishes == 4, "the repeated report was published")
        #expect(counts.nudges == 1, "a read was asked for without a new floor")

        // Stopped again, at a newer floor: one more read.
        try await step(
            LeaseDriverReport(state: .refused(fault), automaticEvidence: .readFrom(laterFloor)))
        #expect(counts.publishes == 5)
        #expect(counts.nudges == 2, "no read was asked for at the newer floor")
        feed.finish()
    }
}
