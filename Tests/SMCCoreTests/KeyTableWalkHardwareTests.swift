import Testing

@testable import SMCCore

/// The walk over `Mac16,5`'s real index table, read live.
///
/// `SMCConnectionMac165Tests` checks that the `#KEY` cross-check matches here. That alone would
/// still pass with a few refused codes, since the walk counts up to
/// `KeyTableWalk.maximumWalkedRefusedCodes` of them beside a key (#623). This pins the stronger
/// fact this machine shows: every entry of its table is a key, none refused and none
/// unanswered. A misread of the index table on this machine cannot hide behind the cap.
///
/// Gated on `isDevelopmentMachine()` as well as the SMC: another Mac's table may hold a code
/// `SMCKey` refuses, and that is what #623 lets it have.
@Suite(
    "Key-table walk, Mac16,5's real table",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct KeyTableWalkMac165Tests {

    @Test("Every entry of this machine's index table is a key: none refused, none unanswered")
    func everyEntryIsAKey() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let walk = try await connection.walkKeyTable()

        // Without it, a `keyCount()` of 0 would walk nothing and pass every line below.
        #expect(walk.crossCheck.declaredCount > 1000)
        #expect(walk.crossCheck.matches)
        #expect(walk.tally.refusedCodeCount == 0)
        #expect(walk.tally.keyCount == walk.crossCheck.declaredCount)
        let published = try await connection.verifyKeyCountCrossCheck()
        #expect(published == walk.crossCheck)
    }

    /// #628's guard on the one table this project has read: every key distinct, and `#KEY`
    /// itself among them, at index 0 on macOS 27.2.
    @Test("This machine's key set is plausible: no key twice, and #KEY at index 0")
    func keySetIsPlausible() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let walk = try await connection.walkKeyTable()

        #expect(walk.crossCheck.declaredCount > 1000)
        #expect(walk.tally.duplicateKeyCount == 0)
        #expect(walk.tally.keys.count == walk.crossCheck.declaredCount)
        #expect(!walk.tally.holdsReorderedKeyCountKey)
        #expect(walk.tally.keySetIsPlausible)
        #expect(try await connection.key(at: 0) == SMCKey.keyCount)
    }

    /// The misreads `KeyTableWalkKeySetTests` applies to a made-up table, applied to this
    /// machine's own, in index order. Each keeps every code printable and matches `#KEY`'s
    /// count, and each fails the key-set check. The keys are read once by the walk; reading them
    /// again in order is a cache hit, not a round trip.
    @Test(
        "This machine's table, misread so every code stays printable, is no key table",
        arguments: PrintableMisread.allCases)
    func misreadRealTableIsNoKeyTable(misread: PrintableMisread) async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }
        let declaredCount = try await connection.walkKeyTable().crossCheck.declaredCount
        try #require(declaredCount > 1000)
        var keys: [SMCKey] = []
        for index in 0..<declaredCount {
            keys.append(try await connection.key(at: index))
        }

        let walk = SMCConnection.walkKeyTable(
            declaredCount: declaredCount, keyAt: misread.table(of: keys).key(at:))

        #expect(walk.tally.refusedCodeCount == 0)
        #expect(walk.crossCheck.matches)
        #expect(!walk.tally.keySetIsPlausible)
        #expect((walk.tally.duplicateKeyCount > 0) == misread.repeatsKeys)
        #expect(walk.tally.holdsReorderedKeyCountKey == !misread.repeatsKeys)
    }
}
