import Foundation
import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// Index tables at `Mac16,5`'s size whose every code is a key, and the misreads of them that
/// keep every code printable: the shapes `KeyTableWalk.keySetIsPlausible` exists for (#628).
/// Each matches `#KEY`'s count, so only a check of which keys were found can refuse it.
enum KeySetIndexTables {
    static let declaredCount = MisreadIndexTables.declaredCount

    /// `#KEY` at index 0, as on `Mac16,5`, then distinct keys in ascending order, fourteen to
    /// each first three characters, the way a real table holds a family such as `TC0D`, `TC0E`.
    static let keys: [SMCKey] = [SMCKey.keyCount] + (0..<declaredCount - 1).map(synthetic)

    /// The same number of distinct keys, with no `#KEY` among them.
    static let keysWithoutKeyCount: [SMCKey] = (0..<declaredCount).map(synthetic)

    /// The key at `index` of a made-up table: `A00a`, `A00b` … `A00n`, `A01a`, and so on.
    static func synthetic(_ index: Int) -> SMCKey {
        let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array("0123456789")
        let lower = Array("abcdefghijklmn")
        return SMCKey(
            String([
                upper[index / 1_400], digits[index / 140 % 10], digits[index / 14 % 10],
                lower[index % 14],
            ]))!
    }

    /// `keys`' codes, each passed through `misread`, one per index; the probe is unanswered.
    static func table(
        of keys: [SMCKey] = KeySetIndexTables.keys,
        _ misread: (FourCharCode) -> FourCharCode = { $0 }
    ) -> ScriptedIndexTable {
        ScriptedIndexTable(
            codes: Dictionary(
                uniqueKeysWithValues: keys.enumerated().map {
                    ($0.offset, misread($0.element.fourCharCode))
                }))
    }

    /// A printable byte, standing in for whatever neighbours the key field.
    static let printable: FourCharCode = 0x20
}

/// A misread of `READ_INDEX`'s key field that keeps every code printable, so every index
/// resolves to a key and the walk matches `#KEY`. Applied to `KeySetIndexTables.keys` here, and
/// to `Mac16,5`'s own table in `KeyTableWalkMac165Tests`.
enum PrintableMisread: String, CaseIterable, Sendable, CustomTestStringConvertible {
    /// One byte forward, onto a printable neighbour: the first three characters kept.
    case forwardOntoPrintable
    /// One byte back, onto a printable neighbour: the last three characters kept.
    case backwardOntoPrintable
    /// The four bytes in reverse: `#KEY` reads as `YEK#`.
    case byteReversed
    /// The two halves swapped: `#KEY` reads as `EY#K`.
    case halvesSwapped
    /// Every index answers index 0's key, as if the index never reached the firmware.
    case everyIndexAnswersIndexZero

    var testDescription: String { rawValue }

    var table: ScriptedIndexTable { table(of: KeySetIndexTables.keys) }

    /// `keys`, in index order, read through this misread.
    func table(of keys: [SMCKey]) -> ScriptedIndexTable {
        let printable = KeySetIndexTables.printable
        let misread: (FourCharCode) -> FourCharCode
        switch self {
        case .forwardOntoPrintable:
            misread = { printable << 24 | $0 >> 8 }
        case .backwardOntoPrintable:
            misread = { $0 << 8 | printable }
        case .byteReversed:
            misread = { $0.byteSwapped }
        case .halvesSwapped:
            misread = { $0 << 16 | $0 >> 16 }
        case .everyIndexAnswersIndexZero:
            let first = keys[0].fourCharCode
            misread = { _ in first }
        }
        return KeySetIndexTables.table(of: keys, misread)
    }

    /// Whether the misread repeats keys, which the distinct-key check sees, or keeps them
    /// distinct and moves `#KEY`, which only the reordered-`#KEY` check sees.
    var repeatsKeys: Bool {
        switch self {
        case .forwardOntoPrintable, .backwardOntoPrintable, .everyIndexAnswersIndexZero: true
        case .byteReversed, .halvesSwapped: false
        }
    }
}

/// #628: discovery completes only on a key set that could be a key table. Before, every shape
/// here matched the cross-check and completed discovery, so every named read reported its key
/// absent and a Mac with fans reported none.
@Suite("Key-table walk, a key set that is no key table does not complete discovery")
struct KeyTableWalkKeySetTests {

    static let declaredCount = KeySetIndexTables.declaredCount

    /// The control: what the misreads below are misreads of passes, so each fails for its own
    /// shape and not for the fixture.
    @Test("A table of distinct keys holding #KEY is plausible, and completes discovery")
    func realLookingTableCompletesDiscovery() async {
        let walk = SMCConnection.walkKeyTable(
            declaredCount: Self.declaredCount, keyAt: KeySetIndexTables.table().key(at:))
        #expect(walk.crossCheck.matches)
        #expect(walk.tally.keys.count == Self.declaredCount)
        #expect(walk.tally.keySetIsPlausible)
        #expect(walk.tally.implausibleKeySetMessage() == nil)

        let connection = SMCConnection()
        _ = await SMCSensorProvider(connection: connection).readAll(
            declaredCount: Self.declaredCount, keyAt: KeySetIndexTables.table().key(at:))
        #expect(await discoveryCompleted(on: connection))
    }

    @Test(
        "verifyKeyCountCrossCheck's walk matches a printable misread, and finds its keys no table",
        arguments: PrintableMisread.allCases)
    func crossCheckMatchesButKeySetFails(misread: PrintableMisread) {
        let walk = SMCConnection.walkKeyTable(
            declaredCount: Self.declaredCount, keyAt: misread.table.key(at:))

        // What the cross-check alone sees: every index a key, the count matched.
        #expect(walk.tally.keyCount == Self.declaredCount)
        #expect(walk.tally.refusedCodeCount == 0)
        #expect(walk.crossCheck.matches)
        // What the key set shows.
        #expect(!walk.tally.keySetIsPlausible)
        #expect((walk.tally.duplicateKeyCount > 0) == misread.repeatsKeys)
        #expect(walk.tally.holdsReorderedKeyCountKey == !misread.repeatsKeys)
    }

    @Test(
        "readAll's walk does not complete discovery on a printable misread",
        arguments: PrintableMisread.allCases)
    func readAllDoesNotCompleteDiscoveryOnAPrintableMisread(misread: PrintableMisread) async {
        let connection = SMCConnection()

        _ = await SMCSensorProvider(connection: connection).readAll(
            declaredCount: Self.declaredCount, keyAt: misread.table.key(at:))

        #expect(await !discoveryCompleted(on: connection))
    }

    /// `#KEY` declaring 0, with nothing answered at the probe: the walk visits no index, finds
    /// no key past the bound, and matches.
    @Test("A declared count of 0 matches the cross-check, and does not complete discovery")
    func declaredZeroDoesNotCompleteDiscovery() async {
        let empty = ScriptedIndexTable(codes: [:])

        let walk = SMCConnection.walkKeyTable(declaredCount: 0, keyAt: empty.key(at:))
        #expect(walk.crossCheck.matches)
        #expect(walk.tally.keyCount == 0)
        #expect(!walk.tally.keySetIsPlausible)

        let connection = SMCConnection()
        _ = await SMCSensorProvider(connection: connection).readAll(
            declaredCount: 0, keyAt: empty.key(at:))
        #expect(await !discoveryCompleted(on: connection))
    }

    /// `#KEY` is evidence, never a requirement: Intel, M1 and M2 tables are unread, and one
    /// that does not list `#KEY` must not lose discovery for it.
    @Test("A table of distinct keys without #KEY is plausible, and completes discovery")
    func tableWithoutKeyCountCompletesDiscovery() async {
        let table = KeySetIndexTables.table(of: KeySetIndexTables.keysWithoutKeyCount)

        let walk = SMCConnection.walkKeyTable(
            declaredCount: Self.declaredCount, keyAt: table.key(at:))
        #expect(!walk.tally.keys.contains(SMCKey.keyCount))
        #expect(walk.tally.keySetIsPlausible)

        let connection = SMCConnection()
        _ = await SMCSensorProvider(connection: connection).readAll(
            declaredCount: Self.declaredCount, keyAt: table.key(at:))
        #expect(await discoveryCompleted(on: connection))
    }

    /// Only a reordering *in place of* `#KEY` counts against a table. A table that held a key
    /// spelled with `#KEY`'s bytes beside `#KEY` itself would be no sign of a reordered field.
    @Test("A reordering of #KEY beside #KEY itself is plausible, and completes discovery")
    func reorderingBesideKeyCountCompletesDiscovery() async {
        let table = ScriptedIndexTable(codes: [
            0: SMCKey.keyCount.fourCharCode, 1: KeyTableCodes.fan.fourCharCode,
            2: SMCKey("YEK#")!.fourCharCode,
        ])

        let walk = SMCConnection.walkKeyTable(declaredCount: 3, keyAt: table.key(at:))
        #expect(!walk.tally.holdsReorderedKeyCountKey)
        #expect(walk.tally.keySetIsPlausible)

        let connection = SMCConnection()
        _ = await SMCSensorProvider(connection: connection).readAll(
            declaredCount: 3, keyAt: table.key(at:))
        #expect(await discoveryCompleted(on: connection))
    }

    @Test("reorderedKeyCountKeys is #KEY's bytes in each of their 23 other orders")
    func reorderedKeyCountKeysAreTheOtherOrders() {
        let reordered = KeyTableWalk.reorderedKeyCountKeys

        #expect(reordered.count == 23)
        #expect(!reordered.contains(SMCKey.keyCount))
        #expect(reordered.contains(SMCKey("YEK#")!))
        #expect(reordered.contains(SMCKey("EY#K")!))
        #expect(reordered.allSatisfy { $0.rawValue.sorted() == SMCKey.keyCount.rawValue.sorted() })
    }
}

/// The line `KeyTableWalk.finish(probe:)` logs at `.fault` when the key set is no key table.
@Suite("Key-table walk, the implausible key set log line")
struct KeyTableWalkKeySetLogTests {

    static func walk(_ keys: [SMCKey]) -> KeyTableWalk {
        var walk = KeyTableWalk(declaredCount: keys.count)
        for (index, key) in keys.enumerated() {
            _ = walk.record(.key(key), at: index)
        }
        return walk
    }

    @Test("A walk that found no key says so")
    func noKeyIsSaid() throws {
        let message = try #require(KeyTableWalk(declaredCount: 0).implausibleKeySetMessage())

        #expect(message.contains("of 0 index-table entries"))
        #expect(message.contains("it resolved no key"))
        #expect(message.contains("Discovery does not complete"))
    }

    @Test("Repeated keys are counted, with the distinct count left")
    func repeatedKeysAreCounted() throws {
        let fan = KeyTableCodes.fan
        let walk = Self.walk([SMCKey.keyCount, fan, fan, fan])

        let message = try #require(walk.implausibleKeySetMessage())

        #expect(message.contains("2 of its 4 keys repeat one already walked, leaving 2 distinct"))
        #expect(!message.contains("another order"))
    }

    @Test("#KEY reordered in place of #KEY is said")
    func reorderedKeyCountIsSaid() throws {
        let walk = Self.walk([SMCKey("YEK#")!, KeyTableCodes.fan])

        let message = try #require(walk.implausibleKeySetMessage())

        #expect(message.contains("it holds #KEY's four bytes in another order, and not #KEY"))
        #expect(!message.contains("repeat"))
        #expect(message.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) })
    }
}

// swiftlint:enable force_unwrapping
