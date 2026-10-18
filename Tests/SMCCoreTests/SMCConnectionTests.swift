import IOKit
import Testing

// `write(_:to:)` is `@_spi(FanWrite) public` — see the 2026-09-06 amendment in
// docs/ADR/0008-write-authorisation.md. `@testable` widens *internal* access and does
// nothing for an SPI group, so `anUnopenedWriteIssuesNoRoundTrip` below needs the opt-in
// by name. Because it has that opt-in, this file never obtains an opened connection.
@_spi(FanWrite) @testable import SMCCore

// swiftlint:disable force_unwrapping

/// `SMCKeyInfo.isReadable` is pure logic over a byte and needs no hardware: attribute
/// bit `0x80` is the readable flag, observed as a perfect correlation across all 3385
/// keys on `Mac16,5` (see `docs/SMC-RESEARCH.md`), but the bit itself is just arithmetic.
@Suite("SMC key info readability")
struct SMCKeyInfoTests {

    @Test("Bit 0x80 set makes a key readable")
    func bitSetIsReadable() {
        let info = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0x80)
        #expect(info.isReadable)
    }

    @Test("Bit 0x80 clear makes a key unreadable, regardless of other bits")
    func bitClearIsNotReadable() {
        let info = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0x54)
        #expect(!info.isReadable)
    }

    @Test("Other attribute bits do not affect readability")
    func otherBitsAreIgnored() {
        let readable = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0xC4)
        let unreadable = SMCKeyInfo(key: SMCKey("F0Ac")!, type: .flt, dataSize: 4, attributes: 0x07)
        #expect(readable.isReadable)
        #expect(!unreadable.isReadable)
    }
}

/// Behaviour that does not require a real SMC: every read entry point must refuse
/// cleanly, rather than crash, when the connection has never been opened. This is
/// checked before any IOKit call is issued, so it holds identically on real hardware
/// and on CI's SMC-less virtual machines.
@Suite("SMC connection, unopened")
struct SMCConnectionUnopenedTests {

    @Test("keyCount() throws rather than reading through a closed connection")
    func keyCountThrowsWhenUnopened() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.keyCount()
        }
    }

    @Test("key(at:) throws rather than reading through a closed connection")
    func keyAtIndexThrowsWhenUnopened() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.key(at: 0)
        }
    }

    @Test("read(_:) throws rather than reading through a closed connection")
    func readThrowsWhenUnopened() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.read(SMCKey("F0Ac")!)
        }
    }

    @Test("keyInfo(for:) throws rather than reading through a closed connection")
    func keyInfoThrowsWhenUnopened() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.keyInfo(for: SMCKey("F0Ac")!)
        }
    }

    @Test("close() on a never-opened connection is a harmless no-op")
    func closeWithoutOpenDoesNotThrow() async {
        let connection = SMCConnection()
        await connection.close()
    }

    @Test("A negative index is rejected without ever reaching IOKit")
    func negativeIndexIsRejected() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.invalidIndex(-1)) {
            _ = try await connection.key(at: -1)
        }
    }

    /// The inversion of what this test asserted before the write had a body: then every write
    /// threw `notPermitted` whatever the handle. Now a well-formed write is no longer refused
    /// by SMCCore's own rule — it reaches the connection, and an unopened one refuses it as
    /// not open before anything is stamped or sent.
    @Test("write(_:to:) on an unopened connection is refused as unopened, with no round trip")
    func anUnopenedWriteIssuesNoRoundTrip() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.connectionFailed(kernReturn: kIOReturnNotOpen)) {
            try await connection.write([0x00], to: SMCKey("F0Md")!)
        }
        #expect(connection.roundTrips.issuedCount == 0)
        #expect(connection.roundTrips.lastBegunOperation == nil)
    }
}

/// The read cache #32 adds: populated once, reused, invalidated correctly, and a subset
/// read that skips a round trip once it is warm — all provable without hardware, by
/// seeding the cache directly (see `SMCConnection`'s test-only seams) and observing
/// behaviour on a connection that is deliberately never opened. If a lookup returns
/// without throwing `SMCError.connectionFailed`, or `readKeyInfoAttempts`/
/// `readIndexAttempts` stays at 0, that lookup could not have reached IOKit — the guard
/// at the top of `call(_:)` throws immediately on an unopened
/// connection, before any wire call, so the only way to avoid that is a cache hit.
@Suite("SMC connection, read cache")
struct SMCConnectionCacheTests {

    @Test("keyInfo(for:) returns a seeded entry without attempting READ_KEYINFO")
    func keyInfoServesFromCache() async throws {
        let connection = SMCConnection()
        let key = SMCKey("F0Ac")!
        let info = SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 0x80)
        await connection.seedKeyInfoCacheForTesting(info)

        let result = try await connection.keyInfo(for: key)
        #expect(result == info)
        #expect(await connection.readKeyInfoAttempts == 0)
    }

    @Test("keyInfo(for:) on a cold cache attempts READ_KEYINFO and fails without a connection")
    func keyInfoColdCacheAttemptsAndFails() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.keyInfo(for: SMCKey("F0Ac")!)
        }
        #expect(await connection.readKeyInfoAttempts == 1)
    }

    /// A6: the write path's key-info read never answers from the cache. The handle is the dead
    /// port, so the `READ_KEYINFO` is stamped and fails inside IOKit with nothing sent; a
    /// version that served the seeded entry would return it, issuing nothing.
    @Test("freshKeyInfo(for:) issues READ_KEYINFO even when the cache holds the key")
    func freshKeyInfoBypassesTheCache() async throws {
        let connection = SMCConnection()
        let monitor = connection.roundTrips
        let key = SMCKey("F0Md")!
        let seeded = SMCKeyInfo(key: key, type: .ui8, dataSize: 1, attributes: 0xD0)
        await connection.seedKeyInfoCacheForTesting(seeded)
        await connection.adoptUnusableHandleForTesting()

        await #expect(throws: SMCError.self) {
            _ = try await connection.freshKeyInfo(for: key)
        }

        #expect(monitor.issuedCount == 1, "one READ_KEYINFO, whatever the cache held")
        #expect(monitor.lastBegunOperation == .call(key: key.fourCharCode, selector: 9))
        #expect(await connection.readKeyInfoAttempts == 1)

        // A failure leaves the cache as it was: the read path still answers from it, and
        // that answer costs nothing.
        #expect(try await connection.keyInfo(for: key) == seeded)
        #expect(monitor.issuedCount == 1)
        await connection.close()
    }

    @Test("key(at:) returns a seeded entry without attempting READ_INDEX")
    func keyAtIndexServesFromCache() async throws {
        let connection = SMCConnection()
        let key = SMCKey("F0Ac")!
        await connection.seedKeyTableCacheForTesting(index: 0, key: key)

        let result = try await connection.key(at: 0)
        #expect(result == key)
        #expect(await connection.readIndexAttempts == 0)
    }

    @Test("key(at:) on a cold cache attempts READ_INDEX and fails without a connection")
    func keyAtIndexColdCacheAttemptsAndFails() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.key(at: 0)
        }
        #expect(await connection.readIndexAttempts == 1)
    }

    @Test("invalidate() forces keyInfo(for:) to rediscover rather than trust the seeded entry")
    func invalidateClearsKeyInfoCache() async {
        let connection = SMCConnection()
        let key = SMCKey("F0Ac")!
        await connection.seedKeyInfoCacheForTesting(
            SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 0x80))
        await connection.invalidate()

        await #expect(throws: SMCError.self) {
            _ = try await connection.keyInfo(for: key)
        }
        #expect(await connection.readKeyInfoAttempts == 1)
    }

    @Test("invalidate() forces key(at:) to rediscover rather than trust the seeded entry")
    func invalidateClearsKeyTableCache() async {
        let connection = SMCConnection()
        await connection.seedKeyTableCacheForTesting(index: 0, key: SMCKey("F0Ac")!)
        await connection.invalidate()

        await #expect(throws: SMCError.self) {
            _ = try await connection.key(at: 0)
        }
        #expect(await connection.readIndexAttempts == 1)
    }

    @Test("read(_:) with a warm keyInfo cache skips READ_KEYINFO and only attempts READ_BYTES")
    func readSkipsKeyInfoOnWarmCache() async {
        let connection = SMCConnection()
        let key = SMCKey("F0Ac")!
        await connection.seedKeyInfoCacheForTesting(
            SMCKeyInfo(key: key, type: .flt, dataSize: 4, attributes: 0x80))

        // The connection is never opened, so the READ_BYTES attempt this makes is bound
        // to fail — the point is *which* round trip was skipped, not that this succeeds.
        await #expect(throws: SMCError.self) {
            _ = try await connection.read(key)
        }
        #expect(await connection.readKeyInfoAttempts == 0)
    }

    @Test("read(_:) on a cold cache attempts READ_KEYINFO first")
    func readAttemptsKeyInfoOnColdCache() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.self) {
            _ = try await connection.read(SMCKey("F0Ac")!)
        }
        #expect(await connection.readKeyInfoAttempts == 1)
    }

    @Test("read(keys:) returns one outcome per requested key, in the order requested")
    func readKeysReturnsOneOutcomePerKey() async {
        let connection = SMCConnection()
        let keys = [SMCKey("F0Ac")!, SMCKey("F0Tg")!, SMCKey("F0Ac")!]

        let outcomes = await connection.read(keys: keys)

        #expect(outcomes.map(\.key) == keys)
    }

    @Test("read(keys:) reports keyNotFound at zero round trips once discovery excludes the key")
    func readKeysReportsKeyNotFoundAfterDiscovery() async {
        let connection = SMCConnection()
        let known = SMCKey("F0Ac")!
        let missing = SMCKey("ZZZZ")!
        await connection.markDiscoveryComplete([known])

        let outcomes = await connection.read(keys: [missing])

        let expected = SMCKeyReadOutcome(key: missing, result: .failure(.keyNotFound(missing)))
        #expect(outcomes == [expected])
        // Zero round trips: the connection was never opened, and a real attempt would
        // have incremented this from a READ_KEYINFO call.
        #expect(await connection.readKeyInfoAttempts == 0)
    }

    @Test("read(keys:) attempts a key discovery confirmed exists, rather than assuming success")
    func readKeysAttemptsAKnownKey() async {
        let connection = SMCConnection()
        let key = SMCKey("F0Ac")!
        await connection.markDiscoveryComplete([key])

        let outcomes = await connection.read(keys: [key])

        guard case .failure(let error) = outcomes[0].result else {
            Issue.record("expected a failure — the connection was never opened")
            return
        }
        // Confirmed known, so this must be a real attempt (connectionFailed, since the
        // connection is closed), never a fabricated keyNotFound.
        #expect(error != .keyNotFound(key))
        #expect(await connection.readKeyInfoAttempts == 1)
    }

    @Test("read(keys:) before any full discovery attempts every key rather than assuming unknown")
    func readKeysAttemptsBeforeDiscovery() async {
        let connection = SMCConnection()
        let key = SMCKey("ZZZZ")!

        let outcomes = await connection.read(keys: [key])

        guard case .failure(let error) = outcomes[0].result else {
            Issue.record("expected a failure — the connection was never opened")
            return
        }
        #expect(error != .keyNotFound(key))
        #expect(await connection.readKeyInfoAttempts == 1)
    }
}

/// `SMCConnection.validatePlausibleKeyCount(_:)` is the sanity bound the write-up on
/// issue #30 asked for: a decoded `#KEY` must never reach an allocation or a loop bound
/// unchecked, because a misdecoded one is exactly the scenario the byte-order tripwire
/// exists to catch, and an unbounded count turns the tripwire into a ~957-million-element
/// allocation and a ~957-million-iteration loop instead of a report. Pure and synchronous,
/// so none of this needs hardware.
@Suite("SMC key count plausibility bound")
struct SMCConnectionKeyCountPlausibilityTests {

    @Test("A normal count (3385, observed on Mac16,5) passes through unchanged")
    func normalCountPasses() throws {
        #expect(try SMCConnection.validatePlausibleKeyCount(3385) == 3385)
    }

    @Test("The exact byte-swap artefact observed on Mac16,5 is rejected")
    func exactObservedArtefactIsRejected() {
        // #KEY's raw bytes (00000d39) decode to 3385 big-endian (correct) or
        // 957,153,280 little-endian — the exact value a byte-order regression on a
        // future machine would hand to keyCount() if this bound did not exist.
        #expect(throws: SMCError.implausibleKeyCount(declared: 957_153_280)) {
            _ = try SMCConnection.validatePlausibleKeyCount(957_153_280)
        }
    }

    @Test("A count exactly at the ceiling is accepted; one above is rejected")
    func ceilingIsInclusive() throws {
        let ceiling = SMCConnection.maxPlausibleKeyCount
        #expect(try SMCConnection.validatePlausibleKeyCount(ceiling) == ceiling)
        #expect(throws: SMCError.implausibleKeyCount(declared: ceiling + 1)) {
            _ = try SMCConnection.validatePlausibleKeyCount(ceiling + 1)
        }
    }

    @Test("A negative count is rejected, not just a huge one")
    func negativeCountIsRejected() {
        #expect(throws: SMCError.implausibleKeyCount(declared: -1)) {
            _ = try SMCConnection.validatePlausibleKeyCount(-1)
        }
    }
}

/// `SMCConnection.decodeKeyCountFallback(value:)` is the fix for the blocker found in
/// review of #34: without it, a machine whose SMC interface generation cannot be
/// determined gets zero sensor readings at all, not just degraded display-grade
/// integers, because `#KEY` itself is a plain integer and `readAll()`/
/// `verifyKeyCountCrossCheck()` cannot proceed without a key count. Pure and
/// synchronous — no hardware, no actor, no connection needed — since it operates only on
/// an already-constructed `SMCValue`.
@Suite("SMC #KEY generation-undetermined fallback decode")
struct SMCConnectionKeyCountFallbackTests {

    @Test("#KEY's captured Mac16,5 bytes decode to 3385 via the fallback, matching the resolver")
    func decodesTheCapturedBytes() {
        // Same raw bytes as SMCByteOrderCapturedBytesTests.keyCountDecodesBigEndian, so
        // the fallback and the resolver agree on the one case this project has observed.
        let value = SMCValue(key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39])
        #expect(SMCConnection.decodeKeyCountFallback(value: value) == 3385)
    }

    @Test("A key other than #KEY is refused, even with #KEY's own type and bytes")
    func refusesAKeyThatIsNotKeyCount() {
        let value = SMCValue(key: SMCKey("RBID")!, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39])
        #expect(SMCConnection.decodeKeyCountFallback(value: value) == nil)
    }

    @Test("A type other than ui32 is refused, even for the #KEY key itself")
    func refusesAWrongType() {
        let value = SMCValue(key: SMCKey.keyCount, type: .ui16, bytes: [0x0D, 0x39])
        #expect(SMCConnection.decodeKeyCountFallback(value: value) == nil)
    }

    @Test("A byte count other than 4 is refused rather than decoding a partial value")
    func refusesTheWrongByteCount() {
        let short = SMCValue(key: SMCKey.keyCount, type: .ui32, bytes: [0x0D, 0x39])
        let long = SMCValue(
            key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x00, 0x0D, 0x39])
        #expect(SMCConnection.decodeKeyCountFallback(value: short) == nil)
        #expect(SMCConnection.decodeKeyCountFallback(value: long) == nil)
    }
}

/// `KeyCountCrossCheck.matches` folding in `keyExistsPastDeclaredCount` is what makes the
/// tripwire two-sided: a declared count that undercounts the real table walks and
/// succeeds on every index inside its own (too-small) bound, so `declaredCount ==
/// walkedCount` alone reports a spurious match. Pure struct logic, no hardware.
@Suite("KeyCountCrossCheck — two-sided matches")
struct KeyCountCrossCheckMatchesTests {

    @Test("Equal counts with nothing past the bound: matches")
    func equalCountsNothingPastBoundMatches() {
        let result = KeyCountCrossCheck(declaredCount: 3385, walkedCount: 3385)
        #expect(result.matches)
    }

    @Test("Equal counts but a key exists past the declared bound: does not match")
    func equalCountsButUndercountedDoesNotMatch() {
        // The exact blind spot this field closes: a #KEY that undercounts the real table
        // would otherwise report a clean match here.
        let result = KeyCountCrossCheck(
            declaredCount: 3385, walkedCount: 3385, keyExistsPastDeclaredCount: true)
        #expect(!result.matches)
    }

    @Test("Unequal counts still do not match, regardless of the past-bound probe")
    func unequalCountsDoNotMatch() {
        let result = KeyCountCrossCheck(declaredCount: 3385, walkedCount: 3000)
        #expect(!result.matches)
    }

    @Test("keyExistsPastDeclaredCount defaults to false for one-sided callers")
    func defaultsToFalse() {
        let result = KeyCountCrossCheck(declaredCount: 10, walkedCount: 10)
        #expect(!result.keyExistsPastDeclaredCount)
        #expect(result.matches)
    }
}

// swiftlint:enable force_unwrapping
