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
    func start() throws -> Task<Int32?, Never> {
        let command = try SetHarness.command(
            SetHarness.thirtySeconds + ["--json"], endpoint: harness.endpoint, output: output,
            time: time, desk: SignalDesk())
        return Task { await exitCode { try await command.run() } }
    }

    /// Runs to the end with nobody touching it.
    ///
    /// **A helper that is busy and nothing waiting on it leaves the clock where it is**, and the
    /// run would then wait for the end of a request that cannot end. In production time passes on
    /// its own; here only a wait for the helper moves it, and that is the keeper's job. So a run
    /// that has not finished in a moment is reported as that, and let go.
    func run() async throws -> Int32? {
        let running = try start()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await running.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            let why =
                "the run did not finish: the helper was still working on `apply` and nothing "
                + "was waiting for it, so no renewal was ever sent and the clock stood still"
            Issue.record(Comment(rawValue: why))
            time.advance(by: .seconds(3_600))
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

    /// The longest the helper went without a renewal, counted from the grant, among the renewals
    /// that landed and up to `end` (virtual seconds after the grant).
    func longestSilence(until end: Duration) async -> Duration {
        var previous = Duration.zero
        var longest = Duration.zero
        for offset in await renewalOffsets() where offset <= end {
            longest = max(longest, offset - previous)
            previous = offset
        }
        return longest
    }

    func events() throws -> [[String: Any]] { try output.events() }
}
