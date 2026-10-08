import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The closing shapes `fanctl set` builds: the report behind each ending, and the facts that go
/// into `--json`'s closing event. The words are `SetMessagesTests`.
@Suite("fanctl set's closing shapes")
struct SetClosingShapeTests {

    typealias Fixtures = SafeStateTests
    typealias Shared = SetFixtures

    /// 2, 4 and 5 are the three "no" answers a person can act on; the rest are not a refusal of
    /// this request, and say so with a null.
    ///
    /// **Mutation:** add `.helperNotReachable` to the set in `Report.notStarted`. Run: red.
    @Test("Only the three refusals are reported as refused, whatever else fails before a lease")
    func refusedIsOnlyTheRefusals() {
        for code in FanctlExitCode.allCases where code != .success {
            let report = SetCommand.Report.notStarted(HelperCommandFailure(code, "x"))
            let refused: Set<FanctlExitCode> = [
                .requestDoesNotFit, .manualControlRefused, .heldByAnotherClient,
            ]
            #expect(
                report.endedBecause == (refused.contains(code) ? "refused" : nil), "\(code)")
            #expect(report.leaseID == nil)
            #expect(report.facts.fans == nil)
            #expect(report.failure?.code == code)
        }
    }

    private static let closingKeys: Set<String> = [
        "schema", "event", "at", "leaseID", "endedBecause", "signal", "releaseAccepted",
        "capturedAt", "snapshotFollowsRelease", "listedLeaseID", "fans", "failure",
    ]

    private static func keys(of event: some Encodable) throws -> [String: Any] {
        let line = try FanctlJSON.encodeLine(event)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }

    /// A caller reading `failed` from before `set` extended it reads the same four keys; the
    /// extension adds the rest, always present, `null` where there is nothing to say.
    ///
    /// **Mutation:** drop a key from `SetClosingFacts.encode(into:)`. Run: red.
    @Test("Every closing event carries every closing key, null when there is nothing to say")
    func closingEventsCarryEveryKey() throws {
        let failure = HelperCommandOutput.FailureJSON(
            exitCode: 2, kind: "requestDoesNotFit", message: "no")
        let failed = try Self.keys(
            of: HelperCommandOutput.FailureEventJSON(failure: failure, at: Date()))
        #expect(Set(failed.keys) == Self.closingKeys)
        #expect(failed["event"] as? String == "failed")
        #expect(failed["schema"] as? Int == 1)
        #expect((failed["failure"] as? [String: Any])?["exitCode"] as? Int == 2)
        for key in Self.closingKeys.subtracting(["schema", "event", "at", "failure"]) {
            #expect(failed[key] is NSNull, "\(key) should be null")
        }

        let ended = try Self.keys(of: SetEndedEventJSON(at: Date(), facts: .none))
        #expect(Set(ended.keys) == Self.closingKeys)
        #expect(ended["event"] as? String == "ended")
        #expect(ended["failure"] is NSNull)
    }

    @Test("A report's facts carry the observed fans beside the plan, or null for one not seen")
    func factsPairPlansWithObservations() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50)), try Shared.plan(7, .rpm(2000))])
        let report = SetCommand.Report.lost(
            .thermalEmergency, hold: hold, release: .failed("x"),
            snapshot: SystemSnapshot(
                fans: [Fixtures.fan(0)], sensors: [], activeLease: nil,
                isThermalEmergencyActive: true, capturedAt: Fixtures.captured))
        let facts = report.facts
        #expect(facts.endedBecause == "controlLost")
        #expect(facts.releaseAccepted == false)
        #expect(facts.snapshotFollowsRelease == false)
        let fans = try #require(facts.fans)
        try #require(fans.count == 2)
        #expect(fans.map(\.plan.index) == [0, 7])
        #expect(fans[0].observed?.index == 0)
        #expect(fans[1].observed == nil, "fan 7 was not in the snapshot")
    }

    @Test("A signal before control has the signal and no lease")
    func interruptedBeforeControl() {
        let report = SetCommand.Report.interruptedBeforeControl(.terminate)
        #expect(report.failure?.code == .failure)
        #expect(report.facts.signal == "SIGTERM")
        #expect(report.facts.leaseID == nil)
        #expect(report.facts.endedBecause == "signal")
    }

    /// The lease was taken and a signal landed before the speed was sent: ended by the signal,
    /// the lease given back, no fan written.
    @Test("A signal after the lease and before the speed has the signal and the lease")
    func interruptedBeforeApply() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let report = SetCommand.Report.interruptedBeforeApply(
            .interrupt, hold: hold, release: .accepted)
        #expect(report.failure?.code == .failure)
        #expect(report.facts.endedBecause == "signal")
        #expect(report.facts.signal == "SIGINT")
        #expect(report.facts.leaseID == hold.leaseID)
        #expect(report.facts.releaseAccepted == true)
        let message = try #require(report.failure?.message)
        #expect(message.contains("before any speed was sent"))
        #expect(message.contains("Nothing was sent to a fan"))
    }

    /// An unanswered apply is `controlLost` with the failure's own code, and carries the check's
    /// verdict as a snapshot only when the check read one.
    @Test("An unanswered apply keeps the failure's code and is reported as controlLost")
    func applyUnansweredShape() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let failure = HelperCommandFailure(
            classifying: HelperClientError.helperNeverAnswered(after: .seconds(5)),
            during: .beforeControl)
        let read = SetCommand.Report.applyUnanswered(
            failure, hold: hold, release: .accepted,
            settlement: Shared.settlement(Fixtures.automatic, verdict: .automatic))
        let unread = SetCommand.Report.applyUnanswered(
            failure, hold: hold, release: .failed("x"),
            settlement: Shared.settlement(nil, interruption: Shared.Gone()))

        for report in [read, unread] {
            #expect(report.failure?.code == .failure, "the apply's classified code")
            #expect(report.facts.endedBecause == "controlLost")
            #expect(report.facts.leaseID == hold.leaseID)
        }
        #expect(read.facts.snapshotFollowsRelease == true)
        #expect(unread.facts.snapshotFollowsRelease == nil, "nothing was read to qualify")
        #expect(unread.facts.releaseAccepted == false)
    }

    // MARK: - Terminal

    @Test("A terminal made from a plain sink always delivers, to either stream")
    func plainSinkDelivers() {
        let terminal = Terminal { _, _ in }
        let sinks = terminal.lineSinks()

        sinks.standardOutput.enqueue("x", at: ContinuousClock.now)
        sinks.standardError.enqueue("y", at: ContinuousClock.now)

        #expect(
            sinks.standardOutput.status == LinePump.Status(oldestUnfinished: nil, isBroken: false))
        #expect(
            sinks.standardError.status == LinePump.Status(oldestUnfinished: nil, isBroken: false))
    }
}
