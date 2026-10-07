import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl auto`, end to end: the shipping `run()`, the real `HelperClient`, a real
/// `NSXPCListener` and the real `HelperConnectionSession` behind it. Only the authority is a
/// double — `SimulatedFanAuthority` — and only where to look, where to write and how time
/// passes are substituted on the command.
///
/// **Time is virtual.** The 10-second window is walked by a clock that advances exactly as far
/// as it is asked to sleep, so a helper that never settles costs microseconds. Every snapshot
/// and every restore is still a real XPC round trip.
///
/// What none of it proves is that a **signed** `fanctl` is admitted by an **installed** helper,
/// or what the fans do after a real restore; that is blocked on #82 and on E4 exactly as
/// `FanctlResetTests` records. A green run here is the contract held against a double.
@Suite("fanctl auto against a real helper session")
struct FanctlAutoTests {

    private static func auto(_ arguments: [String] = []) throws -> Fanctl.Auto {
        try #require(Fanctl.parseAsRoot(["auto"] + arguments) as? Fanctl.Auto)
    }

    struct Run {
        let code: Int32?
        let output: RecordingTerminal
        let time: VirtualSettleTime
    }

    /// Runs the **shipping** `run()` against one listener.
    static func run(
        _ arguments: [String] = [],
        over harness: ClientListenerHarness,
        time: VirtualSettleTime = VirtualSettleTime(),
        realClock: Bool = false
    ) async throws -> Run {
        let output = RecordingTerminal()
        var command = try auto(arguments)
        command.helper = HelperConnection(
            transport: .endpoint(harness.endpoint),
            pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = output.terminal
        if !realClock { command.clock = time.clock }
        let code = await exitCode { try await command.run() }
        return Run(code: code, output: output, time: time)
    }

    static func json(_ run: Run) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(run.output.standardOutput.utf8))
        return try #require(object as? [String: Any])
    }

    /// Everything the authority was asked, minus the read and the teardown notice.
    private static func writes(_ authority: SimulatedFanAuthority) async -> [String] {
        await authority.calls.filter { $0 != "snapshot" && $0 != "connectionDidInvalidate" }
    }

    // MARK: - Already automatic

    /// The whole of "idempotent": nothing to return means nothing is sent.
    ///
    /// **Mutation:** delete the early return on `.automatic` after the first snapshot in
    /// `AutoCommand.perform`. Run: red — one restore request reaches the helper.
    @Test("Already automatic: exit 0, one read, and not one write")
    func alreadyAutomaticSendsNothing() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == nil)
        #expect(await authority.restoreRequests == 0)
        let writes = await Self.writes(authority)
        #expect(writes.isEmpty, "sent \(writes)")
        #expect(await authority.snapshotsServed == 1)
        #expect(run.time.sleeps.isEmpty)
        let text = run.output.standardOutput
        #expect(text.contains("The helper reports every fan automatic and no manual-control lease"))
        #expect(text.contains("No restore request was sent."))
        #expect(run.output.standardError.isEmpty)

        let session = try #require(harness.sessions.first)
        #expect(await session.handshakeState != nil, "auto must handshake")
    }

    /// `auto all` is `auto`.
    ///
    /// **Mutation:** make `Fanctl.Auto.validate()` reject `all`. Run: red here.
    @Test("auto all does exactly what auto does")
    func autoAllIsAuto() async throws {
        struct Result: Equatable {
            let code: Int32?
            let text: String
            let writes: [String]
        }
        var results: [Result] = []
        for arguments in [[], ["all"]] {
            let authority = SimulatedFanAuthority()
            await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
            let harness = ClientListenerHarness(authority: authority)
            let run = try await Self.run(arguments, over: harness)
            // The lease id and the capture time differ per run by construction.
            let text = Self.masked(run.output.standardOutput)
            results.append(Result(code: run.code, text: text, writes: await Self.writes(authority)))
        }
        #expect(results[0].code == nil)
        #expect(results[0] == results[1])
        #expect(results[0].writes == ["restoreAllToAutomatic"])
    }

    private static func masked(_ text: String) -> String {
        text.replacing(/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/, with: "<time>")
            .replacing(
                /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/, with: "<uuid>")
    }

    // MARK: - A restore that settles

    /// One restore, a poll every virtual second until the fourth snapshot after it shows the
    /// fans back, and the holder it ended is named.
    ///
    /// **Mutation:** replace the `SafeState.settle` call in `AutoCommand.perform` with a
    /// constant `.automatic` verdict. Run: red on the snapshot count and the sleeps — it never
    /// looked.
    @Test("A restore that settles after three polls exits 0, names the ended holder, sends once")
    func settlesAfterPolling() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await authority.settling(afterSnapshots: 3)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == nil)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 5, "one before the restore, four after it")
        #expect(run.time.sleeps == Array(repeating: .seconds(1), count: 3))
        let text = run.output.standardOutput
        #expect(text.contains("The manual-control lease held by \"Aeolus.app 0.3.0\""))
        #expect(text.contains("is no longer listed"))
        #expect(!text.contains("Ended"))
        #expect(text.contains("Asked the helper once to return every fan to automatic control"))
        #expect(
            text.contains("The helper now reports every fan automatic and no manual-control lease"))
        #expect(run.output.standardError.isEmpty)
        #expect(await authority.currentLease == nil)
        #expect(await authority.modes() == [.automatic, .automatic])
    }

    @Test("A restore the helper applies at once is confirmed by the first poll, with no wait")
    func settlesAtOnce() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == nil)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 2)
        #expect(run.time.sleeps.isEmpty)
        #expect(!run.output.standardOutput.contains("is no longer listed"))
    }

    // MARK: - A restore that does not

    /// Exactly one request, however long it takes and however it ends. A second one would be
    /// a tug-of-war with whoever else writes (ADR 0011 D2).
    ///
    /// **Mutation:** move the `restoreAllToAutomatic()` call inside `SafeState.settle`'s read
    /// closure in `AutoCommand.perform`, so it is sent before every poll. Run: red — eleven
    /// requests.
    @Test("A fan that never settles exits 8 after ten seconds, with exactly one restore sent")
    func neverSettlesExitsEight() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1_000)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 12, "one before the restore, eleven polls")
        #expect(run.time.elapsed == .seconds(10))
        let diagnosis = run.output.standardError
        #expect(diagnosis.contains("within 10 seconds"))
        #expect(diagnosis.contains("Fan 0"))
        #expect(diagnosis.contains("launchctl bootout system/"))
        #expect(run.output.standardOutput.contains("mode manualFixed"))
        #expect(!run.output.standardOutput.contains("now reports"))
    }

    /// A refused request is not a reason to send another.
    @Test("A restore the helper refuses is reported, not retried, and the poll still decides")
    func aRefusedRestoreIsNotRetried() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.refusingRestore(with: .helperFailed(detail: "firmware said no"))
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(await authority.snapshotsServed == 12)
        #expect(run.output.standardOutput.contains("it did not confirm the request"))
        #expect(run.output.standardError.contains("did not confirm the restore request"))
    }

    /// The helper stopped answering between two polls: that is not the safe state, whatever
    /// the last snapshot said, and the run says the snapshot it shows may predate the restore.
    ///
    /// **Mutation:** in `SafeState.settle`, return `.automatic` from the read's `catch`. Run:
    /// red — exit 0.
    @Test("A snapshot that fails mid-poll exits 8 and says the last snapshot may predate it")
    func aFailedPollExitsEight() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1_000)
        await authority.failingSnapshots(after: 3)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(run.time.sleeps.count == 2)
        #expect(run.output.standardError.contains("stopped answering"))
        #expect(run.output.standardError.contains("may predate"))
        #expect(!run.output.standardOutput.contains("now reports"))
    }

    @Test("A thermal emergency is named when it is why the fans stay up")
    func anEmergencyIsNamed() async throws {
        let authority = SimulatedFanAuthority()
        await authority.strandManual(0)
        await authority.settling(afterSnapshots: 1_000)
        await authority.setThermalEmergency(true)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        #expect(run.output.standardError.contains("thermal emergency"))
        #expect(run.output.standardOutput.contains("Thermal emergency: ACTIVE"))
    }

    // MARK: - 9: the fan nothing here can return

    /// A fan another program holds: one restore is all it gets (the helper decides what that
    /// reaches), the wait runs out, and the reason and its advice are on the terminal.
    ///
    /// **Mutation:** map `.cannotReturn` to `.safeStateNotConfirmed` in
    /// `AutoCommand.Observation.failure`. Run: red.
    @Test("A fan pinned by another program exits 9 with the reason and its advice")
    func foreignPinExitsNine() async throws {
        let authority = SimulatedFanAuthority()
        await authority.markForeignManual(1)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(run.time.elapsed == .seconds(10), "9 is judged at the end of the window")
        let diagnosis = run.output.standardError
        let reason = ManualControlAvailability.Reason.foreignManualControl
        #expect(diagnosis.contains("Fan 1"))
        #expect(diagnosis.contains(reason.userFacingSummary))
        #expect(diagnosis.contains(reason.recoveryAdvice))
        #expect(diagnosis.contains("(reason: foreignManualControl)"))
        #expect(diagnosis.contains("docs/RECOVERY.md"))
        #expect(await authority.modes() == [.automatic, .manualFixed], "fan 0 was returned")
    }

    @Test("A fan the firmware refused to hand back exits 9 and points at the way out")
    func failedRestoreExitsNine() async throws {
        let authority = SimulatedFanAuthority()
        await authority.pin(0, as: .restoreToAutomaticFailed)
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == 9)
        #expect(await authority.restoreRequests == 1)
        #expect(run.output.standardError.contains("(reason: restoreToAutomaticFailed)"))
        #expect(run.output.standardError.contains("launchctl bootout system/"))
    }

    // MARK: - 5: someone else holds the fans

    /// A lease that is there when the window ends is somebody else's hold — taken after the
    /// restore, or never ended by it. This command does not take the fans back a second time.
    ///
    /// **Mutation:** drop the lease case from `AutoCommand.Observation.failure` (return 8).
    /// Run: red.
    @Test("A lease that reappears after the restore exits 5, names the new holder, sends once")
    func aLeaseThatReappearsExitsFive() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await authority.reacquiring(as: "Other 1.0")
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.heldByAnotherClient.rawValue)
        #expect(await authority.restoreRequests == 1)
        #expect(run.time.elapsed == .seconds(10))
        #expect(run.output.standardError.contains("\"Other 1.0\""))
        #expect(
            run.output.standardOutput.contains(
                "The manual-control lease held by \"Aeolus.app 0.3.0\""),
            "the first lease is no longer listed; the second is a different one")
        #expect(run.output.standardOutput.contains("is no longer listed"))
    }

    /// A restore the helper accepts and does not act on leaves the same lease standing. That
    /// lease was not ended by this run, and the output must not say it was.
    ///
    /// **Mutation:** compute `endedLease` as the first snapshot's lease without comparing it to
    /// the last. Run: red — it claims to have ended a lease still listed.
    @Test("A lease the restore did not end is not reported as ended")
    func aSurvivingLeaseWasNotEnded() async throws {
        let authority = SimulatedFanAuthority()
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await authority.ignoringRestore()
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == 5)
        #expect(await authority.restoreRequests == 1)
        #expect(!run.output.standardOutput.contains("is no longer listed"))
        #expect(run.output.standardError.contains("\"Aeolus.app 0.3.0\""))
    }

    /// 9, then 5, then 8.
    @Test("A pinned fan and a reappearing lease together exit 9")
    func nineOutranksFive() async throws {
        let authority = SimulatedFanAuthority()
        await authority.markForeignManual(1)
        await authority.grantForeignLease(over: [0], holder: "Aeolus.app 0.3.0")
        await authority.reacquiring(as: "Other 1.0")
        let harness = ClientListenerHarness(authority: authority)

        let run = try await Self.run(over: harness)

        #expect(run.code == FanctlExitCode.cannotReturnToAutomatic.rawValue)
        #expect(await authority.restoreRequests == 1)
    }
}

/// Time that moves only when something sleeps, by exactly as much as it slept.
///
/// `fanctlTests` has its own `VirtualTime`: test targets cannot share sources, and this suite
/// lives here for the reason `FanctlResetTests` gives.
final class VirtualSettleTime: Sendable {
    private struct State {
        var elapsed = Duration.zero
        var sleeps: [Duration] = []
    }

    private let origin = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())

    var elapsed: Duration { state.withLock { $0.elapsed } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    /// A wait that sleeps this many times is a loop that has stopped ending. Under a clock
    /// that costs nothing it would hang the suite rather than fail it, so the next sleep is
    /// cancelled instead.
    static let runaway = 200

    var clock: SettleClock {
        SettleClock(
            now: { [origin, state] in origin + state.withLock { $0.elapsed } },
            sleep: { [state] duration in
                let sleepsSoFar = state.withLock { value -> Int in
                    value.elapsed += duration
                    value.sleeps.append(duration)
                    return value.sleeps.count
                }
                if sleepsSoFar > Self.runaway { throw CancellationError() }
            })
    }
}
