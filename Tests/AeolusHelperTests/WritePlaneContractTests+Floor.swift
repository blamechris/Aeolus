import Foundation
import Testing
import os

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
            case .floorNotHeld:
                stage = ScriptedControlPlane.Stage.nominal().holdingNoTarget(ofFan: 0)
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
            case .floorRefused:
                await fixture.firmware.queueWrites(to: target, [.refuses(code: 0x85)])
            case .floorNotHeld:
                await fixture.firmware.queueWrites(to: target, [.acceptsWithoutApplying])
            case .atRest: break
            }
            let mark = await fixture.prepared()
            let firmware = fixture.firmware
            return Harness(
                plane: fixture.plane, ledger: try fixture.ledger,
                keyWrites: { fixture.writes(since: mark).map(Self.normalised) },
                duringNextModeWrite: { effect in
                    await firmware.onAfter(.write(Self.modeZero), run: effect)
                },
                roundTripsPerTurn: { fixture.roundTripsPerTurn(since: mark) })
        }
    }

    private static func isRefusedControl(_ error: FanControlPlaneError?) -> Bool {
        if case .firmwareRefusedControl? = error { return true }
        return false
    }

    /// The floor rule on each plane: at rest the engaging turn writes the mode and then the floor,
    /// and the fan is engaged at it; under load it writes the mode alone and keeps Apple's target;
    /// a floor refused, or not held at its read-back, fails the step after the floor's write and
    /// the fan is not engaged. The `.fan` restore this test then issues by hand — the one the
    /// driver's undo issues — hands it back; that the driver itself issues it, through the composed
    /// graph, is `ProductionEngagementAtRestTests`'. No arm ever writes an `F1` key.
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
                try await harness.plane.engageManualControl(of: Self.fan(0)) == .engaged, "\(label)"
            )
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

// MARK: - A restore requested mid-step

extension WritePlaneContractTests {

    /// A restore of the engaging fan requested in the middle of the engaged step's turn — after its
    /// mode write, before its raise — does not stop the raise: no epoch re-check precedes it
    /// (`SMCWriteTurns.holdFloor`, and ADR 0014 D4: "That order is correct"). The step raises and
    /// answers `.engaged`; the restore's own turn comes after it, so its mode write is the last
    /// word on the fan, and the engaged set is empty. On the production arm that is two turns, the
    /// engaged step's eight round trips and the restore's one.
    ///
    /// **Mutation (production only):** in `SMCWriteTurns.step`, re-check the epoch before the
    /// floor hold — `guard ledger.isCurrent(fanAt: index) else { throw
    /// FanControlPlaneError.supersededAfterWrite }`. Run: red on the smcPlane arm: the step throws,
    /// and no floor is written.
    @Test(
        "Both planes raise the floor before a restore requested mid-step, which lands after",
        arguments: Arm.allCases)
    func aRestoreRequestedMidStepLandsAfterTheRaise(_ arm: Arm) async throws {
        let harness = try await Self.floorHarness(arm, .atRest)
        let (plane, ledger) = (harness.plane, harness.ledger)
        let restore = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)
        await harness.duringNextModeWrite {
            ledger.restoreRequested(.fan(0))
            restore.withLock { $0 = Task { try await plane.restoreToAutomatic(.fan(0)) } }
        }

        plane.beginEngagement(fanAt: 0)
        let step = try await plane.engageManualControl(of: Self.fan(0))
        try await #require(restore.withLock { $0 }, "\(arm): the hook did not run").value
        let turns = harness.roundTripsPerTurn()

        #expect(step == .engaged, "\(arm)")
        #expect(await harness.keyWrites() == ["F0Md=1", "F0Tg", "F0Md=0"], "\(arm)")
        #expect(ledger.engagedFans.isEmpty, "\(arm)")
        #expect(try await plane.readControlState(ofFan: 0).mode == .automatic, "\(arm)")
        #expect(turns == (arm == .smcPlane ? [8, 1] : nil), "\(arm): \(String(describing: turns))")
    }
}
