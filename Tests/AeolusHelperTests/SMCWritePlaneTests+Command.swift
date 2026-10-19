import Foundation
import IOKit
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane's target command (C4, C5, C13; #9's floor and encoding items).
extension SMCWritePlaneTests {

    /// One command turn run straight through the scheduler, as the plane runs it, with whatever
    /// `TargetCommand` a row needs — including targets no permit can carry.
    private static func command(
        _ target: TargetCommand, on firmware: FirmwareSMC
    ) async throws -> CommandedTarget {
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        let ledger = PlaneWriteLedger(enumerated: [0, 1], forceKey: .present)
        let log = PlaneWriteLog(SafetyLog(recording: { _, _ in }))
        return try await scheduler.withWriteTurn(at: .supervisor, on: firmware) { channel in
            try SMCWriteTurns.command(target, ledger: ledger, log: log, on: channel)
        }
    }

    // MARK: - Rule 3 rests on the clamp; the turn refuses below the floor

    /// The floor of fan 0's permit, as `mac16x5()` declares its bounds: 1350 RPM.
    private static var floor: Double {
        get throws { try Self.fan(0).target(for: 0).lowestCommandableRPM }
    }

    /// A target below the fan's floor is refused after the clamp and before `encode`, with nothing
    /// read and nothing written — zero, `-0.0`, a value that encodes to a subnormal-adjacent
    /// single,
    /// a negative, and the floor's `nextDown` — and the floor itself is written (#9's checklist).
    ///
    /// **Mutations:** weaken the guard in `SMCWriteTurns.command` to `rpm >= 1`. Run: red here, at
    /// the `nextDown` row alone. Separately, make it pass every number, `rpm == rpm || rpm >=
    /// lowest`. Run: red here, at every refused row.
    @Test(
        "A target below the floor is refused before anything is read, and the floor is written",
        arguments: [0.0, -0.0, 1e-30, -1, 1_350.0.nextDown, 1_350])
    func aTargetBelowTheFloorIsRefused(_ rpm: Double) async throws {
        #expect(try Self.floor == 1_350, "mac16x5()'s fan 0 floor moved; the rows assume 1350")
        let firmware = FirmwareSMC.mac16x5()
        let target = TargetCommand(fan: 0, rpm: rpm, floor: try Self.floor)

        if rpm >= 1_350 {
            #expect(try await Self.command(target, on: firmware).rpm == rpm)
            #expect(
                firmware.log.operations == [
                    .keyInfo(Self.targetZero, .answered),
                    .write(Self.targetZero, FirmwareSMC.flt(rpm: Float(rpm)), .answered),
                    .read(Self.targetZero, .answered),
                ])
        } else {
            await #expect(throws: WriteTurnRefusal.self) {
                try await Self.command(target, on: firmware)
            }
            #expect(firmware.log.operations.isEmpty, "\(rpm): \(firmware.log.operations)")
        }
    }

    /// A floor passed below `FanSafetyLimits.minimumManualRPM` is raised to it: rule 3 does not
    /// rest on the caller's floor either.
    ///
    /// **Mutation:** in `SMCWriteTurns.command`, make `lowest` the passed floor alone. Run: red
    /// here.
    @Test("A floor below the manual minimum is raised to it")
    func aFloorBelowTheManualMinimumIsRaised() async throws {
        let firmware = FirmwareSMC.mac16x5()
        await #expect(throws: WriteTurnRefusal.self) {
            try await Self.command(TargetCommand(fan: 0, rpm: 99, floor: 0), on: firmware)
        }
        #expect(firmware.log.operations.isEmpty)
        #expect(
            try await Self.command(TargetCommand(fan: 0, rpm: 100, floor: 0), on: firmware).rpm
                == 100)
    }

    /// The target is encoded before anything is written: a connection whose interface generation
    /// could not be told has no byte order for a `flt`, so `encode` refuses and the turn writes
    /// nothing, having read only the key's info.
    ///
    /// **Mutation:** in `SMCWriteTurns.encoded`, return `[]` when `encode` throws for a value above
    /// one. Run: red here — an empty write is issued.
    @Test("The target is encoded before it is written, and a refusal writes nothing")
    func theTargetIsEncodedBeforeItIsWritten() async throws {
        let firmware = FirmwareSMC.mac16x5()
        await firmware.setInterfaceGeneration(nil)

        await #expect(throws: WriteTurnRefusal.self) {
            try await Self.command(TargetCommand(fan: 0, rpm: 2_400, floor: 1_350), on: firmware)
        }
        #expect(firmware.log.operations == [.keyInfo(Self.targetZero, .answered)])
    }

    // MARK: - C13: the read-back in the command's own turn

    /// The firmware accepts the target and does not apply it: the read-back holds the old value,
    /// and the command throws `.targetNotConfirmed` rather than report a target nothing honours.
    ///
    /// **Mutation:** in `SMCWriteTurns.command`, compare the read-back against `.infinity` instead
    /// of `targetToleranceRPM`. Run: red here.
    @Test("A target accepted and not applied is not confirmed")
    func aTargetNotAppliedIsNotConfirmed() async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        await fixture.firmware.queueWrites(to: Self.targetZero, [.acceptsWithoutApplying])

        await #expect(
            throws: FanControlPlaneError.targetNotConfirmed(
                index: 0, commandedRPM: 2_400, readBackRPM: 1_350)
        ) {
            try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        }
    }

    /// Within `targetToleranceRPM` the command returns the **permit's** rpm, not the read-back;
    /// outside it, even by two RPM, it throws.
    ///
    /// **Mutations:** return the read-back as the commanded rpm. Run: red at the 0.4 row. Make the
    /// tolerance 100. Run: red at the 2 row.
    @Test(
        "A read-back within the tolerance returns the commanded rpm; outside it throws",
        arguments: [0.4, 2])
    func theReadBackIsJudgedByTheTolerance(_ offset: Double) async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        await fixture.firmware.setRegister(
            Self.targetZero, FirmwareSMC.flt(rpm: Float(2_400 + offset)))
        await fixture.firmware.queueWrites(to: Self.targetZero, [.acceptsWithoutApplying])
        let target = try Self.fan(0).target(for: 2_400)

        if offset < ReclamationLimits.targetToleranceRPM {
            #expect(
                try await fixture.plane.commandTarget(target)
                    == CommandedTarget(fanIndex: 0, rpm: 2_400))
        } else {
            await #expect(throws: FanControlPlaneError.self) {
                try await fixture.plane.commandTarget(target)
            }
        }
    }

    /// A refused target write throws, with no read-back after it.
    @Test("A refused target write throws, and nothing is read back")
    func aRefusedTargetIsThrown() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        await fixture.firmware.queueWrites(to: Self.targetZero, [.refuses(code: 0x85)])

        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        }
        #expect(error.map(Self.isRefusedControl) == true, "\(String(describing: error))")
        #expect(fixture.operations(since: mark).last?.isWrite == true)
    }

    // MARK: - C4: admission first, and C5: one turn

    /// Sealed for exit, or stale: the command and the step are refused at their admission, with
    /// nothing read and nothing written.
    ///
    /// **Mutation:** in `SMCWriteTurns.command`, move `admitCommand()` after the key's
    /// `freshKeyInfo`. Run: red here — a key-info read in the sealed command's turn.
    @Test("A sealed command and a stale step are refused at admission, reading nothing")
    func aSealedCommandAndAStaleStepReadNothing() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        let ledger = try fixture.ledger

        fixture.plane.beginEngagement(fanAt: 0)
        ledger.restoreRequested(.fan(1))
        await #expect(throws: FanControlPlaneError.superseded) {
            try await fixture.plane.engageManualControl(of: Self.fan(0))
        }
        ledger.restoreRequested(.forExit)
        await #expect(throws: FanControlPlaneError.superseded) {
            try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        }
        #expect(fixture.operations(since: mark).isEmpty, "\(fixture.operations(since: mark))")
        #expect(fixture.turns(since: mark).count == 2, "both were admitted inside a turn")
    }

    /// The exit's seal requested while the command waits for its turn refuses it inside the turn:
    /// the admission is the turn's first statement, so it sees a seal that arrived in the queue.
    ///
    /// **Mutation:** in `SMCFanControlPlane.commandTarget(_:)`, call `admitCommand()` before
    /// `withWriteTurn`, and delete it from `SMCWriteTurns.command`. Run: red here — the queued
    /// command writes its target after the seal.
    @Test("A seal requested while the command is queued refuses it, with nothing written")
    func aSealWhileQueuedRefusesTheCommand() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        let ledger = try fixture.ledger
        let plane = fixture.plane
        let target = try Self.fan(0).target(for: 2_400)
        await fixture.firmware.holdReads()

        let read = observing { try await fixture.scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await fixture.firmware.readsParked == 1 }
        let command = observing { try await plane.commandTarget(target) }
        await yieldUntil("the command to queue") {
            await fixture.scheduler.queuedTurns(at: .supervisor) == 1
        }
        ledger.restoreRequested(.forExit)
        await fixture.firmware.releaseReads()
        _ = try await finished("the read", read)

        await #expect(throws: FanControlPlaneError.superseded) {
            _ = try await finished("the command", command)
        }
        #expect(fixture.writes(since: mark).isEmpty, "\(fixture.writes(since: mark))")
    }

    /// U15 for a command: a seal requested from another thread at the turn's first operation after
    /// its admission does not stop the admitted command — it writes once, in its own turn — and no
    /// forward write appears in any turn that began after the request.
    ///
    /// **Mutation:** split `SMCFanControlPlane.commandTarget(_:)` into two write turns — the first
    /// admits and takes a key info, the second runs `SMCWriteTurns.command` with `admitCommand()`
    /// deleted. Run: red here — the write falls in a turn that began after the seal.
    @Test("A command's admission and its write are one turn; nothing forward follows the seal")
    func aCommandIsOneTurn() async throws {
        let fixture = WritePlaneFixture()
        let mark = await fixture.prepared()
        let ledger = try fixture.ledger
        await fixture.firmware.onNext(.keyInfo(Self.targetZero)) {
            ledger.restoreRequested(.forExit)
        }

        let commanded = try await fixture.plane.commandTarget(Self.fan(0).target(for: 2_400))
        #expect(commanded.rpm == 2_400)
        await #expect(throws: FanControlPlaneError.superseded) {
            try await fixture.plane.commandTarget(Self.fan(0).target(for: 3_000))
        }
        fixture.plane.beginEngagement(fanAt: 1)
        await #expect(throws: FanControlPlaneError.superseded) {
            try await fixture.plane.engageManualControl(of: Self.fan(1))
        }

        let turns = fixture.turns(since: mark)
        let forward = turns.map { turn in
            turn.operations.filter {
                if case .write(let key, let bytes, _) = $0 {
                    return key == Self.targetZero || bytes.contains { $0 != 0 }
                }
                return false
            }.count
        }
        #expect(forward == [1, 0, 0], "\(turns.map(\.operations))")
    }
}
