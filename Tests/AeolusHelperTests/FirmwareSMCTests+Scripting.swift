import Foundation
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// `FirmwareSMC`'s scripting surface for B1's later write turns: varying a `Mac16,5` key or
/// register, building `flt` bytes, an absent key's answer as an error, the unlock precondition,
/// the after-answer hook, and the claim the fake is built on — that a scheduler read sees what a
/// channel write set. Beside `FirmwareSMCBehaviourTests` for length.
@Suite("The byte-level fake SMC's scripting", .timeLimit(.minutes(1)))
struct FirmwareSMCScriptingTests {

    private static let mode = smcKey("F0Md")
    private static let forceKey = smcKey("Ftst")
    private static let minimum = smcKey("F0Mn")

    /// The fake's headline claim: `provider` reads the registers a channel write set, through the
    /// real scheduler, in a later turn.
    ///
    /// **Mutation:** make `providerRead(_:)` answer each key with its construction-time value,
    /// `[0x00]`, instead of reading the register. Run: red here.
    @Test("A scheduler read through the provider sees what a write turn set")
    func aSchedulerReadSeesAChannelWrite() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let scheduler = SMCReadScheduler(provider: firmware.provider)
        try await scheduler.withWriteTurn(at: .supervisor, on: firmware) { channel in
            try channel.write([0x01], to: Self.mode)
        }
        let outcomes = try await scheduler.read(keys: ["F0Md"], at: .supervisor)
        #expect(try outcomes.first?.result.get().value == 1)
    }

    @Test("A declared key and a set register are what later reads answer")
    func aDeclaredKeyAndASetRegisterAreRead() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let third = smcKey("F2Md")
        await firmware.declare(
            third, .present(SMCKeyInfo(key: third, type: .ui8, dataSize: 1, attributes: 0xD0)))
        await firmware.setRegister(third, [0x01])
        #expect(try await firmware.read(third).bytes == [0x01])

        _ = try await firmware.read(Self.minimum)
        await firmware.setRegister(Self.minimum, FirmwareSMC.flt(rpm: 1200))
        #expect(try await firmware.read(Self.minimum).scalar() == 1200)

        let kernel = SMCError.connectionFailed(kernReturn: Int32(bitPattern: 0xE000_02C1))
        _ = try await firmware.freshKeyInfo(for: Self.forceKey)
        await firmware.declare(Self.forceKey, .absent(answering: kernel))
        await #expect(throws: kernel) { try await firmware.read(Self.forceKey) }
        #expect(
            firmware.log.operations.last == .keyInfo(Self.forceKey, .threw(kernel)),
            "the redeclared key's cached info was used instead of asking")
    }

    @Test("flt bytes for an RPM are the bytes the machine recorded")
    func fltBytesMatchTheRecordedOnes() {
        #expect(FirmwareSMC.flt(rpm: 1350) == [0x00, 0xC0, 0xA8, 0x44])
        #expect(FirmwareSMC.flt(rpm: 5777) == [0x00, 0x88, 0xB4, 0x45])
        #expect(FirmwareSMC.flt(rpm: 1458) == [0x00, 0x40, 0xB6, 0x44])
    }

    /// An absent key's answer can be a kernel return, as 27.0.1's key-info failures were, and it is
    /// still absent: every member answers it after a round trip, and a walk leaves the key out.
    @Test("An absent key can answer a kernel return, everywhere, and a walk leaves it out")
    func anAbsentKeyCanAnswerAKernelReturn() async throws {
        let kernel = SMCError.connectionFailed(kernReturn: Int32(bitPattern: 0xE000_02C1))
        let firmware = FirmwareSMC(
            keys: [Self.forceKey: .absent(answering: kernel)], registers: [:], generation: .modern)

        await #expect(throws: kernel) { try await firmware.freshKeyInfo(for: Self.forceKey) }
        await #expect(throws: kernel) { try await firmware.read(Self.forceKey) }
        await #expect(throws: kernel) { try await firmware.write([0x00], to: Self.forceKey) }
        #expect(
            firmware.log.operations.last == .write(Self.forceKey, [0x00], .threw(kernel)),
            "a write to an absent key is a round trip the firmware answers")

        _ = try await firmware.provider.readAll()
        let after = try await firmware.provider.read(keys: ["Ftst"])
        #expect(after.first?.result == .failure(.unknownKey("Ftst")))
    }

    /// `.answers(code:)` is a code neither `0x00` nor `0x82`; either of those is another case, and
    /// a scenario that spelled it this way would read as testing something it does not.
    ///
    /// **Mutation:** make the check in `FirmwareSMC.init` never fire (`&&` for `||`). Run: red
    /// here.
    @Test("An unlock answering 0x00 or 0x82 through answers(code:) is refused")
    func theAnswersCaseRefusesTheOtherCasesCodes() {
        for code: UInt8 in [0x00, 0x82] {
            withKnownIssue("\(code)") {
                _ = FirmwareSMC.mac16x5(unlock: .answers(code: code))
            } matching: { issue in
                issue.comments.contains { $0.rawValue.contains("answers(code:") }
            }
        }
        _ = FirmwareSMC.mac16x5(unlock: .answers(code: 0x89))
    }

    /// **Mutation:** fire the after-hook before the operation logs its answer. Run: red here.
    @Test("An after-hook fires once, after its operation is answered, thrown or not")
    func anAfterHookFiresOnceAfterTheAnswer() async throws {
        let firmware = FirmwareSMC.mac16x5()
        let fired = OSAllocatedUnfairLock(initialState: 0)
        await firmware.queueWrites(to: Self.mode, [.refuses(code: 0x89)])
        await firmware.onAfter(.write(Self.mode)) { fired.withLock { $0 += 1 } }
        await #expect(throws: SMCError.firmware(code: 0x89)) {
            try await firmware.write([0x01], to: Self.mode)
        }
        try await firmware.write([0x01], to: Self.mode)

        #expect(fired.withLock { $0 } == 1)
        #expect(
            firmware.log.entries == [
                .write(Self.mode, [0x01], .threw(.firmware(code: 0x89))),
                .afterHookFired(.write(Self.mode)),
                .write(Self.mode, [0x01], .answered),
            ])
    }
}
