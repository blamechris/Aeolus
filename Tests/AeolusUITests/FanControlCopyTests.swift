import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The copy #153's addendum settles for PR 6b, on its exact strings, and the generation check
/// under every driver state.
@Suite("FanControlPresentation — the addendum's copy, and one snapshot under every driver state")
struct FanControlCopyTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias Reason = ManualControlAvailability.Reason

    static let everyReason = FanRowModelTests.Tag.allCases.map(\.reason)

    // MARK: - A refusal, in the past tense

    /// Words that state the machine as it is now. None may follow "the helper refused".
    static let presentTense = [
        "right now", "currently", " yet", "still", " just ", " is ", " are ", " has ", " have ",
        " knows", " believes",
    ]

    /// **Mutation (PT2, "the summary as it stands"):** make `pastTenseSummary` return
    /// `userFacingSummary`. Run: red at the present-tense words for `.writePathNotBuilt`,
    /// `.reclaimedBySystem`, `.releaseInProgress`, `.systemSleeping` and `.noThermalTelemetry`
    /// among others, and at the inequality for every reason but `.unknown`, whose summary is
    /// about this build and is already true of the past.
    @Test("Every refused reason is said as what happened", arguments: everyReason)
    func everyReasonIsSaidInThePast(_ reason: Reason) {
        let sentence = reason.pastTenseSummary

        #expect(!sentence.isEmpty)
        for word in Self.presentTense {
            #expect(!sentence.lowercased().contains(word), "\(reason): \"\(word)\"")
        }
        if case .unknown = reason { return }
        #expect(sentence != reason.userFacingSummary, "\(reason)")
    }

    /// Every reason's sentence, word for word, so a sentence swapped for another reason's, or
    /// replaced, is a red (#497's review, test gap 4). One row per tag, and the tag's switch has no
    /// `default:`, so a reason added later does not compile here until it has a row.
    ///
    /// **Mutations (O7a, O7b):** give `.reclaimedBySystem` `.foreignManualControl`'s sentence; make
    /// `.foreignManualControl`'s "x.". Run, each: red at its own argument.
    @Test(
        "Every refused reason's sentence, word for word", arguments: FanRowModelTests.Tag.allCases)
    func everySentenceWordForWord(_ tag: FanRowModelTests.Tag) {
        let expected: String
        switch tag {
        case .writePathNotBuilt:
            expected =
                "The helper's build had no path to write to the SMC, so manual control was not "
                + "available for any fan."
        case .boundsImplausible:
            expected =
                "A fan's firmware speed bounds did not pass a plausibility check, so there was no "
                + "safe range to control it within."
        case .reclaimedBySystem:
            expected = "The system had taken a fan back from manual control."
        case .leaseHeldByAnotherClient:
            expected =
                "Another Aeolus client held the manual-control lease that taking a fan required."
        case .selfRenewalNotBuilt:
            expected =
                "A self-renewing lease was requested, and the helper's build did not implement one."
        case .releaseInProgress:
            expected =
                "A fan was mid-handback: a previous lease had ended and the write that returns it "
                + "to automatic control had not completed, or a restore of every fan at once was "
                + "running (`fanctl reset --all`, `fanctl auto`, or the handback before the Mac "
                + "sleeps)."
        case .handbackUnconfirmed:
            expected =
                "Aeolus had asked for a fan back and stopped waiting before an answer arrived, so "
                + "it did not know what mode the fan was in."
        case .restoreToAutomaticUnconfirmed:
            expected =
                "Aeolus had issued a restore-to-automatic write for a fan and had not confirmed "
                + "the fan back under automatic control; whether the write was accepted was not "
                + "known."
        case .restoreToAutomaticFailed:
            expected =
                "Aeolus had tried to hand a fan back to automatic control and the firmware never "
                + "took the write, so Aeolus did not know what mode the fan was in."
        case .systemSleeping:
            expected =
                "The machine was going to sleep (or Aeolus believed it was), and every fan had "
                + "been handed back to automatic control for the duration."
        case .noThermalTelemetry:
            expected =
                "Aeolus could not read a critical temperature, so it could not safely watch a fan "
                + "under manual control."
        case .supervisorBlind:
            expected =
                "Aeolus could not confirm a fan's own control state: a read of it failed, or "
                + "start-up could not confirm it back under automatic control."
        case .foreignManualControl:
            expected = "Something other than Aeolus had put a fan under manual control."
        case .unknown:
            expected =
                "The helper refused manual control for a reason this build does not recognise."
        }
        #expect(tag.reason.pastTenseSummary == expected)
    }

    /// A release the helper did not confirm is a loss, said as one (#497's review, C1).
    ///
    /// **Mutation (RU, "a release unconfirmed says nothing"):** in `LeaseEventText.cause`, render
    /// `.releaseUnconfirmed` as `"Control ended."`. Run: red at every detail.
    @Test("An unconfirmed release says the helper did not confirm it, and how")
    func anUnconfirmedReleaseSaysSo() throws {
        let description = try #require(HelperClientError.helperRestarted.errorDescription)
        let cases: [(HelperFailure, String)] = [
            (
                .refused(.leaseExpired),
                "The helper did not confirm the release: the request was refused: leaseExpired"
            ),
            (
                .failed(.helperRestarted),
                "The helper did not confirm the release: the request went unanswered. "
                    + HelperAuthoredText.sanitised(description)
            ),
            (
                .other("the disk is full"),
                "The helper did not confirm the release: the request failed: the disk is full"
            ),
        ]
        for (failure, detail) in cases {
            let line = try FanControlStatusTests.line(
                for: FanControlStatusTests.loss(.releaseUnconfirmed(failure)))
            #expect(line.text == "Control ended.", "\(failure)")
            #expect(line.detail == detail, "\(failure)")
        }
    }

    /// Today's reason, word for word: what a refused take would say on a helper with no write
    /// plane.
    @Test("A refused take on today's helper says what the helper's build lacked")
    func todaysRefusalWordForWord() throws {
        let line = try FanControlStatusTests.line(
            for: .refused(.manualControlUnavailable(reason: .writePathNotBuilt)))

        #expect(line.text == "The helper refused the request for control.")
        #expect(
            line.detail
                == "The helper's build had no path to write to the SMC, so manual control was "
                + "not available for any fan. (manualControlUnavailable: writePathNotBuilt)")
    }

    /// The wire code is a detail after the sentence, never the line's first word.
    ///
    /// **Mutation (WC, "the wire code first"):** in `LeaseEventText.fault`, put
    /// `fault.wireCode + " (" + wire + "). "` ahead of the sentence. Run: red at the prefix for
    /// every argument.
    @Test("A refusal never leads with its wire code", arguments: everyReason)
    func aRefusalDoesNotLeadWithItsCode(_ reason: Reason) throws {
        let detail = try #require(
            try FanControlStatusTests.line(for: .refused(.manualControlUnavailable(reason: reason)))
                .detail)

        #expect(!detail.hasPrefix("manualControlUnavailable"))
        #expect(detail.hasPrefix(reason.pastTenseSummary))
        #expect(
            detail.hasSuffix(
                " (manualControlUnavailable: "
                    + HelperAuthoredText.sanitised(reason.wireValue) + ")"))
    }

    /// A renewal refused for a reason says it the same way, after the verb.
    @Test("A renewal refused for a reason says the reason in the past")
    func aRenewalRefusedForAReason() throws {
        let line = try FanControlStatusTests.line(
            for: FanControlStatusTests.loss(
                .renewal(.refused(.manualControlUnavailable(reason: .noThermalTelemetry)))))

        #expect(
            line.detail
                == "A renewal was refused: Aeolus could not read a critical temperature, so it "
                + "could not safely watch a fan under manual control. "
                + "(manualControlUnavailable: noThermalTelemetry)")
    }

    // MARK: - Custom names a held target

    /// **Mutation (CL, "the old Custom line"):** restore "the helper's last snapshot reports M
    /// RPM". Run: red here and in `FanControlSelectionTests.customWhenEverythingHolds`.
    @Test("Custom names the snapshot's figure as a held target, not as a speed")
    func customNamesAHeldTarget() throws {
        let target = try Fixtures.target([0: 3564])
        let screen = Fixtures.screen(
            Support.snapshot(fans: [Fixtures.heldFan(0, target: 3564)], activeLease: Fixtures.ours),
            driver: Fixtures.held(Fixtures.ours, fans: [0], .confirmed(target)))
        let status = try #require(try Fixtures.present(0, on: screen).status)

        #expect(
            status.text
                == "Accepted 3564 RPM; the snapshot on screen reports a held target of 3564 RPM.")
        #expect(status.detail == nil)
    }

    // MARK: - One snapshot at a time, under every driver state

    /// The generation check is the driver's business under no state: a read that pairs two
    /// snapshots is disabled, between snapshots, and claims neither Custom nor Automatic, whatever
    /// the driver is doing. Each argument changes one input only, as in
    /// `FanControlGenerationTests.aReadThatPairsTwoSnapshotsClaimsNothing`, which holds the held
    /// state's own line.
    ///
    /// **Mutation (GD, "the check only while held"):** in `Licence.init`, skip `isOneSnapshot`
    /// unless `inputs.driver.isHeld`. Run: red for every state but `.held`.
    @Test(
        "A read that pairs two snapshots claims nothing, whatever the driver is doing",
        arguments: Fixtures.DriverTag.allCases, FanControlGenerationTests.Mismatch.allCases)
    func aMixedReadClaimsNothingUnderEveryState(
        _ tag: Fixtures.DriverTag, _ mismatch: FanControlGenerationTests.Mismatch
    ) throws {
        let driver = try tag.state()
        let older = Support.snapshot(fans: [Fixtures.clearedFan(0)], activeLease: Fixtures.ours)
        var lease = Fixtures.ours as Lease?
        var emergency = ThermalEmergencyState.inactive
        var rows = SnapshotReadings.fans(in: older)
        switch mismatch {
        case .lease:
            lease = nil
        case .fanState:
            rows = SnapshotReadings.fans(in: Support.snapshot(fans: [Fixtures.heldFan(0)]))
        case .emergency:
            emergency = .active
        }
        let mixed = Fixtures.Screen(
            inputs: FanControlPresentation.Inputs(
                controlSource: .helperSnapshot(activeLease: lease), thermalEmergency: emergency,
                renderedSnapshot: older, driver: driver),
            rows: rows)
        let presentation = try Fixtures.present(0, on: mixed)

        #expect(presentation.affordance == .disabled(.betweenSnapshots))
        switch tag {
        case .held:
            #expect(presentation.selection == .checking)
        case .idle, .acquiring, .releasing, .released, .lost, .refused:
            #expect(presentation.selection == .unknown)
        }
    }
}
