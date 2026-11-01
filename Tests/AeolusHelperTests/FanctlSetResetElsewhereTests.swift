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
/// `LeaseAuthority.releaseEveryLease`), so the next renewal finds no lease and is refused
/// `leaseUnknown` (`LeaseAuthority.heldLease`). **What `set` exits depends on whether a renewal
/// comes before the hold ends**, so there are two outcomes, and neither is the other's exception:
///
/// - **A renewal comes first: 6** (`aResetFromAnotherClient`). The refusal is a loss the helper
///   reported: `set` releases (refused, the lease is gone), looks at the safe state, and exits 6
///   with `controlLost` when the check finds every fan automatic and no lease. The exit is 8 or 9
///   instead when the check finds worse, as for every loss (`FanctlSetHoldLossCheckTests`).
/// - **The hold ends first: 0** (`aResetAfterTheLastRenewal`). The loop does not renew at the
///   deadline, so a reset that lands after the last renewal is never found by one. The hold ends
///   as it was asked to, the release is refused for the same reason, the check finds every fan
///   automatic and no lease, and `set` exits 0 with `ended`. `releaseAccepted: false` is the
///   record that the release did not take, and `endedBecause` says how the hold ended. A signal
///   before the next renewal ends it the same way (`endedBecause: signal`); no test here pins
///   that one.
///
/// So exit 0 does not say the fans were held for the whole `--for`. It says the fans are
/// automatic and no lease is listed after the release, which a reset from another client also
/// produces. **These two tests pin what `set` does today, not a ruling.** Whether an ending whose
/// release is refused with a lease-gone answer should exit 6 is a separate question for ADR 0013,
/// and changing either answer is a change to exit-code behaviour.
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
    @Test("A reset --all from another client that a renewal finds is exit 6")
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

    /// `set 0 75% --for 30s --json` renews at 10 s and at 20 s. During the sleep that ends at the
    /// deadline, another connection runs the shipping `fanctl reset --all`, which the helper
    /// accepts. Nothing renews again, so nothing finds the lease gone: the hold ends on its
    /// deadline, the release is refused (the lease is already gone), the check finds every fan
    /// automatic and no lease, and the run exits 0.
    ///
    /// **Mutation:** in `SetCommand.heartbeats`, delete the check after the sleep that returns
    /// `.ended(reason)` for `watch.reason` ("Not renewed at the deadline"), so the loop renews at
    /// the deadline. Run: red — a third renewal is sent and refused, and the run exits 6 with
    /// `failed` and `controlLost` in place of 0 with `ended`.
    @Test("A reset --all from another client after the last renewal is exit 0, release refused")
    func aResetAfterTheLastRenewal() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let atTheLastSleep = AsyncSignal()
        let resetDone = AsyncSignal()
        let time = VirtualHoldTime(script: { number, _ in
            guard number == 3 else { return }
            await atTheLastSleep.signal()
            try await resetDone.wait()
        })
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())

        let running = Task { await exitCode { try await command.run() } }
        try await atTheLastSleep.wait()
        let reset = try await FanctlResetTests.emitted(
            over: harness, waiting: FanctlResetTests.unhurried, counting: .harness)
        try #require(reset.exitCode == .success, "the reset was accepted: \(reset.message)")
        try #require(await authority.currentLease == nil, "the reset dropped the lease")
        await resetDone.signal()
        let code = await running.value

        #expect(code == nil, "\(output.standardError)")
        let events = try output.events()
        #expect(
            events.map { $0["event"] as? String } == ["started", "holding", "holding", "ended"],
            "held through both heartbeats, then ended on its deadline")
        let ended = try #require(events.last)
        #expect(ended["endedBecause"] as? String == "durationElapsed")
        #expect(ended["failure"] is NSNull, "nothing was reported lost")
        #expect(ended["releaseAccepted"] as? Bool == false, "the lease was already gone")
        #expect(ended["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        #expect(
            await Harness.count("renewLease", in: authority) == 2,
            "no renewal after the reset, accepted or refused")
        #expect(await Harness.count("releaseLease", in: authority) == 1, "set tried to release")
        #expect(await Harness.count("acquireLease", in: authority) == 1, "never re-acquires")
        #expect(
            await Harness.count("restoreAllToAutomatic", in: authority) == 1,
            "the other client's reset, and none from set")
        #expect(harness.sessions.count >= 2, "set's connection and the reset's")
    }
}
