import Foundation
import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// Index tables a misread of `READ_INDEX`'s reply would produce, at `Mac16,5`'s size. Before
/// the cap on refused codes, both passed the cross-check and completed discovery with an empty
/// key set (the #627 review): every named read then reported its key absent.
enum MisreadIndexTables {
    /// `Mac16,5`'s declared key count on macOS 27.2.
    static let declaredCount = 3_514

    /// Every index, the probe included, answers code zero with result byte 0: what the
    /// zero-filled reply buffer decodes to when the firmware never writes the key field.
    static let allZero = ScriptedIndexTable(
        codes: Dictionary(uniqueKeysWithValues: (0...declaredCount).map { ($0, 0) }))

    /// Real-looking keys read one byte off, where the byte after the key field is zero: each
    /// code shifted left eight bits, so `SMCKey` refuses every one. Past the table, `0xB8`.
    static let shifted = ScriptedIndexTable(
        codes: Dictionary(
            uniqueKeysWithValues: (0..<declaredCount).map { index in
                let key = SMCKey("K\(index % 10)\(index / 10 % 10)\(index / 100 % 10)")!
                return (index, key.fourCharCode << 8)
            }))

    /// A distinct nonzero code `SMCKey` refuses: `F0`, a line feed, then `offset`'s byte.
    static func refusedCode(_ offset: Int) -> FourCharCode {
        0x4630_0A00 | FourCharCode(offset % 0xFF + 1)
    }

    /// `refused` nonzero refused codes between two keys, in a table that declares all of them.
    static func refusing(_ refused: Int) -> ScriptedIndexTable {
        var codes = [0: KeyTableCodes.fan.fourCharCode]
        for offset in 0..<refused {
            codes[1 + offset] = refusedCode(offset)
        }
        codes[refused + 1] = KeyTableCodes.temperature.fourCharCode
        return ScriptedIndexTable(codes: codes)
    }

    /// `count` nonzero refused codes and no key at all; the probe at `count` is unanswered.
    static func allRefused(_ count: Int) -> ScriptedIndexTable {
        ScriptedIndexTable(
            codes: Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, refusedCode($0)) }))
    }

    /// One key at index 0, then `refused` nonzero refused codes.
    static func oneKeyRefusing(_ refused: Int) -> ScriptedIndexTable {
        var codes = [0: KeyTableCodes.fan.fourCharCode]
        for offset in 0..<refused {
            codes[1 + offset] = refusedCode(offset)
        }
        return ScriptedIndexTable(codes: codes)
    }
}

/// The #627 review's blocker, and its zero-code companion. A walk that resolved no key must
/// not match `#KEY`, and must not complete discovery. `SMCConnection.logCrossCheck(_:)` logs its
/// fault on exactly `!matches`, so each `!matches` below is also the fault being logged; the
/// log itself is not read back, as nowhere in this repository reads `OSLogStore`.
@Suite("Key-table walk, a misread table fails the cross-check")
struct KeyTableWalkMisreadTests {

    @Test("A zero code is unanswered, not refused; a nonzero code with zero bytes is refused")
    func zeroCodeIsUnanswered() {
        let table = ScriptedIndexTable(codes: [0: 0, 1: 0x0000_0041])

        #expect(KeyTableEntry(lookingUp: 0, in: table.key(at:)) == .unanswered)
        #expect(KeyTableEntry(lookingUp: 1, in: table.key(at:)) == .refused(0x0000_0041))
    }

    @Test("verifyKeyCountCrossCheck's walk does not count a zero code inside the bound")
    func crossCheckDoesNotWalkAZeroCode() {
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: 0, 2: KeyTableCodes.temperature.fourCharCode,
        ])

        let result = SMCConnection.walkKeyTable(declaredCount: 3, keyAt: table.key(at:)).crossCheck

        #expect(result.walkedCount == 2)
        #expect(!result.matches)
    }

    @Test("readAll's walk does not count a zero code, so discovery does not complete")
    func readAllDoesNotWalkAZeroCode() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)
        let table = ScriptedIndexTable(codes: [
            0: KeyTableCodes.fan.fourCharCode, 1: 0, 2: KeyTableCodes.temperature.fourCharCode,
        ])

        _ = await provider.readAll(declaredCount: 3, keyAt: table.key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }

    @Test("verifyKeyCountCrossCheck's walk fails an all-zero table")
    func crossCheckFailsAnAllZeroTable() {
        let result = SMCConnection.walkKeyTable(
            declaredCount: MisreadIndexTables.declaredCount,
            keyAt: MisreadIndexTables.allZero.key(at:)
        ).crossCheck

        #expect(result.walkedCount == 0)
        #expect(!result.matches)
    }

    @Test("readAll's walk fails an all-zero table, so discovery does not complete")
    func readAllFailsAnAllZeroTable() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        let readings = await provider.readAll(
            declaredCount: MisreadIndexTables.declaredCount,
            keyAt: MisreadIndexTables.allZero.key(at:))

        #expect(readings.isEmpty)
        #expect(await !discoveryCompleted(on: connection))
    }

    @Test("verifyKeyCountCrossCheck's walk counts no refused code in a table read one byte off")
    func crossCheckFailsAShiftedTable() {
        let walk = SMCConnection.walkKeyTable(
            declaredCount: MisreadIndexTables.declaredCount,
            keyAt: MisreadIndexTables.shifted.key(at:))

        #expect(walk.tally.refusedCodeCount == MisreadIndexTables.declaredCount)
        #expect(walk.crossCheck.walkedCount == 0)
        #expect(!walk.crossCheck.matches)
    }

    @Test("readAll's walk fails a table read one byte off, so discovery does not complete")
    func readAllFailsAShiftedTable() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(
            declaredCount: MisreadIndexTables.declaredCount,
            keyAt: MisreadIndexTables.shifted.key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }
}

/// `KeyTableWalk.maximumWalkedRefusedCodes`: up to it, refused codes are walked; one more, and
/// none is.
@Suite("Key-table walk, the cap on refused codes")
struct KeyTableWalkRefusedCapTests {

    static let cap = KeyTableWalk.maximumWalkedRefusedCodes

    @Test("verifyKeyCountCrossCheck's walk matches with exactly the cap refused")
    func crossCheckMatchesAtTheCap() {
        let result = SMCConnection.walkKeyTable(
            declaredCount: Self.cap + 2, keyAt: MisreadIndexTables.refusing(Self.cap).key(at:)
        ).crossCheck

        #expect(result.walkedCount == Self.cap + 2)
        #expect(result.matches)
    }

    @Test("verifyKeyCountCrossCheck's walk counts none of them with one past the cap refused")
    func crossCheckFailsPastTheCap() {
        let result = SMCConnection.walkKeyTable(
            declaredCount: Self.cap + 3, keyAt: MisreadIndexTables.refusing(Self.cap + 1).key(at:)
        ).crossCheck

        #expect(result.walkedCount == 2)
        #expect(!result.matches)
    }

    @Test("readAll's walk completes discovery with exactly the cap refused")
    func readAllCompletesDiscoveryAtTheCap() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(
            declaredCount: Self.cap + 2, keyAt: MisreadIndexTables.refusing(Self.cap).key(at:))

        #expect(await discoveryCompleted(on: connection))
    }

    @Test("readAll's walk does not complete discovery with one past the cap refused")
    func readAllFailsPastTheCap() async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(
            declaredCount: Self.cap + 3, keyAt: MisreadIndexTables.refusing(Self.cap + 1).key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }
}

/// The delta review's case: the cap is absolute, so a `#KEY` of eight or fewer with every reply
/// a nonzero refused code walked every index and matched. `KeyTableWalk.refusedCodesAreWalked`
/// now also needs a key. Beside one key, up to the cap still counts.
@Suite("Key-table walk, refused codes with no key beside them")
struct KeyTableWalkNoKeyTests {

    static let counts = Array(1...KeyTableWalk.maximumWalkedRefusedCodes)

    @Test(
        "verifyKeyCountCrossCheck's walk fails a small table of refused codes only",
        arguments: counts)
    func crossCheckFailsASmallAllRefusedTable(count: Int) {
        let result = SMCConnection.walkKeyTable(
            declaredCount: count, keyAt: MisreadIndexTables.allRefused(count).key(at:)
        ).crossCheck

        #expect(result.walkedCount == 0)
        #expect(!result.matches)
    }

    @Test("readAll's walk does not complete discovery on refused codes only", arguments: counts)
    func readAllFailsASmallAllRefusedTable(count: Int) async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(
            declaredCount: count, keyAt: MisreadIndexTables.allRefused(count).key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }

    @Test("verifyKeyCountCrossCheck's walk matches one key beside refused codes", arguments: counts)
    func crossCheckMatchesOneKeyBesideRefusedCodes(refused: Int) {
        let result = SMCConnection.walkKeyTable(
            declaredCount: refused + 1, keyAt: MisreadIndexTables.oneKeyRefusing(refused).key(at:)
        ).crossCheck

        #expect(result.walkedCount == refused + 1)
        #expect(result.matches)
    }

    @Test("readAll's walk completes discovery with one key beside refused codes", arguments: counts)
    func readAllCompletesDiscoveryWithOneKeyBesideRefusedCodes(refused: Int) async {
        let connection = SMCConnection()
        let provider = SMCSensorProvider(connection: connection)

        _ = await provider.readAll(
            declaredCount: refused + 1, keyAt: MisreadIndexTables.oneKeyRefusing(refused).key(at:))

        #expect(await discoveryCompleted(on: connection))
    }
}

// swiftlint:enable force_unwrapping
