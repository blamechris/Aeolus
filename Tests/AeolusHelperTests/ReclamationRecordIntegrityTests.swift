import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What § 5's record may hold, and what its log lines may state: no target a plane cannot write,
/// no comparison that a value that is not a number passes, and no RPM conversion that traps.
@Suite("§ 5's record and log lines take no value a plane cannot produce", .timeLimit(.minutes(1)))
struct ReclamationRecordIntegrityTests {

    /// A report that is not a number, or is below the floor every permit is clamped to, leaves the
    /// record as it was, so the next cycle reads the fan holding its target and logs nothing.
    ///
    /// **Mutation:** delete the guard in `HeldFan.command(_:)`. Run: red on every argument; the
    /// non-finite ones through the comparison below, which then diverges on the record.
    @Test(
        "A report no plane can write leaves the record alone",
        arguments: [Double.nan, .infinity, -.infinity, 0, 50])
    func aReportNoPlaneCanWriteLeavesTheRecordAlone(rpm: Double) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id

        await machine.watchdog.commandedTarget(CommandedTarget(fanIndex: 0, rpm: rpm), under: lease)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the report was recorded")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
    }

    /// **Mutation:** restore `guard abs(...) > tolerance else { return nil }` in
    /// `primaryDivergence(of:against:)`, under which a target that is not a number reads every
    /// reading back. Run: red.
    @Test("A reading diverges from a target that is not a number")
    func aReadingDivergesFromATargetThatIsNotANumber() {
        let reading = FanControlState(
            index: 0, mode: .manual, target: .rpm(1_800), actualRPM: .rpm(1_800))
        let divergence = ReclamationWatchdog<ScriptedControlPlane>.primaryDivergence(
            of: reading, against: CommandedTarget(fanIndex: 0, rpm: .nan))
        #expect(divergence != nil, "a target that is not a number converged")
    }

    /// Every RPM a § 5 or § 3 line states goes through one total conversion. Each of the seven
    /// sites is reached here with values `Int(_:)` traps on. **Mutation:** restore the bare
    /// conversion at any one site. Run: the test process dies with "Double value cannot be
    /// converted to Int".
    @Test("Every RPM in a log line is written out, whatever the value")
    func everyRPMInALogLineIsWrittenOut() {
        #expect(FanControlPlaneValue.wholeRPM(2_400.4) == "2400")
        #expect(FanControlPlaneValue.wholeRPM(.nan) == "NaN")
        #expect(FanControlPlaneValue.wholeRPM(-.infinity) == "-Infinity")
        #expect(FanControlPlaneValue.wholeRPM(1e30) == "1e+30")

        let recorded = RecordedLog()
        let log = SafetyLog(recording: { recorded.append($0, $1) })
        let divergence = ReclamationDivergence.targetDiverged(commanded: .nan, readBack: 1e30)
        log.reclamationDetected(
            fan: 0, divergence: divergence, commanded: CommandedTarget(fanIndex: 0, rpm: .nan))
        log.reclamationFanNotReachingTarget(fan: 0, actual: -1e30, commanded: .nan, dwellCycles: 3)
        log.reclamationReasserted(fan: 0, rpm: .infinity, attempt: 1, budget: 3)
        log.emergencyCommandedMaximum(fan: 0, rpm: .nan)

        #expect(recorded.lines.count == 4)
        #expect(recorded.lines.allSatisfy { $0.contains("NaN") || $0.contains("Infinity") })
        #expect(divergence.summary.contains("1e+30"))
    }
}
