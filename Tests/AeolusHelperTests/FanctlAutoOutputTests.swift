import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl auto`'s other exits and its output surface, end to end: the runs that read no
/// snapshot (3, 7), the `--json` document, what no failure may claim, and the teardown.
/// The flow suite is `FanctlAutoTests`, whose `run` this one shares.
@Suite("fanctl auto: no snapshot, --json, and what it may claim")
struct FanctlAutoOutputTests {

    private static func run(
        _ arguments: [String] = [], over harness: ClientListenerHarness,
        realClock: Bool = false
    ) async throws -> FanctlAutoTests.Run {
        try await FanctlAutoTests.run(arguments, over: harness, realClock: realClock)
    }

    private static func json(_ run: FanctlAutoTests.Run) throws -> [String: Any] {
        try FanctlAutoTests.json(run)
    }

    // MARK: - 7 and 3: no snapshot

    /// A version mismatch cannot be verified across, but the one message that is exempt from
    /// the version gate is still sent, once — a fence that stopped the way back to automatic
    /// control would defeat its own purpose.
    ///
    /// **Mutation:** skip the `restoreAllToAutomatic()` call on a version mismatch in
    /// `AutoCommand.perform`. Run: red — no restore reaches the helper.
    @Test("A version mismatch still sends the exempt restore once, then exits 7")
    func versionMismatchSendsTheExemptRestore() async throws {
        let future = ProtocolVersionRange(
            minimumSupported: AeolusXPCVersion.current + 1,
            current: AeolusXPCVersion.current + 1)
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority, helperRange: future)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.protocolVersionMismatch.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 0)
        #expect(run.output.standardOutput.isEmpty)
        let diagnosis = run.output.standardError
        #expect(diagnosis.contains("speaks version \(AeolusXPCVersion.current)"))
        #expect(diagnosis.contains("accepted the request"))
        #expect(diagnosis.contains("cannot verify the result"))
    }

    @Test("A version mismatch under --json is a failure document")
    func versionMismatchJSON() async throws {
        let future = ProtocolVersionRange(
            minimumSupported: AeolusXPCVersion.current + 1,
            current: AeolusXPCVersion.current + 1)
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority, helperRange: future)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == 7)
        let document = try Self.json(run)
        #expect(Set(document.keys) == ["schema", "failure"])
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(failure["exitCode"] as? Int == 7)
        #expect(failure["kind"] as? String == "protocolVersionMismatch")
        #expect((failure["message"] as? String)?.contains("cannot verify the result") == true)
        #expect(await authority.restoreRequests == 1)
    }

    @Test("A helper that cannot be reached exits 3 and sends nothing")
    func unreachableExitsThree() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        harness.isAdmitting = false

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.helperNotReachable.rawValue)
        #expect(run.output.standardOutput.isEmpty)
        #expect(run.output.standardError.contains("not installed"))
        #expect(await authority.calls.isEmpty)
        #expect(harness.sessions.isEmpty)
    }

    /// Only a version mismatch sends the exempt restore: it is the one case where the peer is
    /// known to be the helper and the request is known to be accepted. A reply this client
    /// cannot read identifies nothing, and a write request is not sent to it.
    ///
    /// **Mutation:** in `AutoCommand.unreadable`, send the restore for every failure (change
    /// the guard to `failure.code != .success`). Run: red — a restore reaches the authority.
    @Test("A handshake reply this client cannot read exits 1 and sends nothing")
    func anUnreadableHandshakeSendsNothing() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority, garblingHandshakeReplies: true)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.failure.rawValue)
        #expect(await authority.restoreRequests == 0)
        #expect(await authority.snapshotsServed == 0)
        #expect(run.output.standardOutput.isEmpty)
        // Nothing was sent, so the way out that needs no handshake is named.
        #expect(run.output.standardError.contains("`fanctl reset --all`"))
    }

    @Test("An unreachable helper under --json prints a failure document with no fans in it")
    func unreachableJSON() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        harness.isAdmitting = false

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == 3)
        let document = try Self.json(run)
        #expect(Set(document.keys) == ["schema", "failure"])
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "helperNotReachable")
        #expect(harness.sessions.isEmpty)
    }

    // MARK: - JSON

    @Test("--json prints one document with every key, null where absent")
    func jsonWhenAlreadyAutomatic() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == nil)
        #expect(run.output.lines.count == 1, "one document, nothing else on either stream")
        let document = try Self.json(run)
        #expect(
            Set(document.keys)
                == [
                    "schema", "capturedAt", "restoreRequested", "snapshotFollowsRestore",
                    "endedLease", "lease", "fans", "failure",
                ])
        #expect(document["capturedAt"] is String)
        #expect(document["restoreRequested"] as? Bool == false)
        #expect(document["snapshotFollowsRestore"] as? Bool == false)
        #expect(document["endedLease"] is NSNull)
        #expect(document["lease"] is NSNull)
        #expect(document["failure"] is NSNull)
        #expect((document["fans"] as? [Any])?.count == 2)
        _ = harness.sessions
    }

    @Test("--json after a restore names the ended lease and carries no failure")
    func jsonWhenSettled() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == nil)
        let document = try Self.json(run)
        #expect(document["restoreRequested"] as? Bool == true)
        #expect(document["snapshotFollowsRestore"] as? Bool == true)
        let ended = try #require(document["endedLease"] as? [String: Any])
        #expect(ended["holderDescription"] as? String == "Aeolus.app 0.3.0")
        #expect(document["lease"] is NSNull)
        #expect(document["failure"] is NSNull)
        let fans = try #require(document["fans"] as? [[String: Any]])
        #expect(fans.allSatisfy { $0["mode"] as? String == "automatic" })
    }

    /// A non-zero exit after a snapshot still carries the fans it was read from, and the
    /// failure object matches what went to standard error.
    @Test("--json on an exit 8 carries fans and the failure, and the message is the stderr one")
    func jsonWhenNotConfirmed() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1_000)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == 8)
        let document = try Self.json(run)
        #expect(document["restoreRequested"] as? Bool == true)
        let fans = try #require(document["fans"] as? [[String: Any]])
        #expect(fans.first?["mode"] as? String == "manualFixed")
        let failure = try #require(document["failure"] as? [String: Any])
        #expect(failure["exitCode"] as? Int == 8)
        #expect(failure["kind"] as? String == "safeStateNotConfirmed")
        #expect(failure["message"] as? String == run.output.standardError)
    }

    @Test("--json on an exit 9 is kind cannotReturnToAutomatic")
    func jsonWhenPinned() async throws {
        let authority = SimulatedFanAuthority()
        await authority.markForeignManual(0)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(["--json"], over: harness)

        #expect(run.code == 9)
        let failure = try #require(try Self.json(run)["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic")
        #expect(failure["exitCode"] as? Int == 9)
    }

    // MARK: - Honesty

    /// Rule 6: no run that did not end in the safe state says it did, on either stream.
    @Test("No non-zero run claims the fans are automatic")
    func noFailureClaimsSuccess() async throws {
        var runs: [(String, FanctlAutoTests.Run)] = []

        let stranded = SimulatedFanAuthority()
        await stranded.strandManual(0)
        await stranded.settling(afterSnapshots: 1_000)
        runs.append(
            ("8", try await Self.run(over: ClientListenerHarness(authority: stranded))))

        let pinned = SimulatedFanAuthority()
        await pinned.markForeignManual(0)
        runs.append(("9", try await Self.run(over: ClientListenerHarness(authority: pinned))))

        let leased = SimulatedFanAuthority()
        await leased.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await leased.reacquiring(as: "Other 1.0")
        runs.append(("5", try await Self.run(over: ClientListenerHarness(authority: leased))))

        for (name, run) in runs {
            #expect(run.code != nil, "exit \(name) returned normally")
            let everything = run.output.standardOutput + "\n" + run.output.standardError
            for claim in ["now reports", "reports every fan automatic", "restored", "back under"] {
                #expect(!everything.contains(claim), "exit \(name) claimed \"\(claim)\"")
            }
        }
    }

    // MARK: - Teardown and time

    /// **Mutation:** delete `await client.disconnect()` from `Fanctl.Auto.run()`. Run: red —
    /// the authority is never told the connection went away.
    @Test("run() gives the connection back")
    func disconnects() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)
        #expect(run.code == nil)

        try await waitUntil("the helper was told the connection went away") {
            await authority.calls.contains("connectionDidInvalidate")
        }
    }

    /// The default clock really waits. The virtual one used everywhere else cannot show it.
    ///
    /// **Mutation:** make `SettleClock.production`'s `sleep` return at once. Run: red — it
    /// takes microseconds instead of a second.
    @Test("With no clock injected, a poll waits a real second")
    func theDefaultClockWaits() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1)
        let harness = ClientListenerHarness(authority: authority)

        let started = ContinuousClock.now
        let run = try await Self.run(over: harness, realClock: true)
        let elapsed = ContinuousClock.now - started

        #expect(run.code == nil)
        #expect(await authority.snapshotsServed == 3)
        #expect(elapsed >= .milliseconds(900), "waited \(elapsed)")
    }
}
