import AeolusXPC
import AeolusXPCClient
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
    typealias Shared = SetFixtures

    // MARK: - Starting

    @Test("One fan reads as one sentence with the way out at its end")
    func oneFan() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(75))])
        let lines = SetMessages.startLines(hold)
        #expect(
            lines == [
                "Holding fan 0 at 75% (4670 RPM target; firmware 1350–5777 RPM) for 30m under "
                    + "lease \(hold.leaseID.uuidString). Ctrl-C returns it to automatic sooner."
            ])
    }

    @Test("An rpm request says target, and several fans share one way out")
    func severalFans() throws {
        let hold = Shared.hold(
            [
                try Shared.plan(0, .rpm(3000)),
                try Shared.plan(1, .percent(0), minimum: 0, maximum: 3000),
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
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
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
        #expect(clauses[5] == "standard output was closed or stopped taking lines")
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

    /// An emergency that is active when the check ends is why the fans may still be up, and the
    /// message says the helper's override outranks the hold.
    @Test("A thermal emergency still active at the end is named")
    func emergencyNamed() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let snapshot = SystemSnapshot(
            fans: [Fixtures.fan(0, mode: .manualFixed)], sensors: [], activeLease: nil,
            isThermalEmergencyActive: true, capturedAt: Fixtures.captured)

        let message = SetMessages.notConfirmed(
            lead: SetMessages.lead(.durationElapsed, hold: hold), hold: hold,
            release: .accepted, settlement: Shared.settlement(snapshot))

        #expect(message.contains("The helper reports a thermal emergency"))
        #expect(message.contains("Fan 0 (reads manual) is not cleared"))
        #expect(message.contains("within 10 seconds of the release"))
    }

    @Test(
        "A check that read some snapshots before it stopped says the one shown follows the release")
    func unreadableAfterSomeReads() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])

        let message = SetMessages.notConfirmed(
            lead: SetMessages.lead(.signal(.interrupt), hold: hold), hold: hold,
            release: .failed("no reply"),
            settlement: Shared.settlement(Fixtures.automatic, interruption: Shared.Gone()))

        #expect(message.contains("The hold ended: SIGINT was received."))
        #expect(message.contains("The helper did not confirm the release of lease"))
        #expect(message.contains("no reply"))
        #expect(message.contains("(the helper went away)"))
        #expect(message.contains("The snapshot shown was read after the release"))
    }

    /// **The review's probe, C2.** The helper accepted the release and then stopped answering, so
    /// no snapshot was read after it. The snapshot the hold last read was taken while the lease
    /// was held: it lists this run's lease and a fan reading manual. None of that is said as
    /// present, and the text says the helper accepted the release, then stopped answering, and
    /// that what the lease and the fans are doing is unknown.
    ///
    /// `notConfirmed` is given the check's own settlement and nothing from the hold, so what it
    /// can say is what the check read. The end-to-end probe, with the hold's snapshot available
    /// to be mistaken for it, is `FanctlSetEndingTests.theCheckCannotRead`.
    ///
    /// **Mutation:** in `SetMessages.notConfirmed`, describe the fans and the lease from
    /// `unknownAfterRelease`'s absence (print `still` lines even when the snapshot is `nil`).
    /// Run: red on the 'is unknown' assertions below.
    @Test("With no snapshot after the release, nothing is presented as current")
    func nothingFromBeforeTheReleaseIsCurrent() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])

        let message = SetMessages.notConfirmed(
            lead: SetMessages.lead(.durationElapsed, hold: hold), hold: hold,
            release: .accepted, settlement: Shared.settlement(nil, interruption: Shared.Gone()))

        #expect(message.contains("The helper accepted the release and then stopped answering"))
        #expect(message.contains("(the helper went away)"))
        #expect(message.contains("is unknown"))
        #expect(message.contains("No snapshot was read after the release"))
        // The old sentences, which described the snapshot from before the release.
        #expect(!message.contains("still listed"))
        #expect(!message.contains("did not end"))
        #expect(!message.contains("not cleared"))
        #expect(!message.contains("reads manual"))
        #expect(!message.contains("thermal emergency"))
    }

    @Test("A release that was not confirmed and then silence says the same, without 'accepted'")
    func unconfirmedReleaseThenSilence() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])

        let message = SetMessages.notConfirmed(
            lead: SetMessages.lead(.parentExited, hold: hold), hold: hold,
            release: .failed("no reply"),
            settlement: Shared.settlement(nil, interruption: Shared.Gone()))

        #expect(!message.contains("accepted the release"))
        #expect(message.contains("The helper did not confirm the release"))
        #expect(message.contains("is unknown"))
    }

    // MARK: - An apply nobody answered

    /// The helper took the lease and the request to apply the speed got no answer: it may have
    /// applied it, and "refused" would be a statement nothing observed.
    ///
    /// **Mutation:** build the unanswered message from `refused`. Run: red.
    @Test("An unanswered apply says it got no answer and may have been applied")
    func unansweredApplyWording() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let failure = HelperCommandFailure(
            classifying: HelperClientError.helperRestarted, during: .beforeControl)

        for verdict in [SafeState.Verdict.automatic, .notConfirmed] {
            let message = SetMessages.unansweredApply(
                failure, hold: hold, release: .accepted,
                settlement: Shared.settlement(Fixtures.automatic, verdict: verdict))
            #expect(message.contains("did not answer the request to apply the speed"))
            #expect(message.contains("may have applied it"))
            #expect(message.contains("The helper accepted the release"))
            #expect(!message.contains("did not accept the speed"))
            #expect(!message.contains("Nothing is held"))
        }
    }

    @Test("An unanswered apply followed by a pinned fan reports the pinned fan")
    func unansweredApplyThenPinned() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let failure = HelperCommandFailure(
            classifying: HelperClientError.replyNotDelivered, during: .beforeControl)
        let pinned = Fixtures.snapshot([
            Fixtures.fan(0), Fixtures.fan(1, availability: .unavailable(.foreignManualControl)),
        ])

        let message = SetMessages.unansweredApply(
            failure, hold: hold, release: .accepted,
            settlement: Shared.settlement(pinned, verdict: .cannotReturn(fans: [1])))

        #expect(message.contains("(reason: foreignManualControl)"))
        #expect(message.contains("may have applied it"))
    }

    /// Only the helper's own fault is an answer. Every transport failure is not, including the
    /// ones that say nothing was sent: after a lease was taken none of them is a refusal.
    ///
    /// **Mutation:** treat `HelperClientError` as an answer in `SetCommand.helperAnswered`. Run:
    /// red.
    @Test("A fault is the helper's answer; every client error is silence")
    func whatCountsAsAnAnswer() {
        let silences: [any Error] = [
            HelperClientError.helperRestarted,
            HelperClientError.helperNeverAnswered(after: .seconds(5)),
            HelperClientError.replyNotDelivered, HelperClientError.protocolViolation(detail: "x"),
            HelperClientError.helperUnreachable(code: 4_099),
            HelperClientError.helperSignatureRejected,
            HelperClientError.clientCannotVerifyHelper(.runningProcessHasNoTeamIdentifier),
            CocoaError(.fileReadUnknown),
        ]
        for error in silences {
            #expect(!SetCommand.helperAnswered(error), "\(error)")
        }
        let answers: [AeolusXPCFault] = [
            .helperFailed(detail: "x"), .leaseExpired, .boundsImplausible(fanIndex: 0, detail: "x"),
            .invalidParameter(name: "x", detail: "y"),
            .manualControlUnavailable(reason: .writePathNotBuilt),
        ]
        for fault in answers {
            #expect(SetCommand.helperAnswered(fault), "\(fault)")
        }
    }

    // MARK: - What a release that did not take leaves

    /// A release the helper did not confirm leaves a lease it may keep listing for up to 30
    /// seconds: "Nothing is held by this process" is only said when the release was accepted.
    ///
    /// **Mutation:** return the accepted sentence for a failed release in
    /// `SetMessages.heldSentence`. Run: red.
    @Test("'Nothing is held' is only said when the release was accepted")
    func heldSentence() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let accepted = SetMessages.lost(.thermalEmergency, hold: hold, release: .accepted)
        let unconfirmed = SetMessages.lost(.thermalEmergency, hold: hold, release: .failed("x"))
        let timer = SetMessages.timerFailed(hold: hold, release: .failed("x"))
        let refused = SetMessages.refused(
            HelperCommandFailure(.manualControlRefused, "no"), hold: hold, release: .failed("x"))

        #expect(accepted.contains("Nothing is held by this process now."))
        for message in [unconfirmed, timer, refused] {
            #expect(!message.contains("Nothing is held"))
            #expect(message.contains("may keep listing the lease for up to 30 seconds"))
        }
    }

    // MARK: - Another client's words

    /// Another client's holder is hostile input to a terminal: a control or formatting
    /// character in it could rewrite the line it appears on.
    ///
    /// **Mutation:** print `$0.holder` unsanitised in `SetMessages.sentence(for:hold:)`. Run: red.
    @Test("A holder with control characters is sanitised where the message prints it")
    func holderIsSanitisedWhenPrinted() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let hostile = SetCommand.ListedLease(id: UUID(), holder: "Evil\u{1B}[2J\u{202E}Corp")

        let message = SetMessages.lost(
            .leaseNotListed(listed: hostile), hold: hold, release: .accepted)

        #expect(message.contains("Evil[2J"), "the readable part of the name survives")
        #expect(!message.unicodeScalars.contains("\u{1B}"))
        #expect(!message.unicodeScalars.contains("\u{202E}"))
    }

    /// **Mutation:** print the holder unsanitised in `listedLease`. Run: red.
    @Test("A listed lease's holder is sanitised in the exit 8 text")
    func listedHolderIsSanitised() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
        let other = Lease(
            holderDescription: "Evil\u{1B}[31mCorp", expiresAt: Fixtures.captured)
        let snapshot = Fixtures.snapshot([Fixtures.fan(0, mode: .manualFixed)], lease: other)

        let message = SetMessages.notConfirmed(
            lead: SetMessages.lead(.durationElapsed, hold: hold), hold: hold,
            release: .accepted, settlement: Shared.settlement(snapshot))

        #expect(message.contains("another client's lease"))
        #expect(!message.unicodeScalars.contains("\u{1B}"))
    }

    // MARK: - Exit 6's wording

    @Test("Every loss has a sentence that names what the helper said")
    func lossSentences() throws {
        let hold = Shared.hold([try Shared.plan(0, .percent(50))])
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
}
