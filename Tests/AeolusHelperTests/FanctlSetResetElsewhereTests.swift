import AeolusXPC
import ArgumentParser
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// A hold ended by `fanctl reset --all` from another client: run 1's step 1c (ADR 0014's run-1
/// restatement), where the reset is typed in an SSH session while `set` holds fan 0 in another.
///
/// `restoreAllToAutomatic` drops every lease (`SupervisedFanAuthority.restoreAllToAutomatic`,
/// `LeaseAuthority.releaseEveryLease`), so the hold's next renewal finds no lease and is refused
/// `leaseUnknown` (`LeaseAuthority.heldLease`). That is a loss the helper reported: `set` releases
/// (refused, the lease is gone), looks at the safe state, and exits 6 with `controlLost` when the
/// check finds every fan automatic and no lease. **Never 0**: the hold did not end the way it was
/// asked to, and a script that reads 0 would take the fans to have been held for the whole
/// `--for`. The exit is 8 or 9 instead when the check finds worse, as for every loss
/// (`FanctlSetHoldLossCheckTests`).
@Suite("fanctl set when another client resets every fan", .timeLimit(.minutes(1)))
struct FanctlSetResetElsewhereTests {

    typealias Harness = SetHarness

    /// `set 0 75% --for 30s --json` holds through its first heartbeat; during the sleep before the
    /// second, another connection runs the shipping `fanctl reset --all`, which the helper
    /// accepts. The second renewal is refused, and the run ends in 6.
    ///
    /// **Mutation:** in `SetCommand.heartbeats`, end the hold as `.ended(.durationElapsed)` when a
    /// renewal fails, in place of `.lost(.renewalFailed(…))`. Run: red — exit 0, `ended`, and
    /// `endedBecause: durationElapsed` for a hold another client ended.
    @Test("A reset --all from another client during the hold is exit 6, never 0")
    func aResetFromAnotherClient() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let atTheSecondHeartbeat = AsyncSignal()
        let resetDone = AsyncSignal()
        let time = VirtualHoldTime(script: { number, _ in
            guard number == 2 else { return }
            await atTheSecondHeartbeat.signal()
            try await resetDone.wait()
        })
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await atTheSecondHeartbeat.wait()
        let reset = try await FanctlResetTests.emitted(
            over: harness, waiting: FanctlResetTests.unhurried, counting: .harness)
        try #require(reset.exitCode == .success, "the reset was accepted: \(reset.message)")
        try #require(await authority.currentLease == nil, "the reset dropped the lease")
        await resetDone.signal()
        let code = await running.value

        #expect(code == FanctlExitCode.controlLost.rawValue, "\(output.standardError)")
        let events = try output.events()
        #expect(
            events.map { $0["event"] as? String } == ["started", "holding", "failed"],
            "held for one heartbeat, then lost")
        let failed = try #require(events.last)
        #expect(failed["endedBecause"] as? String == "controlLost")
        let failure = try #require(failed["failure"] as? [String: Any])
        #expect(failure["exitCode"] as? Int == 6)
        #expect(failure["kind"] as? String == "controlLost")
        #expect(failed["releaseAccepted"] as? Bool == false, "the lease was already gone")
        #expect(failed["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        #expect(output.standardError.contains("did not renew lease"))
        #expect(await authority.renewals == 1, "the second renewal found no lease")
        #expect(await Harness.count("acquireLease", in: authority) == 1, "never re-acquires")
        #expect(
            await Harness.count("restoreAllToAutomatic", in: authority) == 1,
            "the other client's reset, and none from set")
        #expect(harness.sessions.count >= 2, "set's connection and the reset's")
    }
}
