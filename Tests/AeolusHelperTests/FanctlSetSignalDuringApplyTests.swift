import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// A Ctrl-C that lands while `apply` is outstanding.
///
/// `apply` can take a minute or more (the Apple Silicon unlock alone is on the order of fifty
/// seconds), and the signal is remembered but cannot cut it short: releasing the lease under an
/// `apply` that is working is a design change this contract does not make. What it must not do is
/// print "Holding fan 0 at 75% ..." to a person who has already asked to stop, or lose the signal
/// from the report when `apply` then fails.
@Suite("fanctl set when a signal lands during apply", .timeLimit(.minutes(1)))
struct FanctlSetSignalDuringApplyTests {

    typealias Harness = SetHarness

    /// The signal arrives while `apply` is held at the helper; `apply` is then accepted and the
    /// snapshot shows the fan held. The run ends there: the lease is released and the safe state
    /// checked, and "Holding" is never said, in text or in `--json`. Nor is "The hold ended",
    /// for a hold that was never begun.
    ///
    /// **Mutation:** delete the pending-signal check in `SetCommand.begin` (before `started`).
    /// Run: red — `started` is emitted, and the text says "Holding fan 0". **Mutation:** end it
    /// with `.signal` in place of `.signalBeforeHold` there. Run: red on the text's first line.
    @Test(
        "A signal during an accepted apply ends the run before started", arguments: [false, true])
    func aSignalDuringAnAcceptedApply(json: Bool) async throws {
        let authority = SimulatedFanAuthority()
        let gate = AsyncSignal()
        await authority.holdingApply(until: gate)
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        let desk = SignalDesk()
        let command = try Harness.command(
            Harness.thirtySeconds + (json ? ["--json"] : []), endpoint: harness.endpoint,
            output: output, time: VirtualHoldTime(), desk: desk)

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the apply reached the helper") {
            await authority.calls.contains("apply")
        }
        desk.send(.interrupt)
        await gate.signal()
        let code = await running.value
        _ = harness.sessions

        #expect(code == nil, "a clean ending: \(output.standardError)")
        #expect(!output.standardOutput.contains("Holding"), "\(output.standardOutput)")
        #expect(await Harness.count("renewLease", in: authority) == 0, "no hold was begun")
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        if json {
            let events = try output.events()
            #expect(events.map { $0["event"] as? String } == ["ended"], "nothing says started")
            let ended = try #require(events.first)
            #expect(ended["endedBecause"] as? String == "signal")
            #expect(ended["signal"] as? String == "SIGINT")
            #expect(ended["releaseAccepted"] as? Bool == true)
            #expect(ended["snapshotFollowsRelease"] as? Bool == true, "the check looked")
        } else {
            let lines = output.standardOutput.split(separator: "\n").map(String.init)
            #expect(lines.count == 1, "one closing line and no start line: \(lines)")
            #expect(
                lines.first?.hasPrefix(
                    "The hold was not begun: SIGINT was received while the speed was being "
                        + "applied or confirmed.") == true, "\(lines)")
            #expect(!output.standardOutput.contains("The hold ended"))
        }
    }

    /// The signal arrives, and `apply` then answers a fault. The failure is reported as it
    /// always is, and the signal is still in the report: `signal` is not null.
    ///
    /// **Mutations**, each red on its own assertion: build `applyFaulted`'s report with
    /// `signal: nil` in `SetCommand.Report.applyFaulted` (red on `signal`, and only there: the
    /// note is built from the parameter, not the field); drop `+ SetMessages.signalNote(signal)`
    /// there (red on the note).
    @Test("A signal during an apply that then faults stays in the report")
    func aSignalDuringAnApplyThatFaults() async throws {
        let authority = SimulatedFanAuthority()
        let gate = AsyncSignal()
        await authority.holdingApply(until: gate)
        await authority.refusingApply(with: .boundsImplausible(fanIndex: 0, detail: "x"))
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal()
        let desk = SignalDesk()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: VirtualHoldTime(), desk: desk)

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the apply reached the helper") {
            await authority.calls.contains("apply")
        }
        desk.send(.terminate)
        await gate.signal()
        let code = await running.value
        _ = harness.sessions

        #expect(code == FanctlExitCode.manualControlRefused.rawValue, "\(output.standardError)")
        let failed = try #require(try output.events().first)
        #expect(failed["event"] as? String == "failed")
        #expect(failed["signal"] as? String == "SIGTERM", "the signal is not lost")
        #expect(failed["endedBecause"] as? String == "refused", "the failure is what it was")
        #expect(output.standardError.contains("did not accept the speed"))
        #expect(
            output.standardError.contains(
                "SIGTERM was received while the speed was being applied or confirmed.")
        )
    }
}
