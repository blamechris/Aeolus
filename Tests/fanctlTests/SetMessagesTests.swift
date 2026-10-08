import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The words `fanctl set` uses and the closing shapes it builds, for the branches an end-to-end
/// run against the simulated helper cannot reach on its own. The runs themselves are
/// `FanctlSetTests`, `FanctlSetLossTests`, `FanctlSetRefusalTests` and `FanctlSetEndingTests`.
@Suite("fanctl set's messages and closing shapes")
struct SetMessagesTests {

    typealias Fixtures = SafeStateTests

    private static func plan(
        _ index: Int, _ speed: SetArguments.Speed, minimum: Double = 1350, maximum: Double = 5777
    ) throws -> SetFanPlan {
        let envelope = try FanControlEnvelope.validating(
            declaredMinimumRPM: minimum, declaredMaximumRPM: maximum
        ).get()
        let target: FanTargetRPM
        switch speed {
        case .percent(let percent): target = envelope.target(forPercent: Double(percent))
        case .rpm(let rpm): target = envelope.target(for: Double(rpm))
        }
        return SetFanPlan(index: index, requested: speed, envelope: envelope, target: target)
    }

    private static func hold(_ plans: [SetFanPlan], seconds: Int = 1_800) -> SetCommand.Hold {
        SetCommand.Hold(leaseID: UUID(), plans: plans, duration: .seconds(seconds))
    }

    // MARK: - Starting

    @Test("One fan reads as one sentence with the way out at its end")
    func oneFan() throws {
        let hold = Self.hold([try Self.plan(0, .percent(75))])
        let lines = SetMessages.startLines(hold)
        #expect(
            lines == [
                "Holding fan 0 at 75% (4670 RPM target; firmware 1350–5777 RPM) for 30m under "
                    + "lease \(hold.leaseID.uuidString). Ctrl-C returns it to automatic sooner."
            ])
    }

    @Test("An rpm request says target, and several fans share one way out")
    func severalFans() throws {
        let hold = Self.hold(
            [
                try Self.plan(0, .rpm(3000)),
                try Self.plan(1, .percent(0), minimum: 0, maximum: 3000),
            ],
            seconds: 90)
        let lines = SetMessages.startLines(hold)
        try #require(lines.count == 2)
        #expect(
            lines[0].hasPrefix("Holding fan 0 at 3000 RPM target (firmware 1350–5777 RPM) for 90s"))
        #expect(lines[1].hasPrefix("Holding fan 1 at 0% (100 RPM target; firmware 0–3000 RPM)"))
        #expect(!lines[0].contains("Ctrl-C"))
        #expect(lines[1].hasSuffix("Ctrl-C returns them to automatic sooner."))
    }

    // MARK: - Why a hold ended

    @Test("Every ending has its own clause")
    func whyEachEnding() throws {
        let hold = Self.hold([try Self.plan(0, .percent(50))])
        let clauses = [
            SetCommand.Ending.durationElapsed, .signal(.interrupt), .signal(.terminate),
            .signal(.hangup), .parentExited, .outputClosed,
        ].map { SetMessages.why($0, hold: hold) }
        #expect(Set(clauses).count == clauses.count)
        #expect(clauses[0] == "the 30m it was asked for has passed")
        #expect(clauses[1] == "SIGINT was received")
        #expect(clauses[2] == "SIGTERM was received")
        #expect(clauses[3] == "SIGHUP was received")
        #expect(clauses[4] == "the process that started it exited")
        #expect(clauses[5] == "standard output was closed")
    }

    @Test("endedBecause values are the documented identifiers")
    func endedBecauseIdentifiers() {
        #expect(SetCommand.Ending.durationElapsed.endedBecause == "durationElapsed")
        #expect(SetCommand.Ending.signal(.hangup).endedBecause == "signal")
        #expect(SetCommand.Ending.parentExited.endedBecause == "parentExited")
        #expect(SetCommand.Ending.outputClosed.endedBecause == "outputClosed")
        #expect(SetCommand.Ending.signal(.hangup).signal == .hangup)
        #expect(SetCommand.Ending.parentExited.signal == nil)
    }

    // MARK: - Exit 8's wording

    private static func settlement(
        _ snapshot: SystemSnapshot?, interruption: (any Error)? = nil,
        verdict: SafeState.Verdict = .notConfirmed
    ) -> SafeState.Settlement {
        SafeState.Settlement(
            verdict: verdict, snapshot: snapshot, polls: 1, interruption: interruption)
    }

    private struct Gone: Error, LocalizedError {
        var errorDescription: String? { "the helper went away" }
    }

    /// An emergency that is active when the check ends is why the fans may still be up, and the
    /// message says the helper's override outranks the hold.
    @Test("A thermal emergency still active at the end is named")
    func emergencyNamed() throws {
        let hold = Self.hold([try Self.plan(0, .percent(50))])
        let snapshot = SystemSnapshot(
            fans: [Fixtures.fan(0, mode: .manualFixed)], sensors: [], activeLease: nil,
            isThermalEmergencyActive: true, capturedAt: Fixtures.captured)

        let message = SetMessages.notConfirmed(
            .durationElapsed, hold: hold, release: .accepted,
            settlement: Self.settlement(snapshot), snapshot: snapshot)

        #expect(message.contains("The helper reports a thermal emergency"))
        #expect(message.contains("Fan 0 (reads manual) is not cleared"))
        #expect(message.contains("within 10 seconds of the release"))
    }

    @Test("A check that could not read says so, and whether the snapshot shown follows the release")
    func unreadable() throws {
        let hold = Self.hold([try Self.plan(0, .percent(50))])
        let snapshot = Fixtures.automatic

        let followed = SetMessages.notConfirmed(
            .signal(.interrupt), hold: hold, release: .failed("no reply"),
            settlement: Self.settlement(snapshot, interruption: Gone()), snapshot: snapshot)
        let unseen = SetMessages.notConfirmed(
            .parentExited, hold: hold, release: .accepted,
            settlement: Self.settlement(nil, interruption: Gone()), snapshot: snapshot)
        let blind = SetMessages.notConfirmed(
            .outputClosed, hold: hold, release: .accepted,
            settlement: Self.settlement(nil, interruption: Gone()), snapshot: nil)

        #expect(followed.contains("The hold ended: SIGINT was received."))
        #expect(followed.contains("The helper did not confirm the release of lease"))
        #expect(followed.contains("no reply"))
        #expect(followed.contains("(the helper went away)"))
        #expect(followed.contains("was read after the release"))
        #expect(unseen.contains("No snapshot was read after the release."))
        #expect(blind.contains("stopped answering"))
        #expect(!blind.contains("not cleared"))
    }

    // MARK: - Exit 6's wording

    @Test("Every loss has a sentence that names what the helper said")
    func lossSentences() throws {
        let hold = Self.hold([try Self.plan(0, .percent(50))])
        let id = hold.leaseID.uuidString
        let other = SetCommand.ListedLease(id: UUID(), holder: "Other 1.0")
        let cases: [(SetCommand.Loss, String)] = [
            (.renewalFailed("refused"), "did not renew lease \(id): refused"),
            (.snapshotFailed("timed out"), "could not be read"),
            (.leaseNotListed(listed: nil), "no longer lists lease \(id). It lists no lease."),
            (.leaseNotListed(listed: other), "a lease held by \"Other 1.0\""),
            (.reclaimed(fan: 3), "fan 3 reclaimed by the system"),
            (.thermalEmergency, "thermal emergency"),
            (.fanNotReported(2), "no longer reports fan 2"),
        ]
        for (loss, expected) in cases {
            let message = SetMessages.lost(loss, hold: hold, release: .accepted)
            #expect(message.hasPrefix("Control was lost: "), "\(loss)")
            #expect(message.contains(expected), "\(loss): \(message)")
            #expect(message.contains("never re-acquires"))
            #expect(message.contains("Nothing is held by this process now."))
            #expect(!message.contains("now reports"), "a loss never says the fans are fine")
        }
    }

    // MARK: - The closing shapes

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
        let hold = Self.hold([try Self.plan(0, .percent(50)), try Self.plan(7, .rpm(2000))])
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
        #expect(report.facts.endedBecause == nil)
    }

    // MARK: - Terminal

    @Test("A terminal made from a plain sink always delivers")
    func plainSinkDelivers() {
        let terminal = Terminal { _, _ in }
        #expect(terminal.deliver("x"))
    }
}
