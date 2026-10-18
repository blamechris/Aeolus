import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// `FirmwareSMC`'s unlock rule, holds, hooks, log and recycler, beside `FirmwareSMCTests` for the
/// same reason and split from it only for length.
@Suite("The byte-level fake SMC's unlock, holds and log", .timeLimit(.minutes(1)))
struct FirmwareSMCBehaviourTests {

    private static let mode = smcKey("F0Md")
    private static let forceKey = smcKey("Ftst")
    private static let minimum = smcKey("F0Mn")

    /// One present `ui8` key and nothing else.
    private static func oneKey() -> FirmwareSMC {
        FirmwareSMC(
            keys: [
                mode: .present(SMCKeyInfo(key: mode, type: .ui8, dataSize: 1, attributes: 0xD0))
            ],
            registers: [mode: [0x00]], generation: .modern)
    }

    // MARK: - The unlock rule

    @Test("Naive: the mode write is the default answer")
    func naiveAppliesTheModeWrite() async throws {
        let firmware = FirmwareSMC.mac16x5(unlock: .naive)
        try await firmware.write([0x01], to: Self.mode)
        #expect(await firmware.register(Self.mode) == [0x01])
    }

    @Test(
        "Held until forced: 0x82 until Ftst reads 1, then the steps, then applied; a clear resets")
    func heldUntilForcedYieldsAfterTheForceKey() async throws {
        let firmware = FirmwareSMC.mac16x5(unlock: .heldUntilForced(stepsToYield: 1))
        let held = SMCError.firmware(code: 0x82)
        await #expect(throws: held) { try await firmware.write([0x01], to: Self.mode) }
        try await firmware.write([0x01], to: Self.forceKey)
        await #expect(throws: held) { try await firmware.write([0x01], to: Self.mode) }
        try await firmware.write([0x01], to: Self.mode)
        #expect(await firmware.register(Self.mode) == [0x01])

        // Clearing the force key starts the count again, as the scripted plane's does.
        try await firmware.write([0x00], to: Self.forceKey)
        try await firmware.write([0x01], to: Self.forceKey)
        await #expect(throws: held) { try await firmware.write([0x01], to: Self.mode) }
        try await firmware.write([0x01], to: Self.mode)
    }

    @Test("Never yields: 0x82 with the force key set; a zero mode write is not an engagement")
    func neverYieldsHoldsTheModeWrite() async throws {
        let firmware = FirmwareSMC.mac16x5(unlock: .neverYields)
        try await firmware.write([0x01], to: Self.forceKey)
        await #expect(throws: SMCError.firmware(code: 0x82)) {
            try await firmware.write([0x01], to: Self.mode)
        }
        try await firmware.write([0x00], to: Self.mode)
        #expect(await firmware.register(Self.mode) == [0x00])
    }

    @Test("Answers: the mode write is answered with that code")
    func answersRefusesWithTheCode() async throws {
        let firmware = FirmwareSMC.mac16x5(unlock: .answers(code: 0x89))
        await #expect(throws: SMCError.firmware(code: 0x89)) {
            try await firmware.write([0x01], to: Self.mode)
        }
    }

    @Test("Reads back: the mode write is accepted, and the register reads the scripted value")
    func readsBackLeavesTheScriptedRawMode() async throws {
        let firmware = FirmwareSMC.mac16x5(unlock: .readsBack(rawMode: 2))
        try await firmware.write([0x01], to: Self.mode)
        #expect(try await firmware.read(Self.mode).bytes == [0x02])
    }

    // MARK: - Holding, hooks and the log

    /// The hold must suspend, or every "one at a time" claim made against it passes vacuously: a
    /// double with no `await` inside cannot park anything. So this shows both halves — the read is
    /// parked, and the actor is not blocked while it is.
    @Test("A held read parks its turn, leaves the actor free, and resumes when released")
    func aHeldReadParksAndResumes() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider)
        await firmware.holdReads()

        let read = observing { try await scheduler.read(keys: ["F0Md"], at: .supervisor) }
        await yieldUntil("the read to park") { await firmware.readsParked == 1 }
        #expect(await read.isFinished.isSet == false)
        _ = try await firmware.freshKeyInfo(for: Self.forceKey)

        await firmware.releaseReads()
        let outcomes = try #require(try await finished("the held read", read))
        #expect(try outcomes.first?.result.get().value == 0)
    }

    @Test("A held walk parks and resumes, and returns every reading the table declares")
    func aHeldWalkParksAndResumes() async throws {
        let firmware = FirmwareSMC.mac16x5()
        await firmware.holdWalks()

        let walk = observing { try await firmware.provider.readAll() }
        await yieldUntil("the walk to park") { await firmware.walksParked == 1 }
        #expect(await walk.isFinished.isSet == false)

        await firmware.releaseWalks()
        let readings = try #require(try await finished("the held walk", walk))
        #expect(readings.count == 12)
    }

    @Test("A hook fires exactly once, immediately before its operation")
    func aHookFiresOnce() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let fired = HookCount()
        await firmware.onNext(.write(Self.mode)) { fired.increment() }
        try await firmware.write([0x01], to: Self.mode)
        try await firmware.write([0x00], to: Self.mode)

        #expect(fired.count == 1)
        #expect(
            firmware.log.entries == [
                .hookFired(.write(Self.mode)), .write(Self.mode, [0x01], .answered),
                .write(Self.mode, [0x00], .answered),
            ])
    }

    @Test("The log orders firmware operations against the scheduler's turns")
    func theLogOrdersOperationsAgainstTurns() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider, observer: firmware.log)
        _ = try await scheduler.read(keys: ["F0Mn"], at: .supervisor)

        #expect(
            firmware.log.entries == [
                .turnGranted(.supervisor), .providerReadBegan(["F0Mn"]),
                .keyInfo(Self.minimum, .answered), .read(Self.minimum, .answered),
                .providerReadEnded, .turnEnded(.supervisor),
            ])
    }

    @Test("The recycler closes the handle the channel uses; a read reopens it, the cache survives")
    func theRecyclerClosesTheChannelsHandle() async throws {
        let firmware = FirmwareSMC.mac16x5()
        _ = try await firmware.read(Self.mode)
        await firmware.recycler.close()
        #expect(await firmware.interfaceGeneration == nil)
        await #expect(throws: FirmwareSMC.notOpen) { try await firmware.read(Self.mode) }
        #expect(firmware.log.operations.last == .read(Self.mode, .unsent(FirmwareSMC.notOpen)))

        try await firmware.recycler.open()
        #expect(await firmware.interfaceGeneration == .modern)
        let before = firmware.log.operations.count
        _ = try await firmware.read(Self.mode)
        #expect(firmware.log.operations.count == before + 1, "the key-info cache did not survive")

        await firmware.recycler.close()
        _ = try await firmware.provider.read(keys: ["F0Md"])
        #expect(await firmware.interfaceGeneration == .modern, "a provider read did not reopen")
    }

    /// The thrown error is caught inside the block, so the one known issue that can match is the
    /// fake's own record: a fake that only threw would leave this red.
    @Test("A key the table does not declare is a scenario error, recorded as an issue")
    func anUnscriptedKeyIsRecorded() async throws {
        let firmware = Self.oneKey()
        await withKnownIssue {
            await #expect(throws: SMCError.keyNotFound(Self.forceKey)) {
                try await firmware.freshKeyInfo(for: Self.forceKey)
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("does not declare") }
        }
    }
}

/// A count a `@Sendable` hook can raise.
private final class HookCount: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
