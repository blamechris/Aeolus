import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// One run of `fanctl set` for `FanctlSetRenewalTests`: leases live thirty virtual seconds, and the
/// helper works on `apply` for `applyTakes` of the same clock before it answers.
struct RenewalScene {

    /// How long the helper keeps a lease nobody renews.
    static let lifetime = Duration.seconds(30)

    let authority = SimulatedFanAuthority()
    let time = VirtualHoldTime()
    let gate = AsyncSignal()
    let harness: ClientListenerHarness
    let output = RecordingTerminal()

    init(
        applyTakes: Duration, configure: (SimulatedFanAuthority) async -> Void = { _ in }
    ) async {
        await authority.expiringLeases(after: Self.lifetime, on: time.clock)
        await authority.holdingApply(until: gate)
        await configure(authority)
        harness = ClientListenerHarness(authority: authority)
        let gate = self.gate
        time.helperBusy(for: applyTakes) { await gate.signal() }
    }

    /// Starts `fanctl set 0 75% --for 30s --json` and returns at once.
    ///
    /// - Parameter deadlines: The client's own, when a test wants the shipping ones rather than
    ///   the harness's. A renewal that is not answered then times out in the shipping five
    ///   seconds, well inside an `apply`'s fifty-seven.
    /// - Returns: The running command, yielding its exit code (`nil` for exit 0).
    /// - Throws: If the command cannot be built.
    func start(deadlines: HelperClientDeadlines? = nil) throws -> Task<Int32?, Never> {
        var command = try SetHarness.command(
            SetHarness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())
        if let deadlines {
            command.helper = HelperConnection(
                transport: .endpoint(harness.endpoint), pinning: UnenforcedClientPinning(),
                deadlines: deadlines)
        }
        return Task { await exitCode { try await command.run() } }
    }

    /// Runs to the end with nobody touching it.
    ///
    /// **A helper that is busy and nothing waiting on it leaves the clock where it is**, and the
    /// run would then wait for the end of a request that cannot end. In production time passes on
    /// its own; here only a wait for the helper moves it, and that is the keeper's job. So a run
    /// that has not finished in a moment is reported as that, and let go.
    ///
    /// **A moment is ten seconds of the watchdog's own turns, not ten seconds on the wall.** On
    /// CI's pool of one the tests of this target ran for 150 to 198 s (run 41341626972), as every
    /// continuation waits its turn behind the rest of the suite. A single
    /// `Task.sleep(for: .seconds(10))` is ready after ten wall seconds whether or not the pool has
    /// given the run a turn in them, and would then report a run that was only waiting. A thousand
    /// sleeps of ten milliseconds are ten seconds' worth of turns the pool gave the watchdog (a
    /// little over ten, 12.5 s measured, when the pool is free): while it is away, the count
    /// stands still.
    ///
    /// **The recovery happens inside the watchdog child, before the group is left.** Leaving a
    /// task group waits for every child, and a child that waits on the command cannot finish
    /// until the command does: a recovery run after the group would never run, and a mutation
    /// that never starts the keeper would sit out the suite's whole time limit instead of failing
    /// at once.
    func run() async throws -> Int32? {
        let running = try start()
        let time = self.time
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await running.value }
            group.addTask {
                for _ in 0..<1_000 {
                    try? await Task.sleep(for: .milliseconds(10))
                    guard !Task.isCancelled else { return }
                }
                let why =
                    "the run did not finish: the helper was still working on `apply` and nothing "
                    + "was waiting for it, so no renewal was ever sent and the clock stood still"
                Issue.record(Comment(rawValue: why))
                time.advance(by: .seconds(3_600))
            }
            await group.next()
            group.cancelAll()
        }
        let code = await running.value
        _ = harness.sessions
        return code
    }

    /// Every renewal that landed, as the time after the grant it landed at.
    func renewalOffsets() async -> [Duration] {
        let grant = await authority.grantInstants.first ?? time.now
        return await authority.renewalInstants.map { $0 - grant }
    }

    /// The longest the lease went without a renewal, counted from the grant, through the last
    /// renewal to the instant the lease was **released**: the final interval is the one the
    /// helper's own clock was still running on, and it is as long as any other.
    func longestSilence() async -> Duration {
        let grant = await authority.grantInstants.first ?? time.now
        var points = await renewalOffsets()
        if let released = await authority.releaseInstants.first { points.append(released - grant) }
        var previous = Duration.zero
        var longest = Duration.zero
        for point in points {
            longest = max(longest, point - previous)
            previous = point
        }
        return longest
    }

    func events() throws -> [[String: Any]] { try output.events() }
}
