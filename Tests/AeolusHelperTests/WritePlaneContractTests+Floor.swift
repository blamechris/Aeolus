import Foundation
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The engaged turn's floor rule as one contract over both planes (ADR 0014's P1′ amendment,
/// decision 4). #637 built the rule on `main` and on the scripted double; until this scenario ran
/// over the production plane too, the two could decide it differently with nothing red, the class
/// of defect #417 was. In a file of its own so the suite's file stays inside `file_length`.
extension WritePlaneContractTests {

    /// Where fan 0 starts, and how the firmware answers the floor's write.
    enum FloorScenario: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Apple has the fan stopped: raw `3`, target 0. The engaged turn raises it.
        case atRest
        /// Apple is spinning the fan at P1's sixteen-way plateau: raw `0`, target 3455. Nothing
        /// is written but the mode.
        case underLoad
        /// At rest, and the floor's write is refused.
        case floorRefused
        /// At rest, and the floor's write is accepted and not held at the read-back.
        case floorNotHeld

        var testDescription: String { rawValue }
    }

    /// A plane under the floor contract, fan 0 placed as `scenario` says and fan 1 at rest.
    static func floorHarness(_ arm: Arm, _ scenario: FloorScenario) async throws -> Harness {
        switch arm {
        case .scripted:
            let fan0: ScriptedControlPlane.FanCondition =
                scenario == .underLoad ? .automatic(at: 3_455) : .stoppedByApple
            let stage: ScriptedControlPlane.Stage
            switch scenario {
            case .floorRefused: stage = .nominal(targetWrites: .refused(reason: "0x85"))
            case .floorNotHeld: stage = ScriptedControlPlane.Stage.nominal().holdingNoTarget(ofFan: 0)
            case .atRest, .underLoad: stage = .nominal()
            }
            let plane = ScriptedControlPlane(
                fans: [0: fan0, 1: .stoppedByApple], stages: [stage], unlock: .naive)
            return Harness(
                plane: plane, ledger: plane.ledger,
                keyWrites: { await plane.keyWrites.map(Self.normalised) },
                duringNextModeWrite: { effect in await plane.duringNextModeWrite(effect) })
        case .smcPlane:
            let fixture = WritePlaneFixture(stoppedByApple: [0, 1])
            let target = smcKey("F0Tg")
            switch scenario {
            case .underLoad: await fixture.firmware.spinByApple(fan: 0, at: 3_455)
            case .floorRefused: await fixture.firmware.queueWrites(to: target, [.refuses(code: 0x85)])
            case .floorNotHeld: await fixture.firmware.queueWrites(to: target, [.acceptsWithoutApplying])
            case .atRest: break
            }
            let mark = await fixture.prepared()
            let firmware = fixture.firmware
            return Harness(
                plane: fixture.plane, ledger: try fixture.ledger,
                keyWrites: { fixture.writes(since: mark).map(Self.normalised) },
                duringNextModeWrite: { effect in
                    await firmware.onAfter(.write(Self.modeZero), run: effect)
                })
        }
    }

    private static func isRefusedControl(_ error: FanControlPlaneError?) -> Bool {
        if case .firmwareRefusedControl? = error { return true }
        return false
    }

    /// The floor rule on each plane: at rest the engaging turn writes the mode and then the floor,
    /// and the fan is engaged at it; under load it writes the mode alone and keeps Apple's target;
    /// a floor refused, or not held at its read-back, fails the step after the floor's write, the
    /// fan is not engaged, and the undo — the driver's `.fan` restore — hands it back. No arm ever
    /// writes an `F1` key.
    ///
    /// **Mutation (production only):** in `SMCWriteTurns.step`, delete `try holdFloor(of: fan,
    /// log: log, on: channel)`. Run: red on the smcPlane arm, at rest and both refusals; green on
    /// the scripted arm.
    @Test(
        "Both planes hold an engaged fan at its floor, and undo a floor not taken",
        arguments: Arm.allCases, FloorScenario.allCases)
    func bothPlanesHoldTheFloor(_ arm: Arm, _ scenario: FloorScenario) async throws {
        let harness = try await Self.floorHarness(arm, scenario)
        let label = "\(arm), \(scenario)"

        harness.plane.beginEngagement(fanAt: 0)
        switch scenario {
        case .atRest, .underLoad:
            #expect(
                try await harness.plane.engageManualControl(of: Self.fan(0)) == .engaged, "\(label)")
            let expected = scenario == .atRest ? 1_350.0 : 3_455
            #expect(
                try await harness.plane.readControlState(ofFan: 0).target == .rpm(expected),
                "\(label)")
            #expect(harness.ledger.engagedFans == [0], "\(label)")
            #expect(
                await harness.keyWrites()
                    == (scenario == .atRest ? ["F0Md=1", "F0Tg"] : ["F0Md=1"]), "\(label)")
        case .floorRefused, .floorNotHeld:
            let error = await #expect(throws: FanControlPlaneError.self, "\(label)") {
                try await harness.plane.engageManualControl(of: Self.fan(0))
            }
            if scenario == .floorNotHeld {
                #expect(
                    error == .targetNotConfirmed(index: 0, commandedRPM: 1_350, readBackRPM: 0),
                    "\(label): \(String(describing: error))")
            } else {
                #expect(Self.isRefusedControl(error), "\(label): \(String(describing: error))")
            }
            #expect(harness.ledger.engagedFans.isEmpty, "\(label)")
            try await harness.plane.restoreToAutomatic(.fan(0))
            #expect(await harness.keyWrites() == ["F0Md=1", "F0Tg", "F0Md=0"], "\(label)")
            #expect(
                try await harness.plane.readControlState(ofFan: 0).mode == .automatic, "\(label)")
        }
        #expect(!(await harness.keyWrites()).contains { $0.hasPrefix("F1") }, "\(label)")
    }
}
