import Foundation
import IOKit
import Testing

@testable import AeolusHelper
@testable import SMCCore

/// The production plane's restore (C3, C6, C19, C20; #9's payload and connection-failure items).
extension SMCWritePlaneTests {

    // MARK: - C3: requested before the turn

    /// A restore moves the epoch when it is called, before it waits for its turn: with the turn
    /// held by a parked read, the restore is queued and an engagement in progress is already stale.
    ///
    /// **Mutation:** move `ledger.restoreRequested(scope)` inside the restore's write turn. Run:
    /// red
    /// here — the engagement is current while the restore waits.
    @Test("A restore is requested before it waits: the epoch moves while it is queued")
    func aRestoreIsRequestedBeforeItsTurn() async throws {
        let fixture = WritePlaneFixture()
        await fixture.prepared()
        let ledger = try fixture.ledger
        let plane = fixture.plane
        ledger.beginEngagement(fanAt: 0)
        #expect(try ledger.admitStep(fanAt: 0) == .first)
        await fixture.firmware.holdReads()

        let read = observing { try await fixture.scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to hold its turn") { await fixture.firmware.readsParked == 1 }
        let restore = observing { try await plane.restoreToAutomatic(.fan(1)) }
        await yieldUntil("the restore to queue") {
            await fixture.scheduler.queuedTurns(at: .supervisor) == 1
        }

        #expect(!ledger.isCurrent(fanAt: 0), "the restore had not moved the epoch while it waited")
        #expect(fixture.firmware.log.operations.filter(\.isWrite).isEmpty)
        await fixture.firmware.releaseReads()
        _ = try await finished("the read", read)
        _ = try await finished("the restore", restore)
    }

    // MARK: - C6: from the ledger's plan, and the exit writes what the machine-wide restore writes

    /// `.forExit` writes exactly what `.everyFan` writes, operation for operation, and seals.
    ///
    /// **Mutation:** in `SMCFanControlPlane.restoreToAutomatic(_:)`, issue `.fan(0)` in the turn
    /// when the scope is `.forExit`. Run: red here.
    @Test("The exit's restore writes exactly what the machine-wide restore writes")
    func theExitWritesWhatTheMachineWideRestoreWrites() async throws {
        var logs: [[FirmwareLog.Entry]] = []
        for scope in [FanRestoreScope.everyFan, .forExit] {
            let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
            await fixture.prepared()
            try await fixture.engage(1)
            let mark = fixture.firmware.log.entries.count
            try await fixture.plane.restoreToAutomatic(scope)
            logs.append(fixture.operations(since: mark))
        }
        #expect(logs[0] == logs[1], "\(logs)")
        #expect(
            logs[0] == [
                .write(Self.modeZero, [0], .answered), .write(Self.modeOne, [0], .answered),
                .write(Self.forceKey, [0], .answered),
            ])
    }

    /// The turn file plans every restore through the ledger and names no scope of its own (#9's
    /// b2 checklist: "never from a scope switch of its own").
    ///
    /// **Mutation:** add `if case .forExit = scope { return }` to `SMCWriteTurns.keystone`. Run:
    /// red here.
    @Test("The write turns name no restore scope")
    func theWriteTurnsNameNoScope() throws {
        for file in ["SMCWriteTurns.swift", "SMCWriteTurns+Reads.swift"] {
            let url = try #require(
                try SeamScanner.swiftFiles().first { $0.lastPathComponent == file })
            let code = SeamScanner.strippingAllComments(
                try String(contentsOf: url, encoding: .utf8))
            for scope in [".fan(", ".everyFan", ".forExit"] {
                #expect(!code.contains(scope), "\(file) names \(scope)")
            }
        }
    }

    // MARK: - C19: the unlock reversed, every write attempted, nothing read

    /// Every mode first, then the key; a refused mode write is followed by the rest, and the
    /// restore throws only after all of them. No key info, no read.
    ///
    /// **Mutations:** in `RestorePlan.attemptEvery`, rethrow inside the loop. In
    /// `SMCWriteTurns.keystone`, read the key before writing it. In `RestorePlan.init`, put the key
    /// ahead of the modes. Run: red here at the operations, each.
    @Test("A restore writes every mode then the key, attempts every write, and reads nothing")
    func aRestoreAttemptsEveryWriteAndReadsNothing() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
        await fixture.prepared()
        try await fixture.engage(0)
        let mark = fixture.firmware.log.entries.count
        await fixture.firmware.queueWrites(to: Self.modeZero, [.refuses(code: 0x85)])

        let error = await #expect(throws: (any Error).self) {
            try await fixture.plane.restoreToAutomatic(.everyFan)
        }
        #expect(error.map(Self.isRefusedControl) == true, "\(String(describing: error))")
        #expect(
            fixture.operations(since: mark) == [
                .write(Self.modeZero, [0], .threw(.firmware(code: 0x85))),
                .write(Self.modeOne, [0], .answered), .write(Self.forceKey, [0], .answered),
            ])
        #expect(await fixture.firmware.register(Self.forceKey) == [0])
    }

    /// `.fan(n)` clears the key when it hands back the last engaged fan, and never while another
    /// engaged fan depends on it.
    ///
    /// **Mutation:** in `PlaneWriteLedger.issueRestore(fanAt:)`, clear the key whenever the flag is
    /// set, ignoring the engaged set. Run: red here, at the first restore.
    @Test("A per-fan restore clears the key only when no engaged fan is left")
    func aPerFanRestoreClearsTheKeyLast() async throws {
        let fixture = WritePlaneFixture(unlock: .heldUntilForced(stepsToYield: 0))
        await fixture.prepared()
        try await fixture.engage(0)
        try await fixture.engage(1)

        var mark = fixture.firmware.log.entries.count
        try await fixture.plane.restoreToAutomatic(.fan(0))
        #expect(fixture.writes(since: mark) == ["F0Md=0"])
        mark = fixture.firmware.log.entries.count
        try await fixture.plane.restoreToAutomatic(.fan(1))
        #expect(fixture.writes(since: mark) == ["F1Md=0", "Ftst=0"])
    }

    /// A restore writes zeros of the size the preparation step recorded, one zero byte for a key
    /// with none, and never a key recorded absent.
    ///
    /// **Mutation:** in `PlaneWriteLedger.issueMachineWideRestore()`, clear the key whatever its
    /// presence. Run: red here, at the absent row.
    @Test("A restore writes the recorded size, one byte when unknown, and no absent key")
    func aRestoreWritesTheRecordedSizes() async throws {
        let sized = WritePlaneFixture()
        await sized.firmware.declare(
            Self.modeZero,
            .present(SMCKeyInfo(key: Self.modeZero, type: .ui8, dataSize: 2, attributes: 0xD0)))
        var mark = await sized.prepared()
        try await sized.plane.restoreToAutomatic(.fan(0))
        #expect(sized.writes(since: mark) == ["F0Md=0,0"])

        let unprepared = WritePlaneFixture()
        mark = unprepared.firmware.log.entries.count
        try await unprepared.plane.restoreToAutomatic(.fan(1))
        #expect(unprepared.writes(since: mark) == ["F1Md=0"])

        let absent = WritePlaneFixture()
        mark = await absent.prepared()
        try absent.ledger.recordPreparation(
            enumerated: [0, 1], forceKey: .absent, declaredSizes: [Self.modeZero: 1])
        try await absent.plane.restoreToAutomatic(.everyFan)
        #expect(absent.writes(since: mark) == ["F0Md=0", "F1Md=0"], "an absent key was written")
    }

    // MARK: - C20: a failed enumeration

    /// The bring-up enumeration failed: `.everyFan` writes every fan this process touched, and the
    /// key, then throws `.fanSetUnknown`.
    ///
    /// **Mutation:** in `PlaneWriteLedger.issueMachineWideRestore()`, drop `.union(state.touched)`.
    /// Run: red here.
    @Test(
        "After a failed enumeration the machine-wide restore writes the touched fans, then throws")
    func aFailedEnumerationStillRestoresTheTouchedFans() async throws {
        let fixture = WritePlaneFixture()
        _ = await fixture.plane.prepareWritePath(
            enumerating: ScriptedFanEnumeration(indices: [], failure: Self.kernelError))
        try await fixture.engage(1)
        let mark = fixture.firmware.log.entries.count

        await #expect(throws: FanControlPlaneError.fanSetUnknown(refusedWrite: nil)) {
            try await fixture.plane.restoreToAutomatic(.everyFan)
        }
        #expect(fixture.writes(since: mark) == ["F1Md=0", "Ftst=0"])
    }

    // MARK: - #9: the payload range, and the connection's two failures

    /// The payload range is stated twice — `PlaneWriteLedger.restorePayload(for:)`'s one to 32
    /// bytes and `SMCConnection.maxPayloadBytes` — and held together here: a recorded size the
    /// connection can carry is written as zeros of that size, and every other is one zero byte.
    ///
    /// **Mutation:** make `restorePayload(for:)`'s range `1...33`. Run: red here, at 33.
    @Test("A restore's payload range is the connection's, one to maxPayloadBytes")
    func thePayloadRangeIsTheConnections() async throws {
        #expect(FirmwareSMC.maxPayloadBytes == SMCConnection.maxPayloadBytes)
        for size in 0...(SMCConnection.maxPayloadBytes + 4) {
            let ledger = PlaneWriteLedger(
                enumerated: [0], forceKey: .present, declaredSizes: [Self.modeZero: size])
            let carried = (1...SMCConnection.maxPayloadBytes).contains(size)
            #expect(
                ledger.restorePayload(for: .mode(fan: 0))
                    == (carried ? [UInt8](repeating: 0, count: size) : [0]), "\(size)")
        }

        let fixture = WritePlaneFixture()
        let largest = SMCConnection.maxPayloadBytes
        await fixture.firmware.declare(
            Self.modeZero,
            .present(
                SMCKeyInfo(key: Self.modeZero, type: .ui8, dataSize: largest, attributes: 0xD0)))
        let mark = await fixture.prepared()
        try await fixture.plane.restoreToAutomatic(.fan(0))
        #expect(
            fixture.operations(since: mark)
                == [.write(Self.modeZero, [UInt8](repeating: 0, count: largest), .answered)])
    }

    /// Only a result byte is an answer. `connectionFailed` for a handle never opened and for a
    /// kernel call that failed, and a short reply, are all `.unanswered` — the same thing, never
    /// told apart — and a step whose mode write got either is undone like any write that may have
    /// landed.
    ///
    /// **Mutation:** in `SMCWriteTurns.answer(to:)`, answer `.refused(code: 0)` for
    /// `.connectionFailed(kernReturn: kIOReturnNotOpen)`. Run: red here.
    @Test("Both connectionFailed causes and a short reply are unanswered, and never told apart")
    func noResultByteIsNoAnswer() async throws {
        let failures: [SMCError] = [
            FirmwareSMC.notOpen, Self.kernelError, .truncatedReply(expected: 80, received: 12),
        ]
        for failure in failures {
            guard case .unanswered = SMCWriteTurns.answer(to: failure) else {
                Issue.record(
                    "\(failure) was read as an answer: \(SMCWriteTurns.answer(to: failure))")
                continue
            }
        }
        #expect(SMCWriteTurns.answer(to: .firmware(code: 0x82)) == .heldBySystem)
        #expect(SMCWriteTurns.answer(to: .firmware(code: 0x85)) == .refused(code: 0x85))

        for failure in failures.prefix(2) {
            let fixture = WritePlaneFixture()
            await fixture.prepared()
            await fixture.firmware.queueWrites(
                to: Self.modeZero, [.unanswered(failure, applied: false)])
            fixture.plane.beginEngagement(fanAt: 0)
            let error = await #expect(throws: (any Error).self) {
                try await fixture.plane.engageManualControl(of: Self.fan(0))
            }
            #expect(
                error.map(Self.isRefusedControl) == true, "\(failure): \(String(describing: error))"
            )
            #expect(try fixture.ledger.touchedFans == [0], "\(failure): the write was not counted")
        }
    }
}
