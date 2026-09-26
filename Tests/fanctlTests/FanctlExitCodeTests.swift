import AeolusXPC
import AeolusXPCClient
import ArgumentParser
import FanKit
import Foundation
import Testing

@testable import fanctl

/// The exit-code table: every case of every error a helper verb can throw, in both phases,
/// and the documentation that promises the same numbers.
@Suite("fanctl's helper-command exit codes")
struct FanctlExitCodeTests {

    // MARK: - The numbers themselves

    /// Literal numbers, because comparing the enum to itself would pass any renumbering — and
    /// renumbering is exactly what a caller branching on these cannot survive.
    @Test("The table's numbers are the documented ones")
    func theNumbersAreStable() {
        let table: [FanctlExitCode: Int32] = [
            .success: 0, .failure: 1, .requestDoesNotFit: 2, .helperNotReachable: 3,
            .manualControlRefused: 4, .heldByAnotherClient: 5, .controlLost: 6,
            .protocolVersionMismatch: 7, .safeStateNotConfirmed: 8, .usage: 64,
        ]
        #expect(table.count == FanctlExitCode.allCases.count)
        for code in FanctlExitCode.allCases {
            #expect(code.rawValue == table[code], "\(code) moved")
        }
        #expect(FanctlExitCode.usage.exitCode == .validationFailure)
    }

    @Test("No two codes share a number or a kind")
    func codesAreDistinct() {
        let all = FanctlExitCode.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(Set(all.map(\.kind)).count == all.count)
    }

    /// `docs/CLI.md` is what a script author reads; it must list every code with its number.
    @Test("docs/CLI.md documents every code")
    func theDocumentationListsEveryCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(
            contentsOf: root.appendingPathComponent("docs/CLI.md"), encoding: .utf8)
        for code in FanctlExitCode.allCases {
            #expect(
                document.contains("| \(code.rawValue) | `\(code.kind)` |"),
                "docs/CLI.md does not list exit code \(code.rawValue) as `\(code.kind)`")
        }
    }

    // MARK: - HelperClientError, every case

    private static let clientErrors: [(HelperClientError, FanctlExitCode)] = [
        (.clientCannotVerifyHelper(.runningProcessHasNoTeamIdentifier), .helperNotReachable),
        (.helperUnreachable(code: 4099), .helperNotReachable),
        (.helperSignatureRejected, .helperNotReachable),
        (.helperRestarted, .failure),
        (.helperNeverAnswered(after: .seconds(5)), .failure),
        (.replyNotDelivered, .failure),
        (.protocolViolation(detail: "x"), .failure),
    ]

    @Test("Every HelperClientError maps to its code before control")
    func clientErrorsBeforeControl() {
        for (error, expected) in Self.clientErrors {
            let failure = HelperCommandFailure(classifying: error, during: .beforeControl)
            #expect(failure.code == expected, "\(error)")
            #expect(failure.message == error.errorDescription)
        }
    }

    // MARK: - AeolusXPCFault, every case

    private static let faults: [(AeolusXPCFault, FanctlExitCode)] = [
        (.handshakeRequired, .failure),
        (
            .versionMismatch(
                clientVersion: 1, helperRange: ProtocolVersionRange(minimumSupported: 2, current: 2)
            ),
            .protocolVersionMismatch
        ),
        (.malformedPayload(detail: "x"), .failure),
        (.invalidParameter(name: "fanIndices", detail: "x"), .requestDoesNotFit),
        (.manualControlUnavailable(reason: .writePathNotBuilt), .manualControlRefused),
        (.manualControlUnavailable(reason: .foreignManualControl), .manualControlRefused),
        (.manualControlUnavailable(reason: .leaseHeldByAnotherClient), .heldByAnotherClient),
        (.leaseExpired, .controlLost),
        (.leaseUnknown, .controlLost),
        (.leaseNotHeldByThisConnection, .controlLost),
        (.thermalEmergencyActive, .manualControlRefused),
        (.reclaimedBySystem, .manualControlRefused),
        (.boundsImplausible(fanIndex: 0, detail: "x"), .manualControlRefused),
        (.helperFailed(detail: "x"), .failure),
        (.unknown(code: "fromTheFuture", detail: nil), .failure),
    ]

    @Test("Every AeolusXPCFault maps to its code before control")
    func faultsBeforeControl() {
        for (fault, expected) in Self.faults {
            let failure = HelperCommandFailure(classifying: fault, during: .beforeControl)
            #expect(failure.code == expected, "\(fault)")
            #expect(failure.message == fault.errorDescription)
        }
    }

    /// Once a lease is held, any failure to keep it means this client can no longer say it
    /// holds the fans — rule 6 — so every error is `controlLost`.
    @Test("While holding a lease, every helper error is control lost")
    func everythingWhileHoldingIsControlLost() {
        for (error, _) in Self.clientErrors {
            #expect(
                HelperCommandFailure(classifying: error, during: .holdingControl).code
                    == .controlLost, "\(error)")
        }
        for (fault, _) in Self.faults {
            #expect(
                HelperCommandFailure(classifying: fault, during: .holdingControl).code
                    == .controlLost, "\(fault)")
        }
    }

    @Test("An error nobody anticipated is exit 1 with its own words")
    func anUnanticipatedErrorIsFailure() {
        let failure = HelperCommandFailure(classifying: CancellationError(), during: .beforeControl)
        #expect(failure.code == .failure)
        #expect(!failure.message.isEmpty)
    }

    @Test("A failure already classified passes through unchanged")
    func aClassifiedFailurePassesThrough() {
        let original = HelperCommandFailure(.requestDoesNotFit, "no fan 9")
        #expect(HelperCommandFailure(classifying: original, during: .holdingControl) == original)
    }

    // MARK: - Leaving

    @Test("fail() writes to stderr, a failure document under --json, and throws the code")
    func failWritesAndThrows() throws {
        let output = RecordingOutput()
        let failure = HelperCommandFailure(.heldByAnotherClient, "held by Aeolus.app")
        #expect(throws: ExitCode(5)) {
            try HelperCommandOutput.fail(failure, as: .document, on: output.terminal)
        }
        #expect(output.standardError == "held by Aeolus.app")
        let object = try JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))
        let document = try #require(object as? [String: Any])
        let body = try #require(document["failure"] as? [String: Any])
        #expect(document["schema"] as? Int == 1)
        #expect(body["exitCode"] as? Int == 5)
        #expect(body["kind"] as? String == "heldByAnotherClient")
    }

    @Test("fail() in text mode writes nothing to stdout")
    func failInTextModeLeavesStdoutEmpty() {
        let output = RecordingOutput()
        #expect(throws: ExitCode(3)) {
            try HelperCommandOutput.fail(
                HelperCommandFailure(.helperNotReachable, "gone"), as: .text, on: output.terminal)
        }
        #expect(output.standardOutput.isEmpty)
    }

    @Test("Helper-authored text loses its control characters and is bounded")
    func displayTextIsSanitised() {
        #expect(DisplayText.sanitised("fan\u{202E}ctl\nDENIED") == "fanctlDENIED")
        #expect(DisplayText.sanitised("\u{0}\u{7}") == "(unprintable)")
        let long = String(repeating: "a", count: 500)
        #expect(DisplayText.sanitised(long).count == DisplayText.maxLength)
    }
}
