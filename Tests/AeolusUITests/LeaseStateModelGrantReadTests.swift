import AeolusXPC
import AeolusXPCClient
import Combine
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The read `LeaseStateModel` asks for at a grant (#154, #515's first round): once per lease
/// identifier entering `held`, and at no other report that is `held`. An extension, so these run in
/// `LeaseStateModelTests`, under its time limit.
extension LeaseStateModelTests {

    /// Two grants, each followed by every other kind of report that is `held` under the same
    /// lease: its first `apply` answered, a renewal (the same identifier, a later expiry), a
    /// target queued behind an `apply`, and an evidence change. One read each grant, and none for
    /// the rest.
    ///
    /// **Mutation (G1, "every held report asks"):** in `LeaseStateModel.isNewGrant`, drop the
    /// identifier check, so any `held` asks. Run: red at the count after the reports under the
    /// same lease, and at both counts after the second grant. **Mutation (G2, "no grant
    /// read"):** make `isNewGrant` return `false`. Run: red at the grant's count, here and at
    /// `AutomaticAfterAReadTests`' grant read.
    @Test("One read is asked for each grant, and none for any other report while held")
    func asksOneReadPerGrant() async throws {
        let (stream, feed) = AsyncStream.makeStream(of: LeaseDriverReport.self)
        let counts = Counts()
        let model = LeaseStateModel(following: stream, askForARead: { counts.nudges += 1 })
        let sink = model.objectWillChange.sink { counts.publishes += 1 }
        defer { sink.cancel() }

        typealias Evidence = LeaseDriverReport.AutomaticEvidence
        func step(_ state: LeaseDriverState, _ evidence: Evidence = .anyRead) async throws {
            let report = LeaseDriverReport(state: state, automaticEvidence: evidence)
            feed.yield(report)
            try #require(await Support.settle { model.current == report }, "\(report)")
        }
        let first = try FanControlFixtures.target([0: 3000])
        let second = try FanControlFixtures.target([0: 3500])
        let leaseA = Lease(holderDescription: LeaseScene.holder, expiresAt: Date())
        let renewedA = Lease(
            id: leaseA.id, holderDescription: LeaseScene.holder,
            expiresAt: leaseA.expiresAt.addingTimeInterval(30))
        let leaseB = Lease(holderDescription: LeaseScene.holder, expiresAt: Date())
        func held(_ lease: Lease, _ phase: HeldLease.Phase) -> LeaseDriverState {
            .held(HeldLease(lease: lease, fans: [0], phase: phase))
        }

        try await step(.acquiring(fans: [0]))
        #expect(counts.nudges == 0)

        try await step(held(leaseA, .applying(first, queued: nil)))
        #expect(counts.nudges == 1, "no read was asked for at the grant")

        try await step(held(leaseA, .confirmed(first)))
        try await step(held(renewedA, .confirmed(first)))
        try await step(held(renewedA, .applying(first, queued: second)))
        try await step(held(renewedA, .applying(first, queued: second)), .noRead)
        #expect(counts.nudges == 1, "a report under the same lease asked for a read")
        #expect(counts.publishes == 6, "each report was published")

        try await step(.releasing)
        try await step(.acquiring(fans: [0]))
        try await step(held(leaseB, .applying(second, queued: nil)))
        #expect(counts.nudges == 2, "no read was asked for at the second grant")
        try await step(held(leaseB, .confirmed(second)))
        #expect(counts.nudges == 2)
        feed.finish()
    }

    /// A report that is both a new grant and a new floor asks once. The driver publishes neither
    /// with the other today; the rule is that one report asks for at most one read.
    @Test("A report that is both a grant and a floor asks for one read")
    func aGrantWithAFloorAsksOnce() async throws {
        let floor = try await Self.twoFloors().0
        let (stream, feed) = AsyncStream.makeStream(of: LeaseDriverReport.self)
        let counts = Counts()
        let model = LeaseStateModel(following: stream, askForARead: { counts.nudges += 1 })

        let report = LeaseDriverReport(
            state: .held(
                HeldLease(
                    lease: FanControlFixtures.ours, fans: [0],
                    phase: .confirmed(try FanControlFixtures.target([0: 3000])))),
            automaticEvidence: .readFrom(floor))
        feed.yield(report)
        try #require(await Support.settle { model.current == report })

        #expect(counts.nudges == 1)
        feed.finish()
    }
}
