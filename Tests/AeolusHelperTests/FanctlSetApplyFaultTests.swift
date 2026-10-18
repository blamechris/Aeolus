import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` after the helper **answered `apply` with a fault**: the lease is released, and then
/// the safe state is looked at, whatever the fault was.
///
/// A fault used to skip the look, on the assumption that a refused `apply` changed nothing.
/// Level 6 breaks the assumption. It can engage fan 0, fail on fan 1, have the undo refused and
/// still answer only the original fault; it can find a thermal emergency set once every fan was
/// written. A release whose restore was refused is still answered "accepted". `set` then said
/// "Nothing is held" and exited 1 without reading a snapshot, where exit 9 (the restore failed)
/// and its recovery advice exist for exactly this case.
@Suite("fanctl set after apply answers with a fault", .timeLimit(.minutes(1)))
struct FanctlSetApplyFaultTests {

    typealias Harness = SetHarness

    private static let bothFans = ["all", "75%", "--for", "30s", "--json"]

    /// `apply` engaged fan 0, failed, had the undo refused, and answered only the fault. The
    /// release is accepted and the restore did not happen: exit 9, the reason and its recovery,
    /// from a snapshot read after the release.
    ///
    /// **Mutation:** skip the safe-state check after a fault in `SetCommand.afterFailedApply`
    /// (hand `.applyFaulted` a constant `.automatic` settlement). Run: red — exit 1, and "did not
    /// accept the speed" over a fan that is still pinned.
    @Test("A fault that leaves a fan pinned is exit 9, with the reason and the way out")
    func aFaultThatLeavesAFanPinned() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(
            with: .helperFailed(detail: "fan 1 could not be engaged"), leavingPinned: 0,
            as: .restoreToAutomaticFailed)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Self.bothFans, over: harness)

        #expect(run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(await Harness.count("apply", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1, "given back, once")
        #expect(await Harness.count("restoreAllToAutomatic", in: authority) == 0)
        let events = try run.output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "nothing says started")
        let failed = try #require(events.first)
        #expect(
            failed["endedBecause"] as? String == "controlLost",
            "`refused` is only said when the check found nothing left behind")
        #expect(failed["releaseAccepted"] as? Bool == true, "the release was accepted")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "and the check looked")
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["kind"] as? String == "cannotReturnToAutomatic")
        #expect(failure["exitCode"] as? Int == 9)

        let message = run.output.standardError
        let reason = ManualControlAvailability.Reason.restoreToAutomaticFailed
        #expect(message.contains("fan 1 could not be engaged"), "the helper's own words survive")
        #expect(message.contains("Fan 0"))
        #expect(message.contains("(reason: restoreToAutomaticFailed)"))
        #expect(message.contains(reason.recoveryAdvice))
        #expect(message.contains("docs/RECOVERY.md"))
        #expect(message.contains("launchctl bootout system/"))
        #expect(!message.contains("did not accept the speed"))
        #expect(!message.contains("Nothing is held"))
        #expect(!message.lowercased().contains("nothing was applied"))
        #expect(!message.contains("now reports"))
        _ = harness.sessions
    }

    /// The same fault with nothing left behind: the check finds every fan automatic and no
    /// lease, and only then is the helper's "no" the whole story. The exit is the fault's own.
    @Test("A fault that leaves nothing behind keeps its own code, once the check has said so")
    func aFaultThatLeavesNothing() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(with: .boundsImplausible(fanIndex: 0, detail: "x"))
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Self.bothFans, over: harness)

        #expect(run.code == FanctlExitCode.manualControlRefused.rawValue)
        let failed = try #require(try run.output.events().first)
        #expect(failed["endedBecause"] as? String == "refused")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        #expect(run.output.standardError.contains("did not accept the speed"))
        #expect(
            run.output.standardError.contains(
                "lists no manual-control lease and every fan automatic"))
        _ = harness.sessions
    }

    /// A thermal emergency that sets once every fan was written. The release returns the fans
    /// and the check finds them back: exit 4, as the fault classifies, and now said after
    /// looking.
    @Test(
        "A thermal emergency after every fan was written is exit 4 when the check finds them back")
    func anEmergencyAfterEveryFanWasWritten() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApplyAfterEngagingEveryFan(with: .thermalEmergencyActive)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Self.bothFans, over: harness)

        #expect(run.code == FanctlExitCode.manualControlRefused.rawValue)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        let failed = try #require(try run.output.events().first)
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        #expect(failed["endedBecause"] as? String == "refused")
        _ = harness.sessions
    }

    /// The same emergency with the fans **not** back inside the window: the check does not find
    /// the safe state, so the exit is 8 and the text does not say the speed was not accepted.
    ///
    /// **Mutation:** return the `.automatic` lead for every verdict in
    /// `SetMessages.faultedApplyLead`. Run: red on "did not accept".
    @Test("A fault whose fans do not come back inside the window is exit 8, not a refusal")
    func aFaultThatDoesNotSettle() async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApplyAfterEngagingEveryFan(with: .thermalEmergencyActive)
        await authority.settling(afterReleaseSnapshots: 1_000)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Self.bothFans, over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(
            run.time.sleeps.filter { $0 == .seconds(1) }.count == 10,
            "the whole window was waited out")
        let failed = try #require(try run.output.events().first)
        #expect(failed["endedBecause"] as? String == "controlLost")
        let message = run.output.standardError
        #expect(message.contains("answered the request to apply the speed with a fault"))
        #expect(message.contains("within 10 seconds of the release"))
        #expect(!message.contains("did not accept the speed"))
        #expect(!message.lowercased().contains("nothing was applied"))
        _ = harness.sessions
    }

    /// Every fault, not a chosen few: after any `AeolusXPCFault` the lease is released and a
    /// snapshot is read after it.
    ///
    /// **Mutation:** the same as the first test.
    @Test(
        "Every fault from apply is followed by a release and a look",
        arguments: [
            AeolusXPCFault.handshakeRequired,
            .malformedPayload(detail: "x"),
            .invalidParameter(name: "x", detail: "y"),
            .manualControlUnavailable(reason: .releaseInProgress),
            .leaseExpired, .leaseUnknown, .leaseNotHeldByThisConnection,
            .thermalEmergencyActive, .reclaimedBySystem,
            .boundsImplausible(fanIndex: 0, detail: "x"),
            .helperFailed(detail: "x"), .unknown(code: "future", detail: nil),
        ])
    func everyFaultIsFollowedByALook(fault: AeolusXPCFault) async throws {
        let authority = SimulatedFanAuthority()
        await authority.refusingApply(with: fault)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Harness.run(Harness.thirtySeconds + ["--json"], over: harness)

        #expect(run.code != nil, "\(fault)")
        #expect(await Harness.count("releaseLease", in: authority) == 1, "\(fault)")
        #expect(await authority.snapshotsServed >= 2, "a snapshot after the release: \(fault)")
        let failed = try #require(try run.output.events().first)
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "\(fault)")
        _ = harness.sessions
    }
}
