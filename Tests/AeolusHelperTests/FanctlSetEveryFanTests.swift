import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` against the composed helper, level 6 and the lease core included, over two
/// scripted fans with `Mac16,5`'s range (1350 to 5777 RPM), under #670's two rules: the helper
/// grants every fan together or none, and holds no client target below a fan's 50 % point
/// (3563.5 RPM here). The `set` suites beside this one run against `SimulatedFanAuthority`,
/// which applies neither rule.
@Suite(
    "fanctl set against the helper's every-fan lease and 50 % point (#670)",
    .timeLimit(.minutes(1)))
struct FanctlSetEveryFanTests {

    /// `set 0` on a two-fan machine is the helper's `leaseMustCoverEveryFan`, exit 4, with the
    /// reason's own text, and nothing written.
    @Test("set on one fan of two is refused, exit 4, and says to ask for every fan")
    func oneFanOfTwoIsRefused() async throws {
        let machine = await Self.twoFans()
        let harness = ClientListenerHarness(authority: machine.helper.authority)

        let run = try await SetHarness.run(["0", "75%", "--for", "30s"], over: harness)

        #expect(run.code == FanctlExitCode.manualControlRefused.rawValue)
        #expect(run.output.standardError.contains("every fan together or of none"))
        #expect(run.output.standardError.contains("fanctl set all"))
        #expect(await machine.helper.leases.leaseCount == 0)
        #expect(await Self.commanded(on: machine).isEmpty)
        _ = harness.sessions
    }

    /// `set all 20%` asks for 2235 RPM; the helper writes and holds 3563.5 on both fans, and the
    /// start line names the helper's target, not the one asked for (`CLAUDE.md` rule 6).
    @Test("set all below the 50 % point is held at the point, and says the helper's target")
    func everyFanBelowThePoint() async throws {
        let machine = await Self.twoFans()
        let harness = ClientListenerHarness(authority: machine.helper.authority)

        let run = try await SetHarness.run(["all", "20%", "--for", "10s"], over: harness)

        #expect(run.code == nil, "\(run.output.standardError)")
        #expect(await Self.commanded(on: machine) == [3_563.5, 3_563.5])
        let text = run.output.standardOutput
        for fan in 0...1 {
            #expect(
                text.contains(
                    "Holding fan \(fan) at 3563.50 RPM target (the helper's, not the 2235 RPM "
                        + "that 20% asked for; firmware 1350–5777 RPM)"),
                "\(text)")
        }
        #expect(!text.contains("2235 RPM target"), "\(text)")
        _ = harness.sessions
    }

    /// The app's 50 % preset is 3564 RPM here, above the point: written and reported unchanged.
    @Test("set all at 50% holds both fans at 3564 RPM and says so")
    func everyFanAtFiftyPercent() async throws {
        let machine = await Self.twoFans()
        let harness = ClientListenerHarness(authority: machine.helper.authority)

        let run = try await SetHarness.run(["all", "50%", "--for", "10s"], over: harness)

        #expect(run.code == nil, "\(run.output.standardError)")
        #expect(await Self.commanded(on: machine) == [3_564, 3_564])
        let text = run.output.standardOutput
        for fan in 0...1 {
            #expect(
                text.contains(
                    "Holding fan \(fan) at 50% (3564 RPM target; firmware 1350–5777 RPM)"),
                "\(text)")
        }
        _ = harness.sessions
    }

    private static func twoFans() async -> LevelSixMachine {
        await LevelSixMachine(fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
    }

    /// Every target the firmware was asked to take, in order.
    private static func commanded(on machine: LevelSixMachine) async -> [Double] {
        await machine.firmware.attempts.compactMap { attempt -> Double? in
            guard case .commandTarget(_, let rpm) = attempt else { return nil }
            return rpm
        }
    }
}
