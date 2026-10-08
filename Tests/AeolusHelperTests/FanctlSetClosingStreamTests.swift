import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// Which stream carries `fanctl set`'s closing event, and that it is never glued to a fragment.
///
/// The closing event goes to standard output **only if that stream is idle**, so it starts a
/// line of its own; otherwise it goes to standard error, as the same line. Exactly one closing
/// event is attempted, on exactly one stream, on every ending that is not SIGKILL. A review
/// found that after a line was abandoned half-way the next write (the closing event) had been
/// appended to the fragment: one line, half a `holding` event and all of an `ended`, that parses
/// as neither, and only an `outputClosed` ending copied it anywhere readable.
@Suite("fanctl set's closing event", .timeLimit(.minutes(1)))
struct FanctlSetClosingStreamTests {

    typealias Harness = SetHarness

    private static func closingEvents(_ events: [[String: Any]]) -> [[String: Any]] {
        events.filter { ["ended", "failed"].contains($0["event"] as? String) }
    }

    // MARK: - Standard output, when it can take it

    /// A consumer that drains: the closing event is the last line of standard output, and
    /// standard error carries nothing.
    ///
    /// **Mutation:** always write the closing event to standard error (drop the stdout branch of
    /// `SetOutput.deliverClosing`). Run: red.
    @Test("A stream that is idle takes the closing event, and standard error stays empty")
    func idleStdoutTakesIt() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let rig = PumpRig(parkingFromLine: nil)
        let time = VirtualHoldTime(script: rig.script())

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, terminal: rig.terminal)

        #expect(run.code == nil)
        let events = rig.standardOutput.events().map { $0["event"] as? String }
        #expect(events == ["started", "holding", "holding", "ended"])
        #expect(rig.standardError.consumed.isEmpty)
        _ = harness.sessions
    }

    // MARK: - Standard error, when it cannot

    /// A stream whose writer has failed cannot be written to again. The closing event is on
    /// standard error, once.
    @Test("A stream that has failed does not take the closing event; standard error does")
    func brokenStdout() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let rig = PumpRig(failingFromLine: 2)
        let time = VirtualHoldTime(script: rig.script())

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(rig.standardOutput.events().map { $0["event"] as? String } == ["started"])
        let closing = rig.standardError.events()
        #expect(closing.map { $0["event"] as? String } == ["ended"])
        #expect(closing.first?["endedBecause"] as? String == "outputClosed")
        _ = harness.sessions
    }

    /// A `failed` ending, with standard output parked: the diagnosis in words and the `failed`
    /// event both reach standard error, and the event parses and carries the exit code.
    ///
    /// **Mutation:** send the `failed` event to standard output regardless (the stream choice in
    /// `SetOutput.deliverClosing` ignores the pump). Run: red.
    @Test("A failed ending with standard output parked: the failed event is on standard error")
    func failedEndingWhileParked() async throws {
        let authority = SimulatedFanAuthority()
        await authority.settling(afterReleaseSnapshots: 1_000)
        let harness = ClientListenerHarness(authority: authority)
        let rig = PumpRig(parkingFromLine: 2)
        defer { rig.release() }
        let time = VirtualHoldTime(script: rig.script())

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, terminal: rig.terminal)

        #expect(run.code == FanctlExitCode.safeStateNotConfirmed.rawValue)
        let closing = Self.closingEvents(rig.standardError.events())
        #expect(closing.map { $0["event"] as? String } == ["failed"])
        let failure = closing.first?["failure"] as? [String: Any]
        #expect(failure?["exitCode"] as? Int == Int(FanctlExitCode.safeStateNotConfirmed.rawValue))
        #expect(closing.first?["endedBecause"] as? String == "outputClosed")
        #expect(
            rig.standardError.completeLines.count >= 2,
            "the diagnosis in words is on standard error too")
        #expect(Self.closingEvents(rig.standardOutput.events()).isEmpty)
        _ = harness.sessions
    }

    /// Text mode: the closing sentence is what a person reads, and it goes to standard error
    /// when standard output is parked, as the event does.
    @Test("In text, the closing sentence goes to standard error when standard output is parked")
    func textClosingSentence() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let rig = PumpRig(parkingFromLine: 1)
        defer { rig.release() }
        let time = VirtualHoldTime(script: rig.script(onceParked: { desk.send(.interrupt) }))

        let run = try await Harness.run(
            Harness.thirtySeconds, over: harness, time: time, desk: desk, terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(rig.standardError.consumed.contains("The hold ended: SIGINT was received."))
        #expect(!rig.standardOutput.consumed.contains("The hold ended"))
        _ = harness.sessions
    }
}
