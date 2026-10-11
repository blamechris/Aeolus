import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` when it never holds anything: the request does not fit this machine (2), the
/// helper refuses (4, 5), cannot be reached (3), or speaks another protocol (7). In every case
/// **nothing is sent to a fan**, and the cases that decide that from the snapshot alone (2)
/// acquire nothing at all.
@Suite("fanctl set when it cannot start", .timeLimit(.minutes(1)))
struct FanctlSetRefusalTests {

    typealias Harness = SetHarness

    /// A machine whose fan 1 declares a maximum of 1e14.
    private static func implausibleMachine() -> SimulatedFanAuthority {
        SimulatedFanAuthority(fans: [
            SimulatedFanAuthority.fan(0), SimulatedFanAuthority.fan(1, maximum: 1e14),
        ])
    }

    private static func failed(
        _ run: Harness.Run, kind: String, exit: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String: Any] {
        let events = try run.output.events()
        #expect(
            events.map { $0["event"] as? String } == ["failed"], "exactly one event: a failure",
            sourceLocation: sourceLocation)
        let failed = try #require(events.first, sourceLocation: sourceLocation)
        let failure = try #require(
            failed["failure"] as? [String: Any], sourceLocation: sourceLocation)
        #expect(failure["kind"] as? String == kind, sourceLocation: sourceLocation)
        #expect(failure["exitCode"] as? Int == exit, sourceLocation: sourceLocation)
        #expect(failed["schema"] as? Int == 1, sourceLocation: sourceLocation)
        return failed
    }

    // MARK: - 2: does not fit this machine

    /// A declared maximum of 1e14 makes 75 % about 7.5e13 RPM, and the helper would grant the
    /// lease over such a fan anyway. The gate is the envelope.
    ///
    /// **Mutation:** in `SetPlan.make`, replace the `controlEnvelope` switch with a check that
    /// both bounds are measured. Run: red — the lease is taken.
    @Test("A fan whose bounds are implausible is exit 2 for a percentage, and nothing is acquired")
    func implausiblePercentage() async throws {
        let authority = Self.implausibleMachine()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["1", "75%", "--for", "30s", "--json"], over: harness)

        #expect(run.code == FanctlExitCode.requestDoesNotFit.rawValue)
        #expect(await Harness.writes(authority).isEmpty, "not one write to the helper")
        let failed = try Self.failed(run, kind: "requestDoesNotFit", exit: 2)
        #expect(failed["endedBecause"] as? String == "refused")
        #expect(failed["leaseID"] is NSNull)
        #expect(failed["fans"] is NSNull)
        let message = run.output.standardError
        #expect(message.contains(FanBoundsImplausibility.maximumAboveCeiling.description))
        #expect(message.contains("Nothing was acquired"))
        _ = harness.sessions
    }

    @Test("A fan whose bounds are implausible is exit 2 for an rpm too")
    func implausibleRPM() async throws {
        let authority = Self.implausibleMachine()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["1", "3000rpm", "--for", "30s"], over: harness)

        #expect(run.code == 2)
        #expect(await Harness.writes(authority).isEmpty)
        #expect(
            run.output.standardError.contains(
                FanBoundsImplausibility.maximumAboveCeiling.description))
        #expect(run.output.standardOutput.isEmpty, "nothing on stdout in text mode")
        _ = harness.sessions
    }

    @Test("all is all or nothing: one unusable fan is exit 2 and the usable one is not held")
    func allOrNothing() async throws {
        let authority = Self.implausibleMachine()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["all", "75%", "--for", "30s"], over: harness)

        #expect(run.code == 2)
        #expect(await Harness.writes(authority).isEmpty)
        #expect(await authority.currentLease == nil)
        #expect(run.output.standardError.contains("Fan 1"))
        #expect(!run.output.standardError.contains("Fan 0"))
        _ = harness.sessions
    }

    /// Refused, never clamped on the client: 6000 is not turned into 5777, and 0 is not turned
    /// into the floor.
    @Test(
        "An rpm outside the fan's range is exit 2, and 0rpm is never raised",
        arguments: [
            "0rpm", "1349rpm", "5778rpm", "6000RPM",
        ])
    func rpmOutsideTheRange(speed: String) async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["0", speed, "--for", "30s"], over: harness)

        #expect(run.code == 2)
        #expect(await Harness.writes(authority).isEmpty)
        #expect(await authority.appliedSettings.isEmpty)
        #expect(run.output.standardError.contains("1350 to 5777 RPM"))
        _ = harness.sessions
    }

    @Test("A fan the machine does not have is exit 2")
    func noSuchFan() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(["5", "75%", "--for", "30s"], over: harness)

        #expect(run.code == 2)
        #expect(await Harness.writes(authority).isEmpty)
        #expect(run.output.standardError.contains("Fan 5 does not exist"))
        _ = harness.sessions
    }

    // MARK: - 4 and 5: the helper's refusal

    /// Today's helper answers every lease with `writePathNotBuilt`. The message is the
    /// helper's own, with its advice; nothing is applied and nothing released (nothing was
    /// taken).
    ///
    /// **Mutation:** classify `manualControlUnavailable` as 5 in `HelperCommandFailure.code`.
    /// Run: red here and in `FanctlExitCodeTests`.
    @Test("A helper that refuses the lease is exit 4, with its reason, and nothing else is sent")
    func theLeaseIsRefused() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingEveryLease(
            with: .manualControlUnavailable(reason: .writePathNotBuilt))
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.manualControlRefused.rawValue)
        #expect(await Harness.writes(authority) == ["acquireLease"])
        let failed = try Self.failed(run, kind: "manualControlRefused", exit: 4)
        #expect(failed["endedBecause"] as? String == "refused")
        #expect(failed["leaseID"] is NSNull)
        #expect(failed["releaseAccepted"] is NSNull)
        #expect(failed["capturedAt"] is NSNull, "no snapshot was read for the closing event")
        #expect(failed["snapshotFollowsRelease"] is NSNull)
        #expect(
            run.output.standardError.contains(
                ManualControlAvailability.Reason.writePathNotBuilt.userFacingSummary))
        _ = harness.sessions
    }

    /// Only one lease exists. Another client's is not touched, and not released: this run holds
    /// nothing to release.
    @Test("A lease held by another client is exit 5, and that lease is left alone")
    func anotherClientHoldsTheLease() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.heldByAnotherClient.rawValue)
        #expect(await Harness.writes(authority) == ["acquireLease"])
        let failed = try Self.failed(run, kind: "heldByAnotherClient", exit: 5)
        #expect(failed["endedBecause"] as? String == "refused")
        #expect(await authority.currentLease?.holderDescription == "Aeolus.app 0.3.0")
        _ = harness.sessions
    }

    // MARK: - 3, 7 and 1: not a refusal of this request

    @Test("A helper that cannot be reached is exit 3, with a failure document under --json")
    func unreachable() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        harness.isAdmitting = false

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.helperNotReachable.rawValue)
        let failed = try Self.failed(run, kind: "helperNotReachable", exit: 3)
        #expect(failed["endedBecause"] is NSNull, "nothing was refused: nothing was asked")
        #expect(failed["leaseID"] is NSNull)
        #expect(harness.sessions.isEmpty)
    }

    @Test("A helper that cannot be reached prints nothing on stdout in text mode")
    func unreachableText() async throws {
        let harness = ClientListenerHarness(authority: SimulatedFanAuthority())
        harness.isAdmitting = false

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == 3)
        #expect(run.output.standardOutput.isEmpty)
        #expect(run.output.standardError.contains("not installed"))
        #expect(run.desk.installs == 1)
    }

    @Test("A version mismatch is exit 7 and nothing is acquired")
    func versionMismatch() async throws {
        let future = ProtocolVersionRange(
            minimumSupported: AeolusXPCVersion.current + 1, current: AeolusXPCVersion.current + 1)
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority, helperRange: future)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code == FanctlExitCode.protocolVersionMismatch.rawValue)
        #expect(await authority.calls.filter { $0 != "connectionDidInvalidate" }.isEmpty)
        let failed = try Self.failed(run, kind: "protocolVersionMismatch", exit: 7)
        #expect(failed["endedBecause"] is NSNull)
        _ = harness.sessions
    }

    @Test("A first snapshot the helper cannot give is exit 1, and nothing is acquired")
    func theFirstSnapshotFails() async throws {
        let authority = SimulatedFanAuthority()
        await authority.failingSnapshots(after: 0)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness)

        #expect(run.code == FanctlExitCode.failure.rawValue)
        #expect(await Harness.writes(authority).isEmpty)
        _ = harness.sessions
    }
}
