import IOKit
import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// A scripted `READ_INDEX`: the firmware's reply code at each index, turned into a key by
/// `SMCConnection.indexedKey(fromCode:)`, the function `key(at:)` itself uses. An index with no
/// code is unanswered, the way `Mac16,5` answers an index past its table: result byte `0xB8`.
///
/// `SMCConnection` has no scripted transport, so this is handed to the walks through their
/// lookup parameter: `SMCConnection.walkKeyTable(declaredCount:keyAt:)` and
/// `SMCSensorProvider.readAll(declaredCount:keyAt:)`.
struct ScriptedIndexTable: Sendable {
    let codes: [Int: FourCharCode]

    func key(at index: Int) throws -> SMCKey {
        guard let code = codes[index] else { throw SMCError.firmware(code: 0xB8) }
        return try SMCConnection.indexedKey(fromCode: code)
    }
}

enum KeyTableCodes {
    static let fan = SMCKey("F0Ac")!
    static let temperature = SMCKey("TC0P")!
    /// A key no scripted table holds. Once discovery completes it reads `.keyNotFound` at no
    /// round trip; before, it is attempted, and an unopened connection refuses the attempt.
    static let absent = SMCKey("ZZZZ")!

    /// Codes `SMCKey` refuses, one per kind of byte outside its alphabet: zero, which the
    /// issue names; a line feed, a C0 control; DEL; and the three bytes that decode to U+2028.
    static let refused: [FourCharCode] = [0x0000_0000, 0x4630_0A63, 0x7F7F_7F7F, 0xE280_A841]
}

/// Whether discovery completed on `connection`: an absent key reads `.keyNotFound` without a
/// round trip. Before discovery completes it is attempted, and an unopened connection answers
/// the attempt with `connectionFailed`, so the two cannot be confused.
func discoveryCompleted(on connection: SMCConnection) async -> Bool {
    let outcome = await connection.read(keys: [KeyTableCodes.absent])
    return outcome.first?.result == .failure(.keyNotFound(KeyTableCodes.absent))
}

/// #623: a code `SMCKey` refuses, inside `0..<declaredCount`, is walked. Before, both walks
/// skipped it uncounted, the cross-check failed with a fault blaming ADR 0003's byte order,
/// and discovery never completed.
@Suite("Key-table walk, a code SMCKey refuses counts as walked")
struct KeyTableWalkRefusedCodeTests {

    @Test(
        "indexedKey(fromCode:) refuses exactly the codes SMCKey refuses",
        arguments: KeyTableCodes.refused)
    func indexedKeyRefusesWhatSMCKeyRefuses(code: FourCharCode) throws {
        #expect(SMCKey(fourCharCode: code) == nil)
        #expect(throws: SMCError.malformedKeyCode(code)) {
            try SMCConnection.indexedKey(fromCode: code)
        }
        let fan = KeyTableCodes.fan
        #expect(try SMCConnection.indexedKey(fromCode: fan.fourCharCode) == fan)
    }

    @Test(
        "verifyKeyCountCrossCheck's walk matches with a refused code inside the bound",
        arguments: KeyTableCodes.refused)
    func crossCheckWalksARefusedCode(code: FourCharCode) {
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: code, 2: KeyTableCodes.temperature.fourCharCode,
        ])

        let result = SMCConnection.walkKeyTable(declaredCount: 3, keyAt: table.key(at:))

        #expect(result.walkedCount == 3)
        #expect(result.matches)
    }

    @Test(
        "readAll's walk completes discovery with a refused code inside the bound",
        arguments: KeyTableCodes.refused)
    func readAllCompletesDiscoveryPastARefusedCode(code: FourCharCode) async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: code, 2: KeyTableCodes.temperature.fourCharCode,
        ])

        _ = await provider.readAll(declaredCount: 3, keyAt: table.key(at:))

        #expect(await discoveryCompleted(on: connection))
        // The two keys the table named are in the discovered set: each is attempted, and the
        // unopened connection refuses the attempt, rather than reporting it absent.
        let named = await connection.read(keys: [KeyTableCodes.fan, KeyTableCodes.temperature])
        for outcome in named {
            #expect(outcome.result == .failure(.connectionFailed(kernReturn: kIOReturnNotOpen)))
        }
    }

    @Test("A walk records a refused code with its index, and hands back no key for it")
    func walkRecordsARefusedCode() {
        var walk = KeyTableWalk(declaredCount: 3)

        #expect(walk.record(.key(KeyTableCodes.fan), at: 0) == KeyTableCodes.fan)
        #expect(walk.record(.refused(0x0000_000A), at: 1) == nil)
        #expect(walk.record(.unanswered, at: 2) == nil)

        #expect(walk.walkedCount == 2)
        #expect(walk.refusedCodes == [RefusedKeyCode(index: 1, code: 0x0000_000A)])
    }
}

/// The probe at index `declaredCount` treats a refused code as no key, the opposite of the
/// walk inside the bound. `KeyTableEntry.isKeyPastDeclaredCount` says why.
@Suite("Key-table walk, a refused code past the bound is no key")
struct KeyTableWalkProbeTests {

    @Test(
        "verifyKeyCountCrossCheck's probe finds no key at a refused code",
        arguments: KeyTableCodes.refused)
    func crossCheckProbeTreatsARefusedCodeAsAbsent(code: FourCharCode) {
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: KeyTableCodes.temperature.fourCharCode, 2: code,
        ])

        let result = SMCConnection.walkKeyTable(declaredCount: 2, keyAt: table.key(at:))

        #expect(!result.keyExistsPastDeclaredCount)
        #expect(result.matches)
    }

    @Test(
        "readAll's probe finds no key at a refused code, so discovery completes",
        arguments: KeyTableCodes.refused)
    func readAllProbeTreatsARefusedCodeAsAbsent(code: FourCharCode) async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: KeyTableCodes.temperature.fourCharCode, 2: code,
        ])

        _ = await provider.readAll(declaredCount: 2, keyAt: table.key(at:))

        #expect(await discoveryCompleted(on: connection))
    }
}

/// What the walks failed on before #623 they still fail on: a key past the bound, and an
/// index inside it that nothing answered. These pin that the seam carries the two-sided
/// tripwire, and that only a refused code, not every failure, became walked.
@Suite("Key-table walk, the cross-check still fails where it should")
struct KeyTableWalkMismatchTests {

    /// Index 1 holds a key, one past a declared count of 1.
    static let undercounted = ScriptedIndexTable(codes: [
        0: KeyTableCodes.fan.fourCharCode, 1: KeyTableCodes.temperature.fourCharCode,
    ])

    /// Index 1 is unanswered, inside a declared count of 3.
    static let holed = ScriptedIndexTable(codes: [
        0: KeyTableCodes.fan.fourCharCode, 2: KeyTableCodes.temperature.fourCharCode,
    ])

    @Test("verifyKeyCountCrossCheck's probe still finds a key past the bound")
    func crossCheckProbeFindsAKeyPastTheBound() {
        let result = SMCConnection.walkKeyTable(
            declaredCount: 1, keyAt: Self.undercounted.key(at:))

        #expect(result.keyExistsPastDeclaredCount)
        #expect(!result.matches)
    }

    @Test("readAll's probe still finds a key past the bound, so discovery does not complete")
    func readAllProbeFindsAKeyPastTheBound() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(declaredCount: 1, keyAt: Self.undercounted.key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }

    @Test("verifyKeyCountCrossCheck's walk does not count an unanswered index")
    func crossCheckDoesNotWalkAnUnansweredIndex() {
        let result = SMCConnection.walkKeyTable(declaredCount: 3, keyAt: Self.holed.key(at:))

        #expect(result.walkedCount == 2)
        #expect(!result.matches)
    }

    @Test("readAll's walk does not count an unanswered index, so discovery does not complete")
    func readAllDoesNotWalkAnUnansweredIndex() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(declaredCount: 3, keyAt: Self.holed.key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }
}

/// The line `KeyTableWalk.finish(probe:)` logs for refused codes. SMCCore logs without an
/// escape, so the line must hold nothing that can break or hide it; see
/// `KeyTableWalk.refusedCodesMessage(_:declaredCount:)`.
@Suite("Key-table walk, the refused-code log line")
struct KeyTableWalkRefusedCodeLogTests {

    @Test("No refused code, no line")
    func noRefusedCodeNoLine() {
        #expect(KeyTableWalk.refusedCodesMessage([], declaredCount: 3) == nil)
    }

    @Test("Each refused code is written in hexadecimal beside its index, with the count")
    func refusedCodesAreWrittenInHexadecimal() throws {
        let refused = [
            RefusedKeyCode(index: 1, code: 0x0000_0000),
            RefusedKeyCode(index: 2, code: 0x4630_0A63),
            RefusedKeyCode(index: 5, code: 0xE280_A841),
        ]

        let message = try #require(KeyTableWalk.refusedCodesMessage(refused, declaredCount: 7))

        #expect(message.contains("3 of 7 index-table entries"))
        #expect(message.contains("index 1: 0x00000000, index 2: 0x46300a63, index 5: 0xe280a841"))
    }

    /// The reason the codes are hexadecimal. Two of the three codes above hold a byte that,
    /// decoded, is a line feed or U+2028: either one reads in `log show` as a second entry.
    @Test("Nothing in the line is a control, format or separator character")
    func lineHoldsNothingThatBreaksIt() throws {
        let refused = KeyTableCodes.refused.enumerated().map {
            RefusedKeyCode(index: $0.offset, code: $0.element)
        }

        let message = try #require(KeyTableWalk.refusedCodesMessage(refused, declaredCount: 4))

        let breaking: [Unicode.GeneralCategory] = [
            .control, .format, .lineSeparator, .paragraphSeparator,
        ]
        let categories = message.unicodeScalars.map(\.properties.generalCategory)
        #expect(!categories.contains(where: breaking.contains))
    }

    @Test("Past the listing limit, the rest are counted rather than listed")
    func refusedCodesPastTheLimitAreCounted() throws {
        let limit = KeyTableWalk.maximumListedRefusedCodes
        let refused = (0..<(limit + 4)).map { RefusedKeyCode(index: $0, code: 0) }

        let message = try #require(
            KeyTableWalk.refusedCodesMessage(refused, declaredCount: 100))

        #expect(message.contains("index \(limit - 1): 0x00000000, and 4 more"))
        #expect(!message.contains("index \(limit): "))
    }
}

// swiftlint:enable force_unwrapping
