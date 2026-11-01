import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #670's (b) through the composed authority: a client target below a fan's 50 % point, the
/// midpoint of `[F<n>Mn, F<n>Mx]`, is written at that point, on the helper side after the value
/// crossed the boundary (`CLAUDE.md` rule 7), and the snapshot reports the target the helper holds,
/// so a client shows the raised value (rule 6). The app's presets pass unchanged.
///
/// Two fans declaring `Mac16,5`'s 1,350 to 5,777 RPM, so the point is 3,563.5.
@Suite("No client target below the 50 % point (#670)", .timeLimit(.minutes(1)))
struct ClientFloorCompositionTests {

    static let point = 3_563.5

    static func machine() async -> LevelSixMachine {
        await LevelSixMachine(fans: [0: .automatic(at: 1_800), 1: .automatic(at: 1_800)])
    }

    /// Both fans at 2,000, below the point: each is written at 3,563.5, § 5 records 3,563.5, and
    /// the snapshot states it as the held target.
    ///
    /// **Mutation:** in `GovernedFanWriter.hold(_:of:)`, write `fan.target(for: goal)`. Run: red,
    /// 2,000 written, recorded and stated.
    @Test("A target below the 50 % point is written, recorded and reported at it")
    func aTargetBelowThePointIsRaised() async throws {
        let machine = await Self.machine()
        let lease = try await machine.lease(fans: [0, 1])

        try await machine.helper.authority.apply(
            Self.settings(2_000), leaseID: lease, from: machine.holder)

        let commanded = await machine.firmware.attempts.compactMap { attempt -> Double? in
            guard case .commandTarget(_, let rpm) = attempt else { return nil }
            return rpm
        }
        #expect(commanded == [Self.point, Self.point], "\(commanded)")
        let snapshot = try await machine.helper.authority.snapshot()
        for index in [0, 1] {
            #expect(
                await machine.helper.reclamationWatchdog.lastCommanded(ofFan: index)?.rpm
                    == Self.point)
            let fan = try #require(snapshot.fans.first { $0.index == index })
            #expect(fan.targetRPM == Self.point, "fan \(index) states \(fan.targetRPM as Any)")
        }
    }

    /// The app's presets, built as `AllFansControlActions` builds them, through
    /// `FanControlEnvelope.target(forPercent:)`: 50 % is 3,564, above the point, and 75 % and
    /// 100 % above that. Each is written and stated as asked, over both fans.
    @Test("The app's 50, 75 and 100 % presets pass unchanged", arguments: [50.0, 75, 100])
    func thePresetsPassUnchanged(percent: Double) async throws {
        let machine = await Self.machine()
        let lease = try await machine.lease(fans: [0, 1])
        let envelope = try #require(
            try? FanControlEnvelope.validating(declaredMinimumRPM: 1_350, declaredMaximumRPM: 5_777)
                .get())
        let preset = envelope.target(forPercent: percent).rpm
        #expect(preset >= Self.point)

        try await machine.helper.authority.apply(
            Self.settings(preset), leaseID: lease, from: machine.holder)

        let snapshot = try await machine.helper.authority.snapshot()
        for index in [0, 1] {
            let fan = try #require(snapshot.fans.first { $0.index == index })
            #expect(fan.targetRPM == preset, "fan \(index), \(percent) %: \(fan.targetRPM as Any)")
        }
    }

    /// Both fans at `rpm`.
    private static func settings(_ rpm: Double) -> [FanSetting] {
        [0, 1].map { FanSetting(fanIndex: $0, control: .fixed(rpm: rpm)) }
    }
}
