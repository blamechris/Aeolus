import AeolusXPC
import AeolusXPCClient
import Combine
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `LeaseStateModel.enteredAfterTheUsersAuto` over a scripted report stream (#157): `true` only for
/// a state the driver entered after the user's last request, when that request was Auto.
///
/// Each step yields one report and waits, boundedly, for the model to hold it, as
/// `LeaseStateModelTests` does.
@Suite(
    "LeaseStateModel — whether the state on screen follows the user's own Auto",
    .timeLimit(.minutes(1)))
@MainActor
struct LeaseStateModelUsersAutoTests {

    typealias Support = SnapshotTestSupport

    /// **Mutation (L1, "any report counts"):** in `LeaseStateModel.publish`, set
    /// `stateFollowsAutomatic` for every report, not only a change of state. Run: red at the
    /// evidence-only report after an Auto asked for in `released`.
    /// **Mutation (L2, "a take keeps it"):** in `userAskedForControl()`, delete the line that sets
    /// `stateFollowsAutomatic` to `false`. Run: red at the expectation right after the take.
    /// **Mutation (L3, "a take is not a request"):** in `userAskedForControl()`, delete
    /// `lastAskedForAutomatic = false`. Run: red at the release nobody asked for and at the last
    /// expectation, and at `MonitoringModeBannerTests.aTakeEndsTheAutosClaim`.
    /// **Mutation (L4, "nothing re-renders"):** in `userAskedForControl()`, delete
    /// `objectWillChange.send()`. Run: red at the publish count after the take.
    @Test("True from the first state after the user's Auto, until the next take")
    func followsTheUsersAutoUntilTheNextTake() async throws {
        let (stream, feed) = AsyncStream.makeStream(of: LeaseDriverReport.self)
        let model = LeaseStateModel(following: stream, whenTheDriverStopsActing: {})
        let counts = LeaseStateModelTests.Counts()
        let sink = model.objectWillChange.sink { counts.publishes += 1 }
        defer { sink.cancel() }

        func step(_ report: LeaseDriverReport) async throws {
            feed.yield(report)
            try #require(await Support.settle { model.current == report }, "\(report)")
        }
        let (early, later) = try await LeaseStateModelTests.twoFloors()
        let held = FanControlFixtures.held(
            FanControlFixtures.ours, fans: [0], .confirmed(try FanControlFixtures.target([0: 3000]))
        )

        // Acting with nothing asked for: not the user's Auto.
        try await step(LeaseDriverReport(state: held, automaticEvidence: .anyRead))
        #expect(!model.enteredAfterTheUsersAuto)

        // Auto: the state already on screen predates it; the next states follow it.
        model.userAskedForAutomatic()
        #expect(!model.enteredAfterTheUsersAuto, "the held state was entered before the Auto")
        try await step(LeaseDriverReport(state: .releasing, automaticEvidence: .anyRead))
        #expect(model.enteredAfterTheUsersAuto)
        try await step(LeaseDriverReport(state: .released, automaticEvidence: .noRead))
        #expect(model.enteredAfterTheUsersAuto)
        try await step(LeaseDriverReport(state: .released, automaticEvidence: .readFrom(early)))
        #expect(model.enteredAfterTheUsersAuto, "an evidence-only report keeps the state's answer")
        model.userAskedForAutomatic()
        #expect(model.enteredAfterTheUsersAuto, "a second Auto changed it")

        // A take: the state on screen no longer follows the Auto, and is re-rendered at once.
        let before = counts.publishes
        model.userAskedForControl()
        #expect(!model.enteredAfterTheUsersAuto, "the take left the Auto's answer standing")
        #expect(counts.publishes == before + 1, "the take's change was not announced")

        // A release nobody asked for: the last control window, fast user switching.
        try await step(LeaseDriverReport(state: held, automaticEvidence: .readFrom(early)))
        try await step(LeaseDriverReport(state: .releasing, automaticEvidence: .readFrom(early)))
        try await step(LeaseDriverReport(state: .released, automaticEvidence: .readFrom(later)))
        #expect(!model.enteredAfterTheUsersAuto, "a release nobody asked for read as the user's")

        // Auto asked for in `released`: nothing changes state, so nothing follows it.
        model.userAskedForAutomatic()
        try await step(LeaseDriverReport(state: .released, automaticEvidence: .noRead))
        #expect(!model.enteredAfterTheUsersAuto, "a state from before the Auto read as after it")
        feed.finish()
    }

    /// A state entered after the Auto counts whatever it is: `lost` included. The banner reads the
    /// state as well (`MonitoringModeDisplay.isTheUsersAuto`), and refuses it there.
    @Test("A loss after the user's Auto still follows it; the banner reads the state")
    func aLossAfterAutoFollowsIt() async throws {
        let (stream, feed) = AsyncStream.makeStream(of: LeaseDriverReport.self)
        let model = LeaseStateModel(following: stream, whenTheDriverStopsActing: {})
        let lost = LeaseDriverState.lost(
            LeaseLoss(
                lease: FanControlFixtures.ours, cause: .releaseUnconfirmed(.other("no answer")),
                afterWake: false))

        model.userAskedForAutomatic()
        feed.yield(LeaseDriverReport(state: .releasing, automaticEvidence: .anyRead))
        feed.yield(LeaseDriverReport(state: lost, automaticEvidence: .noRead))
        try #require(await Support.settle { model.current.state == lost })

        #expect(model.enteredAfterTheUsersAuto)
        feed.finish()
    }

    @Test("A build with no driver never follows an Auto")
    func noDriverNeverFollows() {
        let model = LeaseStateModel()
        model.userAskedForAutomatic()
        #expect(!model.enteredAfterTheUsersAuto)
    }
}
