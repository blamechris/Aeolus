import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper
@testable import AeolusXPCClient
@testable import fanctl

/// `fanctl set` against the composed helper, level 6 and the lease core included, over two
/// scripted fans with `Mac16,5`'s range (1350 to 5777 RPM), under #670's two rules: the helper
/// grants every fan together or none, and holds no client target below a fan's client floor, 65 %
/// of its declared range (4227.55 RPM here). The `set` suites beside this one run against
/// `SimulatedFanAuthority`, which applies neither rule.
@Suite(
    "fanctl set against the helper's every-fan lease and client floor (#670)",
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

    /// `set all 20%` and `set all 50%` ask for 2235 and 3564 RPM; the helper writes and holds
    /// 4227.55 on both fans. The run is a hold, as any other: it starts, holds for its ten
    /// seconds and ends with exit 0, never pending, refused or `controlLost`, and the start line
    /// names the helper's target, not the one asked for (`CLAUDE.md` rule 6). The 50 % row is the
    /// app's preset, below the floor since the floor moved to 65 %.
    ///
    /// **Mutation:** in `CommandableFan.clientTarget(for:)`, return `clamped` unconditionally,
    /// removing the raise. Run: red, 2235 and 3564 written and named.
    @Test(
        "set all below the client floor is held at the floor, and says the helper's target",
        arguments: [(20, 2235), (50, 3564)])
    func everyFanBelowTheFloor(percent: Int, asked: Int) async throws {
        let machine = await Self.twoFans()
        let harness = ClientListenerHarness(authority: machine.helper.authority)

        let run = try await SetHarness.run(["all", "\(percent)%", "--for", "10s"], over: harness)

        #expect(run.code == nil, "\(run.output.standardError)")
        #expect(!run.output.standardError.contains("lost"), "\(run.output.standardError)")
        #expect(await Self.commanded(on: machine) == [4_227.55, 4_227.55])
        let text = run.output.standardOutput
        for fan in 0...1 {
            #expect(
                text.contains(
                    "Holding fan \(fan) at 4227.55 RPM target (the helper's, not the \(asked) RPM "
                        + "that \(percent)% asked for; firmware 1350–5777 RPM)"),
                "\(text)")
        }
        #expect(!text.contains("\(asked) RPM target"), "\(text)")
        #expect(text.contains("The hold ended"), "\(text)")
        _ = harness.sessions
    }

    /// 75 % is 4670 RPM here, above the floor: written and reported unchanged.
    @Test("set all at 75% holds both fans at 4670 RPM and says so")
    func everyFanAboveTheFloor() async throws {
        let machine = await Self.twoFans()
        let harness = ClientListenerHarness(authority: machine.helper.authority)

        let run = try await SetHarness.run(["all", "75%", "--for", "10s"], over: harness)

        #expect(run.code == nil, "\(run.output.standardError)")
        #expect(await Self.commanded(on: machine) == [4_670, 4_670])
        let text = run.output.standardOutput
        for fan in 0...1 {
            #expect(
                text.contains(
                    "Holding fan \(fan) at 75% (4670 RPM target; firmware 1350–5777 RPM)"),
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
