import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl auto` against the composed helper after § 5 gave up a fan whose mode still will not
/// read ([#360](https://github.com/blamechris/Aeolus/issues/360)), end to end: the shipping
/// `run()`, the real `HelperClient`, a real listener and the real `HelperConnectionSession`, in
/// front of the `SupervisedFanAuthority` `HelperComposition` builds over `ScriptedControlPlane`
/// answering `.built`.
///
/// This is #360 as a user meets it. Before it, the fan read `automatic` by #178's fold with
/// `.available` beside it, so `auto` judged the machine cleared, sent no restore and exited 0 —
/// the outcome ADR 0013 rejects under "Exit 0 only when the mode was actually read". Every build on
/// `main` is `.notBuilt`, so this is the command as it will behave once a write path exists, and
/// nothing here is evidence about hardware.
///
/// Time is `VirtualSettleTime`'s, as in `FanctlAutoTests`: its sleep advances a virtual clock and
/// returns, so the 10-second window costs nothing and no thread is ever held waiting. Every
/// snapshot and the restore are still real XPC round trips. The supervisors are not started.
@Suite("fanctl auto: a fan whose mode will not read, composed", .timeLimit(.minutes(1)))
struct FanctlAutoUnreadModeTests {

    /// How many machine-wide restores the firmware has been asked for.
    private static func machineWideRestores(on plane: ScriptedControlPlane) async -> Int {
        await plane.attempts.filter { $0 == .restoreToAutomatic(.everyFan) }.count
    }

    /// `TerminalActionAvailabilityTests.aStillBlindFanReadsTheGrantsRefusal`'s helper, behind a
    /// listener: § 5 has given fan 0 up blind, and its `F0Md` still does not answer.
    ///
    /// **Mutation:** delete the `case nil:` arm's restatement in
    /// `ReadOnlyFanReport.reportingForeignControl(of:observedMode:heldByAeolus:
    /// awaitingConfirmation:reconciliation:)`, returning `fan`. Run: red twice — the exit is 0, not
    /// 8, and no machine-wide restore is sent.
    @Test("fanctl auto sends its restore and exits 8 about a fan whose mode will not read")
    func autoExitsEightAboutAFanWhoseModeWillNotRead() async throws {
        let (helper, log) = try await FinaliseReleaseLedgerTests.holding(
            afterwards: [
                ScriptedControlPlane.Stage(
                    temperatures: LeaseFixture.nominalDieTemperatures, unreadableModes: [0])
            ])
        await helper.plane.setMode(.manual, ofFan: 0)
        await helper.plane.advance()
        await FinaliseReleaseLedgerTests.cycleToTheTerminalAction(helper)
        #expect(
            log.lines(containing: "because the helper cannot read its state").count == 1,
            "§ 5 never gave the blind fan up, so nothing here was tested")
        await FinaliseReleaseLedgerTests.expectTheRevocationRestoredThroughTheRestorer(helper)
        #expect(await helper.ledger.isSupervisorBlind(fanAt: 0), "the terminal action kept no mark")
        let before = await Self.machineWideRestores(on: helper.plane)
        let harness = ClientListenerHarness(authority: helper.authority)

        let run = try await FanctlAutoTests.run(over: harness)

        #expect(
            run.code == FanctlExitCode.safeStateNotConfirmed.rawValue,
            """
            fanctl auto exited \(String(describing: run.code)) about a fan whose mode the helper \
            cannot read: exit 0 claims a safe state nothing confirmed.
            """)
        let after = await Self.machineWideRestores(on: helper.plane)
        #expect(
            after == before + 1,
            """
            \(after - before) machine-wide restores were sent, not one: a blind fan was treated as \
            already automatic.
            """)
        #expect(
            run.output.standardError.contains("fan 0 (supervisorBlind)"),
            "the diagnosis does not name the fan or the reason: \(run.output.standardError)")
    }
}
