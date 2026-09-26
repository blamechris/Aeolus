import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl status`, end to end: the shipping `run()`, the real `HelperClient`, a real
/// `NSXPCListener` and the real `HelperConnectionSession` behind it. Only the authority is a
/// double — `SimulatedFanAuthority` — and only where to look and where to write are
/// substituted on the command.
///
/// What none of it proves is that a **signed** `fanctl` is admitted by an **installed**
/// helper; that is blocked on #82 exactly as `FanctlResetTests` records.
@Suite("fanctl status against a real helper session")
struct FanctlStatusTests {

    private static func status(_ arguments: [String] = []) throws -> Fanctl.Status {
        try #require(Fanctl.parseAsRoot(["status"] + arguments) as? Fanctl.Status)
    }

    private static func run(
        _ arguments: [String] = [], over harness: ClientListenerHarness
    ) async throws -> (code: Int32?, output: RecordingTerminal) {
        let output = RecordingTerminal()
        var command = try status(arguments)
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint),
            pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = output.terminal
        let code = await exitCode { try await command.run() }
        return (code, output)
    }

    @Test("status handshakes, reports every fan and the lease, and exits 0")
    func statusReportsTheSnapshot() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        let harness = ClientListenerHarness(authority: authority)

        let (code, output) = try await Self.run(over: harness)

        #expect(code == nil)
        let text = output.standardOutput
        #expect(text.contains("negotiated XPC protocol \(AeolusXPCVersion.current)"))
        #expect(text.contains("Manual-control lease: held by \"Aeolus.app 0.3.0\""))
        #expect(text.contains("Fan 0"))
        #expect(text.contains("mode manualFixed · target 3000 RPM"))
        #expect(text.contains("Fan 1"))
        #expect(text.contains("manual control: available"))
        #expect(output.standardError.isEmpty)

        let session = try #require(harness.sessions.first)
        #expect(await session.handshakeState != nil, "status must handshake")
        try await waitUntil("the helper was told the connection went away") {
            await authority.calls.contains("connectionDidInvalidate")
        }
    }

    @Test("status --json prints one schema-versioned document")
    func statusJSONIsOneDocument() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let (code, output) = try await Self.run(["--json"], over: harness)

        #expect(code == nil)
        let object = try JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))
        let document = try #require(object as? [String: Any])
        #expect(document["schema"] as? Int == 1)
        #expect(document["lease"] is NSNull)
        #expect(document["thermalEmergencyActive"] as? Bool == false)
        let helper = try #require(document["helper"] as? [String: Any])
        #expect(helper["maximumProtocolVersion"] as? Int == AeolusXPCVersion.current)
        let fans = try #require(document["fans"] as? [[String: Any]])
        #expect(fans.count == 2)
        _ = harness.sessions
    }

    /// The shipped helper's answer, rendered honestly: every fan unavailable with its reason.
    @Test("A helper with no write path is reported fan by fan, with the reason")
    func writePathNotBuiltIsReported() async throws {
        let authority = SimulatedFanAuthority(fans: [
            SimulatedFanAuthority.fan(0, availability: .unavailable(.writePathNotBuilt))
        ])
        let harness = ClientListenerHarness(authority: authority)

        let (code, output) = try await Self.run(over: harness)

        #expect(code == nil)
        #expect(output.standardOutput.contains("reason: writePathNotBuilt"))
        #expect(
            output.standardOutput.contains(
                ManualControlAvailability.Reason.writePathNotBuilt.userFacingSummary))
        _ = harness.sessions
    }

    @Test("A refusing helper exits 3, with nothing on stdout in text mode")
    func aRefusingHelperExitsThree() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        harness.isAdmitting = false

        let (code, output) = try await Self.run(over: harness)

        #expect(code == FanctlExitCode.helperNotReachable.rawValue)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError.contains("not installed"))
        #expect(harness.sessions.isEmpty)
    }

    @Test("A refusing helper under --json still prints a failure document")
    func aRefusingHelperUnderJSONPrintsAFailureDocument() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        harness.isAdmitting = false

        let (code, output) = try await Self.run(["--json"], over: harness)

        #expect(code == 3)
        let object = try JSONSerialization.jsonObject(with: Data(output.standardOutput.utf8))
        let document = try #require(object as? [String: Any])
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(document["schema"] as? Int == 1)
        #expect(failure["exitCode"] as? Int == 3)
        #expect(failure["kind"] as? String == "helperNotReachable")
        #expect(harness.sessions.isEmpty)
    }

    /// A helper that accepts no version this client speaks fails loudly, naming both.
    @Test("A version mismatch exits 7 and names both versions")
    func aVersionMismatchExitsSeven() async throws {
        let future = ProtocolVersionRange(
            minimumSupported: AeolusXPCVersion.current + 1,
            current: AeolusXPCVersion.current + 1)
        let harness = ClientListenerHarness(
            authority: SimulatedFanAuthority(), helperRange: future)

        let (code, output) = try await Self.run(over: harness)

        #expect(code == FanctlExitCode.protocolVersionMismatch.rawValue)
        #expect(output.standardError.contains("speaks version \(AeolusXPCVersion.current)"))
        #expect(output.standardError.contains("\(AeolusXPCVersion.current + 1)"))
        _ = harness.sessions
    }
}
