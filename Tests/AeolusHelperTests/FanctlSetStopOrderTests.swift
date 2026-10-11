import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// What `fanctl set` says ended the hold when standard output failed, and a stop request
/// (a signal, the parent exiting, the deadline) arrived with it.
///
/// A write that gives up is the reader not making room only if nothing else asked the hold to
/// stop. The recorder here fails a line and makes the thing happen while it does, which is all
/// the ordering needs; a writer that really parks is `FanctlSetBlockedWriterTests`.
@Suite("fanctl set's stop requests outrank a write that gave up", .timeLimit(.minutes(1)))
struct FanctlSetStopOrderTests {

    typealias Harness = SetHarness

    /// What happens while a line waits, and what the hold must say it ended because of.
    struct StopCase: Sendable, CustomTestStringConvertible {
        let name: String
        let signal: Bool
        let parent: Bool
        let deadline: Bool
        let because: String
        let signalName: String?

        var testDescription: String { name }

        /// Makes the things this case is about happen.
        func happen(_ desk: SignalDesk, _ time: VirtualHoldTime) {
            if signal { desk.send(.interrupt) }
            if parent { desk.parentExits() }
            if deadline { time.advance(by: .seconds(60)) }
        }
    }

    /// A write that gives up is the reader not making room only if nothing else asked the hold to
    /// stop. A signal, the parent exiting, or the deadline passing while the line waited is the
    /// reason the hold ends, and the closing event says so; when more than one happened, the
    /// order they are looked in decides: a signal, then the parent, then the deadline.
    ///
    /// **Mutations:** drop the `watch.reason ??` from the `holding` branch in
    /// `SetCommand.heartbeats`; drop a branch of `StopWatch.reason`; look at the deadline before
    /// the signal, or at the parent before the signal. Run: red on the cases that name them.
    @Test(
        "A stop request that arrives while a heartbeat's write waits is why the hold ends",
        arguments: [
            StopCase(
                name: "signal", signal: true, parent: false, deadline: false,
                because: "signal", signalName: "SIGINT"),
            StopCase(
                name: "parent", signal: false, parent: true, deadline: false,
                because: "parentExited", signalName: nil),
            StopCase(
                name: "deadline", signal: false, parent: false, deadline: true,
                because: "durationElapsed", signalName: nil),
            StopCase(
                name: "signal and deadline", signal: true, parent: false, deadline: true,
                because: "signal", signalName: "SIGINT"),
            StopCase(
                name: "parent and deadline", signal: false, parent: true, deadline: true,
                because: "parentExited", signalName: nil),
            StopCase(
                name: "signal and parent", signal: true, parent: true, deadline: false,
                because: "signal", signalName: "SIGINT"),
        ])
    func aStopRequestOutranksAFailedWrite(stop: StopCase) async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime()
        // Line 1 is `started`, line 2 the first `holding`, which does not arrive; the thing under
        // test happens as it is handed over. Standard output has failed by then, so the closing
        // event goes to standard error.
        let output = RecordingTerminal(
            acceptingStandardOutputLines: 1,
            onStandardOutput: { number, _ in
                if number == 2 { stop.happen(desk, time) }
            })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk,
            output: output)

        #expect(run.code == nil)
        let closing = try #require(output.standardErrorEvents().last)
        #expect(closing["event"] as? String == "ended")
        #expect(closing["endedBecause"] as? String == stop.because)
        #expect(closing["signal"] as? String == stop.signalName)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        _ = harness.sessions
    }

    /// The same for the start line, which fails before the first look at the clock.
    ///
    /// **Mutation:** as above: the one `watch.reason ??` at the top of the loop decides both.
    /// Run: red on each.
    @Test(
        "A stop request that arrives while the start line waits is why the hold ends",
        arguments: [
            StopCase(
                name: "signal", signal: true, parent: false, deadline: false,
                because: "signal", signalName: "SIGINT"),
            StopCase(
                name: "parent", signal: false, parent: true, deadline: false,
                because: "parentExited", signalName: nil),
            StopCase(
                name: "signal and parent", signal: true, parent: true, deadline: false,
                because: "signal", signalName: "SIGINT"),
        ])
    func aStopRequestOutranksAFailedStartLine(stop: StopCase) async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let time = VirtualHoldTime()
        let output = RecordingTerminal(
            acceptingStandardOutputLines: 0,
            onStandardOutput: { number, _ in
                if number == 1 { stop.happen(desk, time) }
            })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk,
            output: output)

        #expect(run.code == nil)
        let closing = try #require(output.standardErrorEvents().last)
        #expect(closing["event"] as? String == "ended")
        #expect(closing["endedBecause"] as? String == stop.because)
        #expect(closing["signal"] as? String == stop.signalName)
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        _ = harness.sessions
    }
}
