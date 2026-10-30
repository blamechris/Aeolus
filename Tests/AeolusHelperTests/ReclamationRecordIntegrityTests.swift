import FanKit
import Foundation
import Testing

@testable import AeolusHelper

/// What § 5's record may hold, and what its log lines may state: no target a plane cannot write,
/// no comparison that a value that is not a number passes, and no RPM conversion that traps. And
/// what the record may not lose: a cycle that cannot read takes nothing from it (#614's review).
@Suite(
    "§ 5's record and log lines take no value a plane cannot produce, and a blind cycle takes none",
    .timeLimit(.minutes(1)))
struct ReclamationRecordIntegrityTests {

    /// What `SafetyLog.reclamationTargetRefused(_:from:)` says, and no other line.
    static let refusalNotice = "so no plane can have written it"

    /// A report that is not a number, or is below the floor every permit is clamped to, leaves the
    /// record as it was, so the next cycle reads the fan holding its target. The refusal is said
    /// once, at `.fault`, with the value written out.
    ///
    /// **Mutation (a):** delete the guard in `HeldFan.record(_:)`. Run: red on every argument; the
    /// non-finite ones through the comparison below, which then diverges on the record.
    /// **(b):** delete the `logRefusal` call in `commandedTarget(_:under:)`. Run: red on the line.
    @Test(
        "A report no plane can write leaves the record alone, and is logged as a fault",
        arguments: [Double.nan, .infinity, -.infinity, 0, 50])
    func aReportNoPlaneCanWriteLeavesTheRecordAlone(rpm: Double) async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 2_400)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id

        await machine.watchdog.commandedTarget(CommandedTarget(fanIndex: 0, rpm: rpm), under: lease)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false, "the report was recorded")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400)
        let refusals = machine.safetyLog.lines(containing: Self.refusalNotice)
        #expect(refusals.count == 1, "the refusal was not logged exactly once")
        #expect(machine.safetyLog.faults.filter { $0.contains(Self.refusalNotice) } == refusals)
        #expect(refusals.first?.contains("was \(FanControlPlaneValue.wholeRPM(rpm)) RPM") == true)
    }

    /// The dangerous direction. The system holds the fan at 50 RPM and leaves it in manual mode,
    /// and a report of 50 arrives. Recorded, the reading would agree with the record, and § 5
    /// would believe it holds the fan at a speed no permit allows. Refused, the reading diverges
    /// from the record, and the fan is marked reclaimed and re-asserted.
    ///
    /// **Mutation:** delete the guard in `HeldFan.record(_:)`. Run: red on the claim.
    @Test("A report matching a system target below the floor does not make it Aeolus's")
    func aReportMatchingASystemTargetBelowTheFloorDoesNotMakeItAeoluss() async throws {
        let machine = ReclamationMachine(fans: [0: .held(at: 50)])
        try await machine.hold(fan: 0, commanding: 2_400)
        let lease = try #require(await machine.leases.activeLease()).id

        await machine.watchdog.commandedTarget(CommandedTarget(fanIndex: 0, rpm: 50), under: lease)
        await machine.watchdog.cycle()

        #expect(await machine.ledger.isReclaimed(fanAt: 0), "the system's 50 RPM read as Aeolus's")
        #expect(await machine.commandedRPMs == [2_400], "the record's target was not re-asserted")
    }

    /// A re-assert's write is the same exposure a report is: what the record takes is what the
    /// write returned. One that returned a target no plane can write leaves the record alone, so
    /// the next cycle reads the re-asserted target held, and the refusal is said once at `.fault`.
    ///
    /// **Mutation (a):** delete the guard in `HeldFan.record(_:)`. Run: red on every argument: the
    /// record takes the return, the next cycle diverges on it and re-asserts again.
    /// **(b):** delete the `logRefusal` call in `reassert`. Run: red on the line.
    @Test(
        "A re-assert whose write returns a target no plane can write leaves the record alone",
        arguments: [Double.nan, .infinity, 50])
    func aReassertNoPlaneCanWriteLeavesTheRecordAlone(rpm: Double) async throws {
        let plane = ScriptedControlPlane(fans: [0: .held(at: 1_800)])
        let sensing = InterferingFanStateSensing(plane, during: .commandWrite)
        let machine = ReclamationMachine(
            plane: plane, fans: [0: .held(at: 1_800)], interfering: sensing)
        try await machine.hold(fan: 0, commanding: 2_400)
        await sensing.misreport(commandedRPM: rpm)

        await machine.watchdog.cycle()
        await machine.watchdog.cycle()

        #expect(await machine.commandedRPMs == [2_400], "one re-assert, and none after it")
        #expect(await machine.watchdog.lastCommanded(ofFan: 0)?.rpm == 2_400, "return recorded")
        #expect(await machine.ledger.isReclaimed(fanAt: 0) == false)
        let refusals = machine.safetyLog.lines(containing: Self.refusalNotice)
        #expect(refusals.count == 1, "the refusal was not logged exactly once")
        #expect(machine.safetyLog.faults.filter { $0.contains(Self.refusalNotice) } == refusals)
        #expect(refusals.first?.contains("its re-assert returned") == true)
    }

    /// A cycle that cannot read counts itself and nothing else: the record's target stays the step
    /// last put on the wire, so the next readable cycle judges the fan against it. A target lost
    /// there leaves that cycle nothing to judge with. `primaryDivergence(of:against:)` has no
    /// target to compare a manual reading's with, the shortfall has none to fall short of, and
    /// `judge(_:)` grants the registration grace again.
    ///
    /// Two failures in a row, because a loss gated on the second is one the first does not show:
    /// `blindCyclesBeforeDivergence` is 3, so a run of two is still tolerated and judged after
    /// (#615).
    ///
    /// **What this and the scenario below see:** the target lost in `recordReadFailure()` on the
    /// first failure in a row or the second, whether by a write that names the storage or by one
    /// that replaces the whole record, which the lexical count in
    /// `ReclamationHeldFanAccessTests` cannot see. **What they do not:** a loss on the third,
    /// which is red nowhere (measured at full scope, #615): the actor answers a third in a row by
    /// handing the fan back and dropping the record, so no later cycle judges against it
    /// (inferred). Nor a loss in any other method (inferred, not run).
    ///
    /// **Mutations**, each in `HeldFan.recordReadFailure()`: (a) `self[keyPath:
    /// \.storedCommanded] = nil`; (b) the whole record replaced, `var fresh = HeldFan(lease:
    /// lease)`, every counter copied into it, then `self = fresh`. Each ungated, and each gated on
    /// `consecutiveReadFailures >= 2`. Run: red on each ungated, on the target after the first
    /// call and after the second; and on each gated, on the target after the second alone.
    @Test("A read failure leaves the record's target as it was")
    func aReadFailureLeavesTheRecordsTarget() throws {
        var record = ReclamationWatchdog<ScriptedControlPlane>.HeldFan(lease: UUID())
        let target = CommandedTarget(fanIndex: 0, rpm: 2_400)
        let recorded = record.record(target)
        try #require(recorded, "the target was refused before the read failure")

        let first = record.recordReadFailure()
        #expect(first == 1)
        #expect(record.commanded == target, "the first cycle that could not read cleared it")

        let second = record.recordReadFailure()
        #expect(second == 2)
        #expect(record.commanded == target, "the second cycle that could not read cleared it")
    }

    /// The same rule through the actor, and the harm it prevents. The system holds the fan at
    /// 1,800 RPM in manual mode against the 2,400 commanded, and the first `blindCycles` cycles
    /// cannot read it: one, then two, the most the watchdog tolerates. The next one can, diverges
    /// from the record, marks the fan reclaimed and re-asserts 2,400. With the record's target
    /// lost to a blind cycle, the same reading has nothing to diverge from, and the fan is
    /// neither marked nor re-asserted.
    ///
    /// The recovery line is the scenario's precondition: it says the cycles before the last took
    /// the blind path, as many as the case gave, and the last read the fan.
    ///
    /// **Mutations:** (a) and (b) above. Ungated: red in both cases. Gated on
    /// `consecutiveReadFailures >= 2`: red in the second case alone. Run: red on the mark, the
    /// re-assert and the record.
    @Test(
        "A divergence a blind cycle hid is caught by the next readable cycle",
        arguments: [1, 2])
    func aDivergenceABlindCycleHidIsCaughtAfterIt(blindCycles: Int) async throws {
        let stages: [ScriptedControlPlane.Stage] =
            Array(repeating: .blind(), count: blindCycles) + [.nominal()]
        let machine = ReclamationMachine(stages: stages, fans: [0: .held(at: 1_800)])
        try await machine.hold(fan: 0, commanding: 2_400)

        for _ in 0..<blindCycles {
            await machine.watchdog.cycle()
            await machine.plane.advance()
        }
        await machine.watchdog.cycle()

        let recovered = machine.safetyLog.lines(
            containing: "can read fan 0 again after \(blindCycles) unreadable cycle")
        try #require(
            recovered.count == 1,
            "the cycles before the last were not \(blindCycles) blind, or the last not readable")
        #expect(
            await machine.ledger.isReclaimed(fanAt: 0), "a divergence a blind cycle hid was missed")
        #expect(await machine.commandedRPMs == [2_400], "the record's target was not re-asserted")
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
