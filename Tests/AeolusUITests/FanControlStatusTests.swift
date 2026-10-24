import AeolusXPC
import AeolusXPCClient
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// The line beneath the control: `lost` and `refused` as past events, the emergency named only
/// from a flag that is set, and every string the helper wrote cleaned before it is shown.
@Suite("FanControlPresentation — lost and refused are past events, and helper text is cleaned")
struct FanControlStatusTests {

    typealias Fixtures = FanControlFixtures
    typealias Support = SnapshotTestSupport
    typealias StatusLine = FanControlPresentation.StatusLine

    /// The line for `driver` on the screen a past event is usually read on: a licensed snapshot
    /// with fan 0 cleared, no lease listed and **no emergency flag**, as after § 3's latch has
    /// released (#476 NB3).
    static func line(for driver: LeaseDriverState) throws -> StatusLine {
        let screen = Fixtures.screen(
            Support.snapshot(fans: [Fixtures.clearedFan(0)]), driver: driver)
        return try #require(try Fixtures.present(0, on: screen).status, "no line for \(driver)")
    }

    static func loss(_ cause: LeaseLoss.Cause, afterWake: Bool = false) -> LeaseDriverState {
        .lost(LeaseLoss(lease: Fixtures.ours, cause: cause, afterWake: afterWake))
    }

    static func whole(_ line: StatusLine) -> String {
        line.text + " " + (line.detail ?? "")
    }

    // MARK: - Past events

    /// **Mutation (P1):** in `LeaseEventText.lost`, drop the `afterWake` branch. Run: red at the
    /// `afterWake: true` expectations. **Mutation (P2):** drop the `.acquireUnanswered` branch.
    /// Run: red for that argument.
    @Test(
        "A lost lease says control ended, whatever ended it", arguments: Fixtures.CauseTag.allCases)
    func aLossIsAPastEvent(_ tag: Fixtures.CauseTag) throws {
        for cause in tag.causes {
            for afterWake in [false, true] {
                let line = try Self.line(for: Self.loss(cause, afterWake: afterWake))
                let expected: String
                switch tag {
                case .acquireUnanswered:
                    expected = "Control could not be shown to have begun."
                case .renewal, .apply, .snapshot, .connection, .heartbeatFailed:
                    expected = afterWake ? "Control ended across sleep." : "Control ended."
                }
                #expect(line.text == expected, "\(cause), afterWake \(afterWake)")
                #expect(!(line.detail ?? "").isEmpty, "\(cause)")
                for present in ["is held", "is holding", "now held", "still held"] {
                    #expect(!Self.whole(line).lowercased().contains(present), "\(cause)")
                }
            }
        }
    }

    /// A lost lease that the snapshot still lists is not drawn as held: the selection is not
    /// Custom and the control is disabled by the listed lease. `LeaseLoss` carries no target, so
    /// nothing in the driver's state could draw a speed as held.
    @Test("A lost lease is never drawn as held, even while the snapshot still lists it")
    func aLostLeaseIsNeverDrawnAsHeld() throws {
        let driver = Self.loss(.renewal(.failed(.helperRestarted)))
        let snapshot = Support.snapshot(fans: [Fixtures.heldFan(0)], activeLease: Fixtures.ours)
        let presentation = try Fixtures.present(0, on: Fixtures.screen(snapshot, driver: driver))

        #expect(presentation.selection == .unknown)
        #expect(presentation.affordance == .disabled(.heldElsewhere(Fixtures.ours)))
        #expect(presentation.status?.text == "Control ended.")
    }

    /// A refused `.leaseExpired`'s `errorDescription` says "the fans have returned to automatic
    /// control", which is a snapshot's to show.
    ///
    /// **Mutation (ED):** make `LeaseEventText.fault` return
    /// `HelperAuthoredText.sanitised(fault.errorDescription ?? fault.wireCode)`. Run: red at the
    /// "returned to automatic" expectation for `.leaseExpired`, and at the detail's shape for
    /// every argument. **Mutation (PT):** render `.manualControlUnavailable` as the reason's
    /// summary followed by its wire value, which reads as the state now. Run: red for that
    /// argument.
    @Test(
        "A refusal says it was refused, by the helper's own code, and claims no fan state",
        arguments: Fixtures.FaultTag.allCases)
    func aRefusalIsAPastEvent(_ tag: Fixtures.FaultTag) throws {
        let fault = tag.fault(carrying: "detail")
        let line = try Self.line(for: .refused(fault))

        #expect(line.text == "The helper refused the request for control.")
        let detail = try #require(line.detail)
        switch fault {
        case .manualControlUnavailable(let reason):
            #expect(
                detail
                    == "manualControlUnavailable (detail). At the time, that meant: "
                    + reason.userFacingSummary)
        case .unknown:
            #expect(detail == "detail: detail")
        default:
            #expect(detail.hasPrefix(fault.wireCode), "\(detail)")
        }
        #expect(!detail.lowercased().contains("returned to automatic"))
    }

    // MARK: - The emergency, only from a flag that is set

    /// Every cause here has its flag clear, and no failure among them is a helper refusal that
    /// names an emergency.
    ///
    /// **Mutation (EF1):** in `LeaseEventText.cause`'s `.snapshot` arm, also name the emergency
    /// when the loss is `.leaseNotListed(listed: nil)`, which is what § 3's revocation looks like.
    /// **Mutation (EF2):** ignore the flag and always name it. Run, each: red for the snapshot
    /// argument.
    @Test(
        "With the flag clear, a lost lease names no emergency",
        arguments: Fixtures.CauseTag.allCases)
    func aClearFlagNamesNoEmergency(_ tag: Fixtures.CauseTag) throws {
        for cause in tag.causes {
            let line = try Self.line(for: Self.loss(cause))
            #expect(!Self.whole(line).lowercased().contains("emergency"), "\(cause)")
        }
    }

    @Test("A snapshot whose flag is set names the emergency", arguments: Fixtures.LossTag.allCases)
    func aSetFlagNamesTheEmergency(_ tag: Fixtures.LossTag) throws {
        for loss in tag.losses {
            let line = try Self.line(
                for: Self.loss(.snapshot(loss, isThermalEmergencyActive: true)))
            let detail = try #require(line.detail)
            #expect(detail.hasSuffix(" That snapshot reported a thermal emergency."), "\(loss)")
            #expect(line.text == "Control ended.")
        }
    }

    // MARK: - Helper text is cleaned

    /// Every field the helper or another client writes, with a right-to-left override, a newline,
    /// a line separator and more plain text than the sanitiser's cap. Each piece must be exactly
    /// `HelperAuthoredText.sanitised` of what was sent, so a cleaner that strips the same scalars
    /// without the cap is a red too.
    ///
    /// **Mutations (S1–S5):** drop `HelperAuthoredText.sanitised` around (S1) a fault's detail in
    /// `LeaseEventText.fault`, (S2) `HelperFailure.other`, (S3) the holder in
    /// `.leaseNotListed(listed:)`, (S4) a client error's description, (S5) an `unknown` fault's
    /// code. **Mutations (SV3a, SV3b):** replace every `HelperAuthoredText.sanitised` in
    /// `LeaseEventText.fault` (SV3a), or in `failure` and `snapshot` (SV3b), with a strip of the
    /// same scalars that does not cap. Run, each: red at its states.
    @Test("Every string the helper wrote is shown exactly as the sanitiser leaves it")
    func everyHelperStringIsCleaned() throws {
        #expect(Fixtures.cleanedLong.count == HelperAuthoredText.maxLength, "over the cap")
        let expected = try Self.cleanedDetails()
        let carrying = Fixtures.FaultTag.allCases.filter(\.carriesText)
        #expect(
            Set(
                expected.compactMap { state, _ -> Fixtures.FaultTag? in
                    guard case .refused(let fault) = state else { return nil }
                    return Fixtures.FaultTag(fault)
                }) == Set(carrying),
            "every fault that carries text is listed")

        for (state, detail) in expected {
            let line = try Self.line(for: state)
            #expect(line.detail == detail, "\(Fixtures.DriverTag(state))")
            #expect(
                !Self.whole(line).unicodeScalars.contains(where: HelperAuthoredText.isRemoved),
                "\(Fixtures.DriverTag(state))")
        }
    }

    /// Each state carrying `Fixtures.hostileLong` in a helper-authored field, beside the detail it
    /// must show: the fixed words, and each piece as `HelperAuthoredText.sanitised` leaves it.
    static func cleanedDetails() throws -> [(LeaseDriverState, String)] {
        let sent = Fixtures.hostileLong
        let piece = Fixtures.cleanedLong
        let other = Lease(holderDescription: sent, expiresAt: Date())
        let violation = HelperClientError.protocolViolation(detail: sent)
        let violationText = HelperAuthoredText.sanitised(
            try #require(violation.errorDescription))
        let summary = ManualControlAvailability.Reason.unknown(sent).userFacingSummary

        return [
            (.refused(.malformedPayload(detail: sent)), "malformedPayload: \(piece)"),
            (
                .refused(.invalidParameter(name: sent, detail: sent)),
                "invalidParameter \(piece): \(piece)"
            ),
            (
                .refused(.manualControlUnavailable(reason: .unknown(sent))),
                "manualControlUnavailable (\(piece)). At the time, that meant: \(summary)"
            ),
            (
                .refused(.boundsImplausible(fanIndex: 0, detail: sent)),
                "boundsImplausible, fan 0: \(piece)"
            ),
            (.refused(.helperFailed(detail: sent)), "helperFailed: \(piece)"),
            (.refused(.unknown(code: sent, detail: sent)), "\(piece): \(piece)"),
            (Self.loss(.renewal(.other(sent))), "A renewal failed: \(piece)"),
            (
                Self.loss(.apply(.failed(violation))),
                "A speed change went unanswered. \(violationText)"
            ),
            (
                Self.loss(.acquireUnanswered(.refused(.helperFailed(detail: sent)))),
                "The request for control was refused: helperFailed: \(piece)"
            ),
            (
                Self.loss(
                    .snapshot(.leaseNotListed(listed: other), isThermalEmergencyActive: false)),
                "The helper's snapshot listed another lease instead, held by “\(piece)”."
            ),
        ]
    }

    // MARK: - What each cause says

    /// What the connection did, in the past tense, with the state's name beside it. Not the pane's
    /// sentences, which describe the connection now: a replacement connection reports `.idle`, and
    /// the pane's "has not connected to its helper yet" is false after a lease was held.
    ///
    /// **Mutation (CN):** render the cause with
    /// `ControlSourceDisplay.explanation(.helperConnection(health))`. Run: red for every argument.
    @Test(
        "A connection that changed says what it did then, by its state's name",
        arguments: HealthTag.all)
    func aConnectionLossSaysWhatHappened(_ health: HelperConnectionHealth) throws {
        let line = try Self.line(for: Self.loss(.connection(health)))

        let expected: String
        switch HealthTag(health) {
        case .idle: expected = "The connection to the helper reported no handshake (idle)."
        case .handshaken:
            expected = "The connection to the helper reported a handshake (handshaken)."
        case .unresponsive: expected = "The helper stopped answering (unresponsive)."
        case .interrupted: expected = "The helper process went away (interrupted)."
        case .invalidated: expected = "The connection to the helper ended (invalidated)."
        case .refused: expected = "Aeolus and the helper would not agree to talk (refused)."
        case .versionMismatched:
            expected =
                "This copy of Aeolus and the helper did not share a protocol version "
                + "(versionMismatched)."
        }
        #expect(line.detail == expected)
        #expect(!(line.detail ?? "").contains(" yet"))
    }

    @Test("Each loss a snapshot found says what that snapshot showed")
    func eachSnapshotLossSaysWhatItShowed() throws {
        let expected: [(ControlLoss, String)] = [
            (.leaseNotListed(listed: nil), "The helper's snapshot no longer listed this lease."),
            (
                .leaseNotListed(listed: Fixtures.theirs),
                "The helper's snapshot listed another lease instead, held by “fanctl 0.3.0”."
            ),
            (
                .thermalEmergency,
                "The helper's snapshot still listed this lease, but no longer showed it in control."
            ),
            (.fanNotReported(fan: 1), "The helper's snapshot did not report fan 1."),
            (.reclaimedBySystem(fan: 1), "The helper reported fan 1 reclaimed by the system."),
            (.fanNotHeld(fan: 1), "The helper's snapshot did not show fan 1 held."),
        ]
        #expect(
            Set(expected.map { Fixtures.LossTag($0.0) }) == Set(Fixtures.LossTag.allCases),
            "every kind of loss is listed")

        for (loss, sentence) in expected {
            let line = try Self.line(
                for: Self.loss(.snapshot(loss, isThermalEmergencyActive: false)))
            #expect(line.detail == sentence)
        }
    }

    @Test("A failed verb says whether it was refused, went unanswered or failed")
    func aFailedVerbSaysHow() throws {
        let refused = try Self.line(for: Self.loss(.renewal(.refused(.leaseUnknown))))
        #expect(refused.detail == "A renewal was refused: leaseUnknown")

        let unanswered = try Self.line(for: Self.loss(.apply(.failed(.helperRestarted))))
        let description = try #require(HelperClientError.helperRestarted.errorDescription)
        #expect(
            unanswered.detail
                == "A speed change went unanswered. " + HelperAuthoredText.sanitised(description))

        let failed = try Self.line(for: Self.loss(.acquireUnanswered(.other("the disk is full"))))
        #expect(failed.detail == "The request for control failed: the disk is full")

        let heartbeat = try Self.line(for: Self.loss(.heartbeatFailed))
        #expect(heartbeat.detail == "The lease could no longer be renewed on schedule.")
    }

    // MARK: - While the driver is busy

    @Test("Asking, applying and releasing each say so, and only over the fans they concern")
    func theDriverSaysWhatItIsDoing() throws {
        let screen = { (driver: LeaseDriverState) in
            Fixtures.screen(
                Support.snapshot(fans: [Fixtures.clearedFan(0), Fixtures.clearedFan(1)]),
                driver: driver)
        }

        #expect(
            try Fixtures.present(0, on: screen(.acquiring(fans: [0]))).status
                == StatusLine(text: "Asking the helper for control.", detail: nil))
        #expect(try Fixtures.present(1, on: screen(.acquiring(fans: [0]))).status == nil)
        #expect(
            try Fixtures.present(1, on: screen(.releasing)).status
                == StatusLine(
                    text: "Releasing the lease. The helper has not answered yet.", detail: nil))
        #expect(try Fixtures.present(0, on: screen(.idle)).status == nil)
        #expect(try Fixtures.present(0, on: screen(.released)).status == nil)
    }
}
