import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` while its standard output **never drains**: the writer is parked in `write(2)`
/// and stays parked, for as long as the test says.
///
/// The review of #324 found that a pipe at the system's pipe-memory ceiling answers `poll`
/// "writable" and parks a bounded `write(2)` past every stop request, and that a terminal under
/// XOFF parks one too. No check made before a write can promise it will not park, so the claim
/// is not "writes do not park" but **the hold never waits on one**. Here a writer that parks is
/// put under the shipping `run()` (`PumpRig`), and every ending must still release the lease,
/// leave, say why, and do it in bounded virtual time.
///
/// What it takes for that to be a test and not a hope: the pump's thread is real, the clock is
/// virtual, and a virtual hold can sleep ten seconds in the microseconds before a real thread
/// has written a line it was handed. The clock's script quiesces first (`PumpRig.script`): it
/// waits, in real time and for at most two seconds, until the pump has written what it can.
@Suite("fanctl set against an output that never drains", .timeLimit(.minutes(1)))
struct FanctlSetBlockedWriterTests {

    typealias Harness = SetHarness

    /// An ending, and what makes it happen once standard output is parked.
    struct Ending: Sendable, CustomTestStringConvertible {
        let name: String
        /// `--for`.
        let holdFor: String
        let because: String
        let signal: String?
        let act: (@Sendable (SignalDesk) -> Void)?

        var testDescription: String { name }
    }

    static let endings = [
        Ending(
            name: "the consumer is judged not to be draining", holdFor: "30s",
            because: "outputClosed", signal: nil, act: nil),
        Ending(
            name: "a signal", holdFor: "30s", because: "signal", signal: "SIGINT",
            act: { $0.send(.interrupt) }),
        Ending(
            name: "the parent exits", holdFor: "30s", because: "parentExited", signal: nil,
            act: { $0.parentExits() }),
        Ending(
            name: "the deadline falls", holdFor: "11s", because: "durationElapsed", signal: nil,
            act: nil),
    ]

    /// The first `holding` line, at 10 s, parks the writer. Every ending that follows must
    /// release the lease and leave while it is parked, and the closing event must reach standard
    /// error whole, because standard output has a fragment on it.
    ///
    /// **Mutations:** make the hold wait for the writer (`waitUntilIdle` in place of the
    /// `hasTrouble` look at the top of `SetCommand.heartbeats`); drop the stall look there; send
    /// the closing event to standard output whatever the pump's state
    /// (`SetOutput.deliverClosing`). Run: red.
    @Test("Every ending releases and leaves while standard output is parked", arguments: endings)
    func everyEndingWhileParked(ending: Ending) async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        // Standard error is slow, not stopped: the run must wait for what it was handed.
        let rig = PumpRig(
            parkingFromLine: 2, standardError: BlockedWriter(parkingFromLine: nil, delay: 0.05))
        defer { rig.release() }
        var action: (@Sendable () -> Void)?
        if let act = ending.act { action = { act(desk) } }
        let time = VirtualHoldTime(script: rig.script(onceParked: action))

        let run = try await Harness.run(
            ["0", "75%", "--for", ending.holdFor, "--json"], over: harness, time: time,
            desk: desk, terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await authority.currentLease == nil)
        #expect(rig.standardOutput.isParked, "the run did not wait for the writer")
        #expect(run.time.elapsed >= .seconds(10), "the first heartbeat was made")
        #expect(run.time.elapsed < .seconds(15), "and the run was over within the bounds")

        // Standard output: a whole `started` line, then a fragment of the line it is parked on.
        #expect(rig.standardOutput.events().map { $0["event"] as? String } == ["started"])
        let fragment = rig.standardOutput.fragment
        #expect(!fragment.isEmpty)
        #expect(!fragment.contains("\"ended\"") && !fragment.contains("\"failed\""))

        // Standard error: the closing event, once, and it parses.
        let closing = rig.standardError.events()
        #expect(closing.map { $0["event"] as? String } == ["ended"])
        #expect(closing.first?["endedBecause"] as? String == ending.because)
        #expect(closing.first?["signal"] as? String == ending.signal)

        // Let the reader catch up: the closing event was handed to one stream only.
        await rig.drain()
        let eventually = rig.standardOutput.events().map { $0["event"] as? String }
        #expect(eventually == ["started", "holding"], "nothing was queued behind the parked line")
        _ = harness.sessions
    }

    /// The very first line parks. A signal that follows is still a signal: the release is not
    /// behind the output, and neither is the way out.
    @Test("A start line that parks does not keep a signal from releasing the lease")
    func startLineParked() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let rig = PumpRig(parkingFromLine: 1)
        defer { rig.release() }
        let time = VirtualHoldTime(script: rig.script(onceParked: { desk.send(.interrupt) }))

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk,
            terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(await Harness.count("apply", in: authority) == 1)
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(run.time.elapsed < .seconds(5))
        let closing = rig.standardError.events()
        #expect(closing.first?["endedBecause"] as? String == "signal")
        #expect(rig.standardOutput.events().isEmpty, "not one whole line reached standard output")
        _ = harness.sessions
    }

    /// Neither stream will take the closing event. The run still leaves, in bounded time, with
    /// the exit code the helper's report earned, and says so on neither: nothing can.
    ///
    /// **Mutation:** wait for standard error without a bound (`until: .distantFuture` in
    /// `flushStandardError`). Run: red — the virtual clock runs away and the sleep throws.
    @Test("With both streams parked the run still leaves, and the lease is still released")
    func bothParked() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let desk = SignalDesk()
        let rig = PumpRig(
            standardOutput: BlockedWriter(parkingFromLine: 2),
            standardError: BlockedWriter(parkingFromLine: 1))
        defer { rig.release() }
        let time = VirtualHoldTime(script: rig.script(onceParked: { desk.send(.interrupt) }))

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, desk: desk,
            terminal: rig.terminal)

        #expect(run.code == nil)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(rig.standardOutput.isParked && rig.standardError.isParked)
        #expect(run.time.elapsed < .seconds(16))
        #expect(rig.standardError.events().isEmpty, "the one stream left was wedged too")
        _ = harness.sessions
    }
}
