import AeolusXPC
import FanKit
import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// Time that moves only when something sleeps, by exactly as much as it slept, and that can run
/// a script at each sleep.
///
/// `fanctl set` sleeps in heartbeats of ten seconds, and then in one-second polls while it waits
/// for the safe state, all on the one clock: a script keyed on the sleep's number reaches any
/// moment of a hold deterministically, without a real second passing and without asserting a
/// wall-clock bound ([#319](https://github.com/blamechris/Aeolus/issues/319)). A script that
/// **parks** (sleeps on the real clock for an hour) is woken by cancellation, which is exactly
/// how a signal reaches the loop in production, and then the sleep ends without time passing.
final class VirtualHoldTime: Sendable {

    typealias Script = @Sendable (_ number: Int, _ duration: Duration) async throws -> Void

    private struct State {
        var elapsed = Duration.zero
        var sleeps: [Duration] = []
    }

    private let origin = ContinuousClock.now
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let script: Script?
    private let stalls: [Int: Duration]

    /// - Parameters:
    ///   - script: Runs at the start of every sleep, with its one-based number and length,
    ///     before any time passes. If it throws, no time passes and the sleep throws.
    ///   - stalls: Extra time that passes after the sleep with that number, on top of its own
    ///     length: the machine that stalled while the process slept.
    init(script: Script? = nil, stalls: [Int: Duration] = [:]) {
        self.script = script
        self.stalls = stalls
    }

    var elapsed: Duration { state.withLock { $0.elapsed } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    /// Time passing with nothing asleep: a write that took a long time, a machine that stalled.
    func advance(by duration: Duration) {
        state.withLock { $0.elapsed += duration }
    }

    /// A hold that sleeps this many times is a loop that has stopped ending. Under a clock that
    /// costs nothing it would hang the suite rather than fail it, so the next sleep throws.
    static let runaway = 200

    var clock: SettleClock {
        SettleClock(
            now: { [origin, state] in origin + state.withLock { $0.elapsed } },
            sleep: { [state, script, stalls] duration in
                let number = state.withLock { value -> Int in
                    value.sleeps.append(duration)
                    return value.sleeps.count
                }
                if number > Self.runaway { throw CancellationError() }
                try await script?(number, duration)
                state.withLock { $0.elapsed += duration + (stalls[number] ?? .zero) }
            })
    }
}

/// The process `fanctl set` runs in, as far as the suite can reach it: a parent that can exit
/// and signals that can be sent, with nothing sent to this process.
final class SignalDesk: Sendable {

    private struct State {
        var handler: (@Sendable (HoldSignal) -> Void)?
        var parent: Int32
        var installs = 0
        var onInstall: HoldSignal?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(parent: Int32 = 4_242) {
        state = OSAllocatedUnfairLock(initialState: State(parent: parent))
    }

    var installs: Int { state.withLock { $0.installs } }

    /// A signal that arrives the moment the handlers are installed: before the first snapshot.
    func deliverOnInstall(_ signal: HoldSignal) {
        state.withLock { $0.onInstall = signal }
    }

    /// Sends `signal` to the command, as the process's handler would.
    func send(_ signal: HoldSignal) {
        let handler = state.withLock { $0.handler }
        handler?(signal)
    }

    /// The parent exits; the process is reparented to launchd.
    func parentExits() {
        state.withLock { $0.parent = 1 }
    }

    var environment: HoldEnvironment {
        HoldEnvironment(
            parentProcessID: { [state] in state.withLock { $0.parent } },
            installSignals: { [state] deliver in
                let early = state.withLock { value -> HoldSignal? in
                    value.handler = deliver
                    value.installs += 1
                    return value.onInstall
                }
                if let early { deliver(early) }
                return SignalSubscription.none
            })
    }
}

/// Runs the shipping `Fanctl.Set.run()` against one listener, the way `FanctlAutoTests` runs
/// `auto`: the real `HelperClient`, a real `NSXPCListener`, the real `HelperConnectionSession`.
/// Only the authority, where to write, how time passes and what the process is are doubles.
enum SetHarness {

    struct Run {
        let code: Int32?
        let output: RecordingTerminal
        let time: VirtualHoldTime
        let desk: SignalDesk
    }

    static func command(
        _ arguments: [String], endpoint: NSXPCListenerEndpoint, output: RecordingTerminal,
        time: VirtualHoldTime, desk: SignalDesk
    ) throws -> Fanctl.Set {
        var command = try #require(Fanctl.parseAsRoot(["set"] + arguments) as? Fanctl.Set)
        command.helper = HelperConnection(
            transport: .endpoint(endpoint), pinning: UnenforcedClientPinning(),
            deadlines: FanctlResetTests.unhurried)
        command.terminal = output.terminal
        command.clock = time.clock
        command.environment = desk.environment
        return command
    }

    static func run(
        _ arguments: [String], over harness: ClientListenerHarness,
        time: VirtualHoldTime = VirtualHoldTime(), desk: SignalDesk = SignalDesk(),
        output: RecordingTerminal = RecordingTerminal()
    ) async throws -> Run {
        let command = try command(
            arguments, endpoint: harness.endpoint, output: output, time: time, desk: desk)
        let code = await exitCode { try await command.run() }
        return Run(code: code, output: output, time: time, desk: desk)
    }

    /// `set 0 75% --for 30s`, with room for the options a test changes.
    static let thirtySeconds = ["0", "75%", "--for", "30s"]

    /// What the authority was asked, minus the reads and the teardown notice.
    static func writes(_ authority: SimulatedFanAuthority) async -> [String] {
        await authority.calls.filter { $0 != "snapshot" && $0 != "connectionDidInvalidate" }
    }

    static func count(_ call: String, in authority: SimulatedFanAuthority) async -> Int {
        await authority.calls.filter { $0 == call }.count
    }

    static func lines(_ run: Run) throws -> [[String: Any]] {
        try run.output.events()
    }

    static func event(_ name: String, in events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["event"] as? String == name }
    }
}
