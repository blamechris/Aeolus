import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` and the ways a hold ends that are not a failure: a signal, a parent that
/// exited, a standard output that closed (the deadline is `FanctlSetDeadlineTests`). Each
/// releases the lease and runs the safe-state check (`FanctlSetEndingTests` is what that check
/// says); this suite is how each ending is *reached*, and that it is reached by the sleep and
/// nothing else.
///
/// The same shape as `FanctlSetTests`: the shipping `run()`, the real `HelperClient`, a real
/// `NSXPCListener`, a simulated authority and a virtual clock.
@Suite("fanctl set's ordinary endings", .timeLimit(.minutes(1)))
struct FanctlSetStopTests {

    typealias Harness = SetHarness

    // MARK: - Signals

    /// Ctrl-C, `kill`, and a terminal that closed each end the hold early, release the lease and
    /// run the safe-state check. The sleep is what they interrupt; the release that follows is
    /// not cancelled.
    ///
    /// **Mutation:** in `HoldInterrupt.post`, do not cancel the sleeper. Run: red — the parked
    /// sleep runs its 20 seconds and the assertions fail.
    @Test(
        "A signal ends the hold, releases the lease and checks the safe state",
        .timeLimit(.minutes(1)), arguments: [HoldSignal.interrupt, .terminate, .hangup])
    func aSignalEndsTheHold(signal: HoldSignal) async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime(script: { number, _ in
            guard number == 2 else { return }
            desk.send(signal)
            try await Task.sleep(for: .seconds(20))
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk)

        #expect(run.code == nil, "ended by \(signal.name) and the helper reports the safe state")
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        #expect(time.elapsed == .seconds(10), "the interrupted sleep passed no time")
        let events = try run.output.events()
        #expect(events.map { $0["event"] as? String } == ["started", "holding", "ended"])
        let ended = try #require(events.last)
        #expect(ended["endedBecause"] as? String == "signal")
        #expect(ended["signal"] as? String == signal.name)
        #expect(ended["releaseAccepted"] as? Bool == true)
        #expect(await authority.currentLease == nil)
        _ = harness.sessions
    }

    @Test("A signal ends a text hold with the signal named on the closing line")
    func aSignalInText() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime(script: { number, _ in
            guard number == 1 else { return }
            desk.send(.interrupt)
            try await Task.sleep(for: .seconds(20))
        })

        let run = try await Harness.run(
            ["0", "75%", "--for", "2h"], over: harness, time: time, desk: desk)

        #expect(run.code == nil)
        let closing = try #require(run.output.standardOutput.split(separator: "\n").last)
        #expect(closing.hasPrefix("The hold ended: SIGINT was received. "))
        #expect(await Harness.count("renewLease", in: authority) == 0)
        _ = harness.sessions
    }

    /// A signal that arrives while connecting is a person asking to stop: nothing is held, so
    /// nothing is written, and the exit is 1 with the reason.
    ///
    /// **Mutation:** delete the `interrupt.pending` check before `acquireLease` in
    /// `SetCommand.perform`. Run: red — the lease is taken.
    @Test("A signal before control is taken writes nothing and exits 1")
    func aSignalBeforeControl() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        desk.deliverOnInstall(.interrupt)

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, desk: desk)

        #expect(run.code == FanctlExitCode.failure.rawValue)
        #expect(await Harness.writes(authority).isEmpty)
        let events = try run.output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"])
        let failed = try #require(events.first)
        #expect(failed["signal"] as? String == "SIGINT")
        #expect(failed["leaseID"] is NSNull)
        #expect(failed["endedBecause"] as? String == "signal", "ended by the signal, named")
        #expect(run.output.standardError.contains("SIGINT was received before control was taken"))
        _ = harness.sessions
    }

    /// A signal that lands while `acquireLease` is in flight. The lease is granted, and the
    /// speed must not be sent after it: the lease is given back and the run ends with the signal.
    /// The simulated helper holds the acquire until the signal has landed.
    ///
    /// **Mutation:** delete the `interrupt.pending` check between `acquireLease` and `apply` in
    /// `SetCommand.perform`. Run: red — `apply` is sent, and the speed is held.
    @Test("A signal that lands during the lease round trip stops the speed being sent")
    func aSignalDuringTheLeaseRoundTrip() async throws {
        let authority = SimulatedFanAuthority()
        let gate = AsyncSignal()
        await authority.holdingAcquire(until: gate)
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let output = RecordingTerminal()
        let command = try Harness.command(
            Harness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: VirtualHoldTime(), desk: desk)

        let running = Task { await exitCode { try await command.run() } }
        try await waitUntil("the acquire reached the helper") {
            await authority.calls.contains("acquireLease")
        }
        desk.send(.interrupt)
        await gate.signal()
        let code = await running.value

        #expect(code == FanctlExitCode.failure.rawValue)
        #expect(await Harness.count("apply", in: authority) == 0, "no speed was sent")
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await authority.currentLease == nil)
        #expect(await authority.appliedSettings.isEmpty)
        let events = try output.events()
        #expect(events.map { $0["event"] as? String } == ["failed"], "no start, one closing event")
        let failed = try #require(events.first)
        #expect(failed["endedBecause"] as? String == "signal")
        #expect(failed["signal"] as? String == "SIGINT")
        #expect(failed["leaseID"] is String, "the lease was taken")
        #expect(failed["releaseAccepted"] as? Bool == true)
        #expect(output.standardError.contains("before any speed was sent"))
        _ = harness.sessions
    }

    // MARK: - The schedule

    /// A write that took four seconds shortens the next sleep by four: the renewals stay ten
    /// seconds apart, so a slow consumer cannot eat the two heartbeats the lease can miss.
    ///
    /// **Mutation:** sleep a whole `heartbeat` after the work instead of until the next
    /// renewal is due (`untilNextRenewal = heartbeat` in `SetCommand.heartbeats`). Run: red —
    /// the sleeps are 10, 10, 6.
    @Test("Renewals are scheduled from the last renewal, not from the end of the work after it")
    func renewalsKeepTheirSchedule() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let time = VirtualHoldTime()
        let output = RecordingTerminal(onStandardOutput: { number, _ in
            if number == 2 { time.advance(by: .seconds(4)) }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, output: output)

        #expect(run.code == nil)
        #expect(time.sleeps == [.seconds(10), .seconds(6), .seconds(10)])
        #expect(await Harness.count("renewLease", in: authority) == 2)
        _ = harness.sessions
    }

    /// A signal that arrives while the loop is busy with the helper, not while it sleeps: it is
    /// remembered, and the next sleep ends at once. No second heartbeat is made for it.
    ///
    /// **Mutation:** delete the `if let signal { return .signal(signal) }` after the sleep in
    /// `HoldInterrupt.sleep`. Run: red — the sleep reports `.elapsed`, and the hold renews again
    /// before it sees the signal.
    @Test("A signal that arrives during a heartbeat ends the hold before the next renewal")
    func aSignalDuringAHeartbeat() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let output = RecordingTerminal(onStandardOutput: { number, _ in
            if number == 2 { desk.send(.terminate) }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, desk: desk, output: output)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        let ended = try #require(try output.events().last)
        #expect(ended["endedBecause"] as? String == "signal")
        #expect(ended["signal"] as? String == "SIGTERM")
        _ = harness.sessions
    }

    // MARK: - The parent

    /// The parent exited: the process was reparented, and no one is left to want the fans.
    ///
    /// **Mutation:** delete the `parentProcessID()` comparison in `SetCommand.heartbeats`. Run:
    /// red — the hold runs to the end.
    @Test("A parent that exits ends the hold at the next heartbeat")
    func theParentExits() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime(script: { number, _ in
            if number == 2 { desk.parentExits() }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        let ended = try #require(try run.output.events().last)
        #expect(ended["endedBecause"] as? String == "parentExited")
        #expect(ended["signal"] is NSNull)
        _ = harness.sessions
    }

    // MARK: - Standard output

    /// A consumer that went away: the `holding` write is the one that finds out. The hold ends,
    /// the lease is released, and the process does not crash.
    ///
    /// **Mutation:** ignore the result of `SetOutput.holding` in `SetCommand.heartbeats`. Run:
    /// red — the hold runs to the end.
    @Test("A stdout write that fails ends the hold, and the closing event is still attempted")
    func standardOutputCloses() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal(acceptingStandardOutputLines: 1)

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, output: output)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(try output.events().map { $0["event"] as? String } == ["started"])
        let attempted = try output.attemptedEvents()
        #expect(attempted.map { $0["event"] as? String } == ["started", "holding", "ended"])
        #expect(attempted.last?["endedBecause"] as? String == "outputClosed")
        #expect(
            output.standardError.contains(
                "The hold ended: standard output was closed or did not make room."),
            "the closing line goes where it can be read")
        _ = harness.sessions
    }

    @Test("A text hold whose start line cannot be written ends before the first heartbeat")
    func theStartLineCannotBeWritten() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal(acceptingStandardOutputLines: 0)

        let run = try await Harness.run(Harness.thirtySeconds, over: harness, output: output)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(run.time.sleeps.isEmpty)
        #expect(output.standardError.contains("standard output was closed"))
        _ = harness.sessions
    }

    /// Every start line is tried: the first to fail does not excuse the rest, so a consumer that
    /// can still read one of them is not denied it.
    ///
    /// **Mutation:** make `SetOutput.started` stop at the first line that fails
    /// (`allSatisfy { terminal.deliver($0) }`). Run: red — one line attempted.
    @Test("A start line that fails does not stop the others being tried")
    func everyStartLineIsTried() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let output = RecordingTerminal(acceptingStandardOutputLines: 0)

        let run = try await Harness.run(
            ["all", "75%", "--for", "10s"], over: harness, output: output)

        #expect(run.code == nil)
        let attempted = output.attemptedStandardOutput.filter { $0.hasPrefix("Holding fan") }
        #expect(attempted.count == 2, "\(attempted)")
        _ = harness.sessions
    }
}
