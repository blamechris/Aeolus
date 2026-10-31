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

        #expect(walk.crossCheck.matches)
        #expect(walk.tally.refusedCodeCount == 0)
        #expect(walk.tally.keyCount == walk.crossCheck.declaredCount)
        let published = try await connection.verifyKeyCountCrossCheck()
        #expect(published == walk.crossCheck)
    }
}
