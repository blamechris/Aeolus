import SMCCore
import Testing

@testable import AeolusHelper

/// Every failure path E5 has to survive, driven through the mock — because a mock whose
/// failure paths are not themselves tested is a mock that will let the mechanisms built on
/// it pass while proving nothing.
///
/// These are the scenarios #99, #101, #102 and #103 will each script for their own
/// mechanism. Asserting them here first is what makes those tests worth writing.
@Suite("ScriptedControlPlane scenarios")
struct ScriptedControlPlaneTests {

    private static let cpuKey = smcKey("TC0P")
    private static let gpuKey = smcKey("TG0P")

    // MARK: - The firmware refuses

    /// `SAFETY.md` has no row for "the write was refused", and it needs one: on Apple
    /// Silicon a refused `F<n>Md` is the *expected* answer while the thermal manager holds
    /// the fans. A refusal must leave the machine exactly as it was.
    @Test("A refused write throws and changes nothing")
    func aRefusedWriteChangesNothing() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.init(writes: .refused(reason: "firmware answered 0x82"))])

        await #expect(throws: FanControlPlaneError.self) {
            try await plane.engageManualControl(ofFan: 0)
        }
        await #expect(throws: FanControlPlaneError.self) {
            _ = try await plane.commandTarget(4_200, ofFan: 0)
        }

        let state = try await plane.readControlState(ofFan: 0)
        #expect(state.mode == .automatic)
        #expect(state.target == .rpm(1_800))
    }

    // MARK: - The firmware reverts

    /// The reclamation signal. The write succeeds — nothing at the call site can tell —
    /// and the read-back shows the state the fan had before.
    ///
    /// This is why `commandTarget` hands back what it commanded: comparing a read-back
    /// against the *goal* would make a legitimate ramp look like reclamation, because
    /// `F<n>Ac` slews toward `F<n>Tg` rather than stepping. Comparing it against what was
    /// last commanded catches this and not that.
    @Test("A reverted target succeeds at the call site and reads back as the previous value")
    func aRevertedTargetReadsBackAsThePreviousValue() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .init(mode: .manual, targetRPM: 1_800)],
            stages: [.init(writes: .reverted)])

        let commanded = try await plane.commandTarget(4_200, ofFan: 0)
        let state = try await plane.readControlState(ofFan: 0)

        #expect(commanded == CommandedTarget(fanIndex: 0, rpm: 4_200))
        #expect(state.target == .rpm(1_800))
    }

    /// Firmware that accepts a restore and leaves the fan manual is the one condition
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md) names as defeating everything
    /// in E5 — "a return-to-architect event and a `RECOVERY.md` headline". It has to be
    /// scriptable, not assumed away.
    @Test("A restore the firmware discards leaves the fan in manual")
    func aDiscardedRestoreLeavesTheFanManual() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .init(mode: .manual)],
            stages: [.init(writes: .reverted)])

        try await plane.restoreToAutomatic(.fan(0))

        let state = try await plane.readControlState(ofFan: 0)
        #expect(state.mode == .manual)
    }

    // MARK: - Temperatures drift

    /// The override's latch and hysteresis need a temperature that crosses a ceiling and
    /// comes back — including the band between the ceiling and the release point, which is
    /// where a latch that releases too early shows up.
    @Test("Temperatures drift past a ceiling and back below it, one stage at a time")
    func temperaturesDriftPastACeilingAndBack() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [
                .nominal(temperatures: ["TC0P": 55]),
                .nominal(temperatures: ["TC0P": 97]),
                .nominal(temperatures: ["TC0P": 92]),
                .nominal(temperatures: ["TC0P": 55]),
            ])

        var observed: [Double] = []
        for _ in 0..<4 {
            let report = try await plane.readCriticalTemperatures([Self.cpuKey])
            observed.append(report.readings[0].celsius)
            await plane.advance()
        }

        #expect(observed == [55, 97, 92, 55])
    }

    /// The last stage repeats, so a scenario carries exactly as many entries as it has
    /// distinct moments and a test can keep ticking past the end without scripting filler.
    @Test("The final stage repeats once the script is exhausted")
    func theFinalStageRepeats() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(temperatures: ["TC0P": 97]), .nominal(temperatures: ["TC0P": 55])])

        await plane.advance()
        await plane.advance()
        await plane.advance()

        let report = try await plane.readCriticalTemperatures([Self.cpuKey])
        #expect(report.readings[0].celsius == 55)
    }

    // MARK: - Reads fail

    /// Transient blindness: one cycle sees nothing, the next sees everything. The case a
    /// supervisor must not over-react to, and the reason "restore on the first failed read"
    /// is the wrong rule.
    @Test("A transient read failure recovers on the next stage")
    func aTransientReadFailureRecovers() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.blind(), .nominal(temperatures: ["TC0P": 55])])

        await #expect(throws: FanControlPlaneError.self) {
            try await plane.readCriticalTemperatures([Self.cpuKey])
        }

        await plane.advance()
        let report = try await plane.readCriticalTemperatures([Self.cpuKey])
        #expect(report.readings[0].celsius == 55)
    }

    /// Persistent blindness: it never comes back, however long the supervisor waits. The
    /// case #102 turns into divergence — restore and report, rather than sit blind holding
    /// a lease.
    @Test("A persistent read failure never recovers, however far the scenario runs")
    func aPersistentReadFailureNeverRecovers() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(temperatures: ["TC0P": 55]), .blind(reason: "stale io_connect_t")])

        await plane.advance()
        for _ in 0..<5 {
            await #expect(throws: FanControlPlaneError.self) {
                try await plane.readCriticalTemperatures([Self.cpuKey])
            }
            await #expect(throws: FanControlPlaneError.self) {
                try await plane.readControlState(ofFan: 0)
            }
            await plane.advance()
        }
    }

    /// One thermistor dropping out is not the SMC going dark, and the mock keeps them
    /// apart: a key absent from the stage's temperatures fails on its own, and the cycle is
    /// degraded rather than blind.
    @Test("A key the stage does not answer is a partial loss, not a failed cycle")
    func oneMissingKeyIsPartialLossNotBlindness() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal], stages: [.nominal(temperatures: ["TC0P": 61.5])])

        let report = try await plane.readCriticalTemperatures([Self.cpuKey, Self.gpuKey])

        #expect(report.readings.count == 1)
        #expect(report.unreadableKeys == [Self.gpuKey])
    }

    /// …and losing every key is blindness, refused by `CriticalTemperatureReport` rather
    /// than answered with an empty success. The mock inherits that rule instead of
    /// restating it, which is the point of putting it on the type.
    @Test("A stage that answers no critical key at all is blindness, not an empty cycle")
    func losingEveryKeyIsBlindness() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])
        let blind = FanControlPlaneError.criticalTelemetryUnavailable(requestedKeys: 2)

        await #expect(throws: blind) {
            try await plane.readCriticalTemperatures([Self.cpuKey, Self.gpuKey])
        }
    }

    // MARK: - The keystone

    /// The terminal action, available in the cycle where nothing else is.
    ///
    /// A mock that let `ReadBehaviour` gate the restore verb would make this scenario
    /// impossible to write, and would quietly agree with an implementation that read before
    /// restoring — which is the failure
    /// [ADR 0007](../../docs/ADR/0007-safety-composition.md)'s keystone exists to forbid.
    @Test("Restoring to automatic works while every read is failing")
    func restoreWorksWhileBlind() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .init(mode: .manual), 1: .init(mode: .manual)],
            stages: [.blind(), .nominal()])

        try await plane.restoreToAutomatic(.everyFan)

        // The proof has to survive the blindness that made it necessary, so the state is
        // read on a later, sighted stage rather than during the blind one.
        await plane.advance()
        for index in [0, 1] {
            let state = try await plane.readControlState(ofFan: index)
            #expect(state.mode == .automatic, "fan \(index) was not restored")
        }
    }

    @Test("Restoring one fan leaves the others exactly as they were")
    func restoringOneFanTouchesNoOther() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .init(mode: .manual), 1: .init(mode: .manual)])

        try await plane.restoreToAutomatic(.fan(0))

        let restored = try await plane.readControlState(ofFan: 0)
        let untouched = try await plane.readControlState(ofFan: 1)
        #expect(restored.mode == .automatic)
        #expect(untouched.mode == .manual)
    }

    // MARK: - Envelopes

    /// #37's gate needs to be handed the implausible declaration in order to refuse it, so
    /// the mock reports what the firmware says without judging it.
    @Test("An implausible envelope is reported as declared")
    func implausibleEnvelopesAreReportedAsDeclared() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .zeroMinimum, 1: .invertedBounds], stages: [.nominal()])

        let zeroMinimum = try await plane.readEnvelope(ofFan: 0)
        let inverted = try await plane.readEnvelope(ofFan: 1)

        #expect(zeroMinimum.minimumRPM == 0)
        #expect(zeroMinimum.maximumRPM == 5_777)
        #expect(inverted.minimumRPM == 5_777)
        #expect(inverted.maximumRPM == 1_350)
    }

    /// A bound that did not decode is a different thing from a bound that is absurd, and
    /// the seam's one finiteness rule applies through the mock as well as through the real
    /// plane. A double that handed back `NaN` bounds where the real thing reports a fault
    /// would hide the defect it exists to expose.
    @Test("A declared bound that did not decode is a read failure, not an envelope")
    func undecodableBoundsAreReadFailures() async throws {
        let plane = ScriptedControlPlane(fans: [0: .undecodableBounds], stages: [.nominal()])

        let error = await #expect(throws: FanControlPlaneError.self) {
            try await plane.readEnvelope(ofFan: 0)
        }

        #expect(error?.isReadFailure == true, "NaN bounds produced \(describe(error))")
    }

    // MARK: - Unscripted input

    /// The defect class this repository keeps producing, in its most common form: a double
    /// that answers an input nobody stubbed with an empty success, so the test that was
    /// written to catch a failure never reaches one.
    ///
    /// Every operation naming a fan the machine does not have is refused, including the
    /// restore verb — a restore of a fan that does not exist is not a restore that worked.
    @Test("A fan the machine does not have is refused by every operation, never defaulted")
    func anUnscriptedFanIsRefusedEverywhere() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])
        let absent = FanControlPlaneError.fanNotAddressable(index: 3)

        await #expect(throws: absent) { try await plane.readControlState(ofFan: 3) }
        await #expect(throws: absent) { try await plane.readEnvelope(ofFan: 3) }
        await #expect(throws: absent) { try await plane.engageManualControl(ofFan: 3) }
        await #expect(throws: absent) { _ = try await plane.commandTarget(2_400, ofFan: 3) }
        await #expect(throws: absent) { try await plane.restoreToAutomatic(.fan(3)) }
    }

    // MARK: - What was attempted

    /// "The supervisor reached its terminal action" is a claim about a call that was made.
    /// A recorder that only saw successful calls could not tell a supervisor that never
    /// tried to restore from one that tried and was refused — and those are opposite bugs.
    @Test("Every attempt is recorded, including the ones the firmware refused")
    func everyAttemptIsRecordedIncludingRefusals() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.init(writes: .refused(reason: "firmware answered 0x82"))])

        await #expect(throws: FanControlPlaneError.self) {
            try await plane.engageManualControl(ofFan: 0)
        }
        await #expect(throws: FanControlPlaneError.self) {
            try await plane.restoreToAutomatic(.everyFan)
        }
        _ = try await plane.readControlState(ofFan: 0)

        let attempts = await plane.attempts
        #expect(
            attempts == [
                .engageManualControl(fan: 0),
                .restoreToAutomatic(.everyFan),
                .readControlState(fan: 0),
            ])
    }

    /// A write the firmware honours does land, so a scenario can set up "this fan is under
    /// manual control at 4200" by driving the seam rather than by constructing state behind
    /// its back.
    @Test("A honoured write lands and is visible on the next read")
    func aHonouredWriteLands() async throws {
        let plane = ScriptedControlPlane(fans: [0: .nominal], stages: [.nominal()])

        try await plane.engageManualControl(ofFan: 0)
        _ = try await plane.commandTarget(4_200, ofFan: 0)

        let state = try await plane.readControlState(ofFan: 0)
        #expect(state.mode == .manual)
        #expect(state.target == .rpm(4_200))
    }

    /// Advancing the scenario changes the environment, not what has been written. A test
    /// that commands a target and then drives the temperature up must still see the target
    /// it commanded.
    @Test("Advancing a stage does not undo a write")
    func advancingDoesNotUndoAWrite() async throws {
        let plane = ScriptedControlPlane(
            fans: [0: .nominal],
            stages: [.nominal(temperatures: ["TC0P": 55]), .nominal(temperatures: ["TC0P": 97])])

        try await plane.engageManualControl(ofFan: 0)
        _ = try await plane.commandTarget(4_200, ofFan: 0)
        await plane.advance()

        let state = try await plane.readControlState(ofFan: 0)
        #expect(state.mode == .manual)
        #expect(state.target == .rpm(4_200))
    }
}
