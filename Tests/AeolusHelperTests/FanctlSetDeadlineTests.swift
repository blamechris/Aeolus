import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// How `fanctl set`'s clock decides a hold is over: the deadline, a heartbeat that overruns it, a
/// sleep that wakes past it, and a timer that fails. The other endings are `FanctlSetStopTests`.
@Suite("fanctl set's deadline", .timeLimit(.minutes(1)))
struct FanctlSetDeadlineTests {

    typealias Harness = SetHarness

    /// A write that takes longer than the hold has left: the next heartbeat would sleep a
    /// negative time. The loop ends instead.
    ///
    /// **Mutation:** delete the `remaining <= .zero` check at the top of the loop in
    /// `SetCommand.heartbeats`. Run: red — it sleeps again, backwards.
    @Test("A heartbeat that runs past the deadline ends the hold without sleeping again")
    func aHeartbeatOverrunsTheDeadline() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let time = VirtualHoldTime()
        let output = RecordingTerminal(onStandardOutput: { number, _ in
            if number == 2 { time.advance(by: .seconds(25)) }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time, output: output)

        #expect(run.code == nil)
        #expect(time.sleeps == [.seconds(10)])
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(try output.events().last?["endedBecause"] as? String == "durationElapsed")
        _ = harness.sessions
    }

    /// A machine that stalled across the deadline wakes past it: the lease is about to be
    /// released, so it is not renewed first.
    ///
    /// **Mutation:** delete the `now() >= deadline` check after the sleep in
    /// `SetCommand.heartbeats`. Run: red — one more renewal.
    @Test("A sleep that returns past the deadline ends the hold without a last renewal")
    func aSleepReturnsPastTheDeadline() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let time = VirtualHoldTime(stalls: [1: .seconds(60)])

        let run = try await Harness.run(Harness.thirtySeconds, over: harness, time: time)

        #expect(run.code == nil)
        #expect(await Harness.count("renewLease", in: authority) == 0)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        _ = harness.sessions
    }

    /// The loop's own timer failing is neither a loss the helper reported nor an ending anyone
    /// asked for: the lease is released, and the exit is 1.
    ///
    /// **Mutation:** treat `.failed` as `.elapsed` in `SetCommand.heartbeats`. Run: red — the
    /// loop renews on every pass until the clock's runaway guard fails it.
    @Test("A timer that fails releases the lease and exits 1")
    func theTimerFails() async throws {
        let authority = SimulatedFanAuthority()
        let harness = ClientListenerHarness(authority: authority)
        let time = VirtualHoldTime(script: { number, _ in
            if number == 2 { throw CancellationError() }
        })

        let run = try await Harness.run(
            Harness.thirtySeconds + ["--json"], over: harness, time: time)

        #expect(run.code == FanctlExitCode.failure.rawValue)
        #expect(await Harness.count("renewLease", in: authority) == 1)
        #expect(await Harness.count("releaseLease", in: authority) == 1)
        #expect(await Harness.count("acquireLease", in: authority) == 1)
        let failed = try #require(try run.output.events().last)
        #expect(failed["event"] as? String == "failed")
        #expect(failed["endedBecause"] is NSNull)
        #expect(run.output.standardError.contains("timer failed"))
        _ = harness.sessions
    }
}
