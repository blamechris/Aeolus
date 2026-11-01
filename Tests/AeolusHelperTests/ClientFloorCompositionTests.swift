import AeolusXPC
import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// #670's (b) through the composed authority: a client target below a fan's client floor, 65 % of
/// the way from `F<n>Mn` to `F<n>Mx`, is written at the floor, on the helper side after the value
/// crossed the boundary (`CLAUDE.md` rule 7), and the snapshot reports the target the helper holds,
/// so a client shows the raised value (rule 6). ADR 0014's minimal-run amendment, item 7 (b), as
/// re-ruled on 2026-11-01 from the midpoint.
///
/// Two fans declaring `Mac16,5`'s 1,350 to 5,777 RPM unless a test says otherwise, so the floor is
/// 4,227.55: the app's 50 % preset, 3,564, is now below it.
@Suite("No client target below the client floor (#670)", .timeLimit(.minutes(1)))
struct ClientFloorCompositionTests {

    /// 1,350 + 0.65 × 4,427.
    static let floor = 4_227.55

    static func machine(
        _ fans: [Int: ScriptedControlPlane.FanCondition] = [
            0: .automatic(at: 1_800), 1: .automatic(at: 1_800),
        ]
    ) async -> LevelSixMachine {
        await LevelSixMachine(fans: fans)
    }

    /// Both fans at 2,000, below the floor: each is written at 4,227.55, § 5 records 4,227.55, and
    /// the snapshot states it as the held target.
    ///
    /// **Mutation:** in `GovernedFanWriter.hold(_:of:)`, write `fan.target(for: goal)`. Run: red,
    /// 2,000 written, recorded and stated. **Mutation:** in `CommandableFan.clientTarget(for:)`,
    /// return `clamped` unconditionally, removing the raise. Run: red, the same.
    @Test("A target below the client floor is written, recorded and reported at it")
    func aTargetBelowTheFloorIsRaised() async throws {
        let machine = await Self.machine()
        let lease = try await machine.lease(fans: [0, 1])

        try await machine.helper.authority.apply(
            Self.settings(2_000), leaseID: lease, from: machine.holder)

        let commanded = await Self.commanded(on: machine)
        #expect(commanded == [Self.floor, Self.floor], "\(commanded)")
        let snapshot = try await machine.helper.authority.snapshot()
        for index in [0, 1] {
            #expect(
                await machine.helper.reclamationWatchdog.lastCommanded(ofFan: index)?.rpm
                    == Self.floor)
            let fan = try #require(snapshot.fans.first { $0.index == index })
            #expect(fan.targetRPM == Self.floor, "fan \(index) states \(fan.targetRPM as Any)")
        }
    }

    /// The app's presets, built as `AllFansControlActions` builds them, through
    /// `FanControlEnvelope.target(forPercent:)`. 50 % is 3,564, below the floor for the first time
    /// since #670, so it is written and stated at the floor; 75 % and 100 % are above it and pass
    /// as asked. Over both fans, and the `apply` is answered applied: nothing is refused.
    ///
    /// **Mutation:** the raise removed, as above. Run: red on the 50 % row alone.
    @Test(
        "The app's 50 % preset is held at the floor, and 75 and 100 % pass unchanged",
        arguments: [50.0, 75, 100])
    func thePresets(percent: Double) async throws {
        let machine = await Self.machine()
        let lease = try await machine.lease(fans: [0, 1])
        let envelope = try #require(
            try? FanControlEnvelope.validating(declaredMinimumRPM: 1_350, declaredMaximumRPM: 5_777)
                .get())
        let preset = envelope.target(forPercent: percent).rpm
        let held = max(preset, Self.floor)
        #expect(percent != 50 || preset < Self.floor, "the 50 % preset is not below the floor")

        try await machine.helper.authority.apply(
            Self.settings(preset), leaseID: lease, from: machine.holder)

        #expect(await Self.commanded(on: machine) == [held, held])
        let snapshot = try await machine.helper.authority.snapshot()
        #expect(snapshot.activeLease?.id == lease)
        for index in [0, 1] {
            let fan = try #require(snapshot.fans.first { $0.index == index })
            #expect(fan.targetRPM == held, "fan \(index), \(percent) %: \(fan.targetRPM as Any)")
        }
    }

    /// Each fan's floor is its own envelope's: fan 0 declares 1,350 to 5,777 (floor 4,227.55) and
    /// fan 1 1,200 to 4,800 (floor 3,540). Both are asked for 2,000 and each is held at its own
    /// floor (reviewer T's T6: a floor hard-coded to one machine, or taken from fan 0 for every
    /// fan, ships green over identical fans).
    ///
    /// **Mutation:** in `CommandableFan.clientFloorRPM`, return `min(4_227.55,
    /// envelope.declaredMaximumRPM)`. Run: red, fan 1 held at 4,227.55.
    @Test("Each fan is held at its own envelope's floor")
    func eachFanHasItsOwnFloor() async throws {
        let machine = await Self.machine([
            0: .automatic(at: 1_800),
            1: ScriptedControlPlane.FanCondition(minimumRPM: 1_200, maximumRPM: 4_800),
        ])
        let lease = try await machine.lease(fans: [0, 1])

        try await machine.helper.authority.apply(
            Self.settings(2_000), leaseID: lease, from: machine.holder)

        #expect(await Self.commanded(on: machine) == [Self.floor, 3_540])
        let snapshot = try await machine.helper.authority.snapshot()
        #expect(snapshot.fans.first { $0.index == 0 }?.targetRPM == Self.floor)
        #expect(snapshot.fans.first { $0.index == 1 }?.targetRPM == 3_540)
    }

    /// Both fans at `rpm`.
    private static func settings(_ rpm: Double) -> [FanSetting] {
        [0, 1].map { FanSetting(fanIndex: $0, control: .fixed(rpm: rpm)) }
    }

    /// Every target the firmware was asked to take, in order.
    private static func commanded(on machine: LevelSixMachine) async -> [Double] {
        await machine.firmware.attempts.compactMap { attempt -> Double? in
            guard case .commandTarget(_, let rpm) = attempt else { return nil }
            return rpm
        }
    }
}
