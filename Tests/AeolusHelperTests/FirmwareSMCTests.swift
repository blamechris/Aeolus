import Foundation
import IOKit
import Testing
import os

@testable import AeolusHelper
@testable import SMCCore

/// `FirmwareSMC`, held to what it claims to model: one test per behaviour, so a fake that has
/// drifted from the connection it stands in for is a red line here before it is a wrong answer in
/// a write-turn test.
@Suite("The byte-level fake SMC", .timeLimit(.minutes(1)))
struct FirmwareSMCTests {

    private static let mode = smcKey("F0Md")
    private static let forceKey = smcKey("Ftst")
    private static let minimum = smcKey("F0Mn")

    /// One present `ui8` key and nothing else, for the write and read rules.
    private static func oneKey(
        _ key: SMCKey = mode, attributes: UInt8 = 0xD0, dataSize: Int = 1,
        unlock: FirmwareSMC.Unlock = .naive
    ) -> FirmwareSMC {
        FirmwareSMC(
            keys: [
                key: .present(
                    SMCKeyInfo(key: key, type: .ui8, dataSize: dataSize, attributes: attributes))
            ],
            registers: [key: [UInt8](repeating: 0, count: dataSize)], generation: .modern,
            unlock: unlock)
    }

    // MARK: - The development machine

    @Test("Mac16,5 declares and reads what docs/SMC-RESEARCH.md records for 27.0.1")
    func theDevelopmentMachineIsWhatTheResearchRecords() async throws {
        let firmware = FirmwareSMC.mac16x5()
        #expect(await firmware.interfaceGeneration == .modern)

        func info(_ raw: String, _ type: SMCKeyType, _ size: Int, _ bits: UInt8) -> SMCKeyInfo {
            SMCKeyInfo(key: smcKey(raw), type: type, dataSize: size, attributes: bits)
        }
        let declared = [
            info("F0Md", .ui8, 1, 0xD0), info("F1Md", .ui8, 1, 0xD0), info("Ftst", .ui8, 1, 0xD0),
            info("F0Mn", .flt, 4, 0x84), info("F1Mn", .flt, 4, 0x84), info("F0Mx", .flt, 4, 0x85),
            info("F1Mx", .flt, 4, 0x85), info("F0Tg", .flt, 4, 0xD4), info("F1Tg", .flt, 4, 0xD4),
            info("F0Ac", .flt, 4, 0x84), info("F1Ac", .flt, 4, 0x84), info("FNum", .ui8, 1, 0x80),
        ]
        for expected in declared {
            #expect(
                try await firmware.freshKeyInfo(for: expected.key) == expected, "\(expected.key)")
        }

        let read = try await firmware.provider.read(keys: [
            "F0Md", "F1Md", "Ftst", "F0Mn", "F0Mx", "F0Tg", "F1Tg", "F0Ac", "F1Ac", "FNum",
        ])
        let values = Dictionary(
            uniqueKeysWithValues: read.compactMap { outcome in
                (try? outcome.result.get()).map { (outcome.key, $0.value) }
            })
        #expect(values["F0Md"] == 0 && values["F1Md"] == 0 && values["Ftst"] == 0)
        #expect(values["F0Mn"] == 1350 && values["F0Mx"] == 5777)
        #expect(values["F0Tg"] == 1350 && values["F1Tg"] == 1458)
        #expect(abs((values["F0Ac"] ?? 0) - 1343.07) < 0.01)
        #expect(abs((values["F1Ac"] ?? 0) - 1457.94) < 0.01)
        #expect(values["FNum"] == 2)
        #expect(values.count == 10, "a key did not decode: \(read)")
    }

    // MARK: - The key table

    @Test("An absent key answers its scripted code everywhere, and is not found after a walk")
    func anAbsentKeyAnswersItsScriptedCode() async throws {
        let code: UInt8 = 0xA0  // this scenario's; no not-found answer is observed
        let firmware = FirmwareSMC(
            keys: [Self.forceKey: .absent(answering: code)], registers: [:], generation: .modern)

        await #expect(throws: SMCError.firmware(code: code)) {
            try await firmware.freshKeyInfo(for: Self.forceKey)
        }
        await #expect(throws: SMCError.firmware(code: code)) {
            try await firmware.read(Self.forceKey)
        }
        await #expect(throws: SMCError.firmware(code: code)) {
            try await firmware.write([0x00], to: Self.forceKey)
        }

        let before = try await firmware.provider.read(keys: ["Ftst"])
        #expect(
            before.first?.result
                == .failure(.readFailed(reason: "\(SMCError.firmware(code: code))")))

        _ = try await firmware.provider.readAll()
        let operations = firmware.log.operations.count
        let after = try await firmware.provider.read(keys: ["Ftst"])
        #expect(after.first?.result == .failure(.unknownKey("Ftst")))
        #expect(firmware.log.operations.count == operations, "a known-absent key cost a round trip")
    }

    @Test("Key info that fails fails the read, with the same error and no READ_BYTES")
    func keyInfoThatFailsFailsTheRead() async throws {
        let kernel = SMCError.connectionFailed(kernReturn: -536_870_207)
        let firmware = FirmwareSMC(
            keys: [Self.mode: .keyInfoFails(kernel)], registers: [:], generation: .modern)
        await #expect(throws: kernel) { try await firmware.freshKeyInfo(for: Self.mode) }
        await #expect(throws: kernel) { try await firmware.read(Self.mode) }
        #expect(
            firmware.log.operations == [
                .keyInfo(Self.mode, .threw(kernel)), .keyInfo(Self.mode, .threw(kernel)),
            ])
    }

    @Test("Fresh key info always asks; a read asks only on a miss")
    func theKeyInfoCacheIsModelled() async throws {
        let firmware = Self.oneKey()
        _ = try await firmware.read(Self.mode)
        _ = try await firmware.read(Self.mode)
        _ = try await firmware.freshKeyInfo(for: Self.mode)
        #expect(
            firmware.log.operations == [
                .keyInfo(Self.mode, .answered), .read(Self.mode, .answered),
                .read(Self.mode, .answered), .keyInfo(Self.mode, .answered),
            ])
    }

    // MARK: - Reads

    @Test("A read fails with a code, is lost, or is refused unsent, as the connection's would be")
    func readsFailAsTheConnectionsDo() async throws {
        let firmware = Self.oneKey()
        await firmware.setRead(of: Self.mode, .failsWithCode(0x82))
        await #expect(throws: SMCError.firmware(code: 0x82)) { try await firmware.read(Self.mode) }

        let short = SMCError.truncatedReply(expected: 80, received: 40)
        await firmware.setRead(of: Self.mode, .lost(short))
        await #expect(throws: short) { try await firmware.read(Self.mode) }

        let unreadable = Self.oneKey(attributes: 0x50)
        await #expect(throws: SMCError.notReadable(Self.mode)) {
            try await unreadable.read(Self.mode)
        }
        #expect(
            unreadable.log.operations.last == .read(Self.mode, .unsent(.notReadable(Self.mode))))

        let oversized = Self.oneKey(dataSize: 33)
        await #expect(throws: SMCError.valueTooLargeForSingleRead(key: Self.mode, dataSize: 33)) {
            try await oversized.read(Self.mode)
        }
    }

    @Test("A read with no interface generation carries no byte order, so a flt decodes to nothing")
    func anUnknownGenerationDecodesNothing() async throws {
        let firmware = FirmwareSMC.mac16x5()
        await firmware.setInterfaceGeneration(nil)
        #expect(await firmware.interfaceGeneration == nil)

        let value = try await firmware.read(Self.minimum)
        #expect(value.byteOrder == nil)
        #expect(try value.scalar() == nil)

        let read = try await firmware.provider.read(keys: ["F0Mn", "F0Md"])
        guard case .failure(.notDecodable) = read[0].result else {
            Issue.record("F0Mn decoded with no generation: \(read[0])")
            return
        }
        #expect(try read[1].result.get().value == 0, "a ui8 needs no byte order")
    }

    // MARK: - Writes

    /// One write mode, what it throws, and what the register holds after a write of `01`.
    struct WriteCase: Sendable, CustomTestStringConvertible {
        let answer: FirmwareSMC.WriteAnswer
        let thrown: SMCError?
        let register: [UInt8]
        var testDescription: String { "\(answer)" }
    }

    static let writeCases = [
        WriteCase(answer: .applies, thrown: nil, register: [0x01]),
        WriteCase(answer: .acceptsWithoutApplying, thrown: nil, register: [0x00]),
        WriteCase(answer: .refuses(code: 0x85), thrown: .firmware(code: 0x85), register: [0x00]),
        WriteCase(
            answer: .unanswered(
                .connectionFailed(kernReturn: kIOReturnNotResponding), applied: true),
            thrown: .connectionFailed(kernReturn: kIOReturnNotResponding), register: [0x01]),
        WriteCase(
            answer: .unanswered(.truncatedReply(expected: 80, received: 0), applied: false),
            thrown: .truncatedReply(expected: 80, received: 0), register: [0x00]),
    ]

    @Test("Each write mode answers and lands as stated", arguments: writeCases)
    func eachWriteModeAnswersAndLands(_ scenario: WriteCase) async throws {
        let firmware = Self.oneKey(Self.forceKey)
        await firmware.queueWrites(to: Self.forceKey, [scenario.answer])
        do {
            try await firmware.write([0x01], to: Self.forceKey)
            #expect(scenario.thrown == nil, "answered nothing")
        } catch {
            #expect(error == scenario.thrown)
        }
        #expect(await firmware.register(Self.forceKey) == scenario.register)
        #expect(
            try await firmware.read(Self.forceKey).bytes == scenario.register,
            "a read sees the register")
    }

    @Test("An empty or oversized payload is refused before any round trip")
    func anOutOfRangePayloadIsRefusedUnsent() async throws {
        let firmware = Self.oneKey()
        for payload in [[], [UInt8](repeating: 0x01, count: 33)] {
            await #expect(throws: SMCError.notPermitted) {
                try await firmware.write(payload, to: Self.mode)
            }
        }
        #expect(firmware.log.operations.count == 2, "\(firmware.log.operations)")
        #expect(firmware.log.operations.allSatisfy { !$0.isRoundTrip })
        #expect(await firmware.register(Self.mode) == [0x00])
    }

    @Test("Queued answers come first, in order, and then the default")
    func queuedAnswersComeFirst() async throws {
        let firmware = Self.oneKey(Self.forceKey)
        await firmware.setDefaultWrite(.acceptsWithoutApplying)
        await firmware.queueWrites(to: Self.forceKey, [.refuses(code: 0x82), .applies])
        await #expect(throws: SMCError.firmware(code: 0x82)) {
            try await firmware.write([0x01], to: Self.forceKey)
        }
        try await firmware.write([0x01], to: Self.forceKey)
        try await firmware.write([0x00], to: Self.forceKey)
        #expect(
            await firmware.register(Self.forceKey) == [0x01], "the default applied the last one")
    }
}
