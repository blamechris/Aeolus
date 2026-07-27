import Testing

@testable import SMCCore

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

    @Test("The write path stays refused; E1 adds no write selector")
    func writeStaysRefused() async {
        let connection = SMCConnection()
        await #expect(throws: SMCError.notPermitted) {
            try await connection.write([0x00], to: SMCKey("F0Md")!)
        }
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

/// Facts true of *any* machine exposing the `AppleSMC` IOService: enumeration completes,
/// `#KEY`'s own value is what the walk uses as its bound, and a failed key read never
/// aborts the walk. Gated only on `SMCConnection.isHardwareAvailable()` — cheap,
/// synchronous, false on every GitHub Actions macOS runner (no SMC at all), true on every
/// real Mac including CI's absence. Nothing here assumes a fan exists, a specific key
/// exists, or a specific count — see `SMCConnectionMac165Tests` below for assertions that
/// are actually facts about this project's one verified machine.
@Suite("SMC connection, real hardware", .enabled(if: SMCConnection.isHardwareAvailable()))
struct SMCConnectionHardwareTests {

    @Test("open() succeeds, is idempotent, and the connection survives being reopened")
    func openCloseReopen() async throws {
        let connection = SMCConnection()
        try await connection.open()
        try await connection.open()  // idempotent: must not throw or duplicate-open
        await connection.close()
        await connection.close()  // idempotent: must not throw when already closed
        try await connection.open()  // reopening after close must succeed again

        let count = try await connection.keyCount()
        #expect(count > 0)
        await connection.close()
    }

    @Test("#KEY reports its count honouring its own big-endian value")
    func keyCountIsPositiveAndPlausible() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let count = try await connection.keyCount()
        // Observed 3385 on Mac16,5 / macOS 26.5.2; assert a broad sanity range rather
        // than the exact figure so this does not go red on a firmware update that adds
        // or removes a handful of keys, and so it holds on any other Mac's key table
        // too. See docs/SMC-RESEARCH.md for the exact number observed on Mac16,5 and
        // cross-checked against a full manual enumeration.
        #expect(count > 1000)
        #expect(count < 10000)
    }

    @Test("Index enumeration walks the full key table without a hard-coded list")
    func enumeratesEveryIndex() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let count = try await connection.keyCount()
        var seen = Set<SMCKey>()
        for index in 0..<count {
            let key = try await connection.key(at: index)
            seen.insert(key)
        }
        // Duplicates are possible in principle; the meaningful assertion is that the
        // whole table walked without throwing and produced a large, plausible set that
        // includes the very key (#KEY) that told it how far to walk.
        #expect(seen.count > 1000)
        #expect(seen.contains(SMCKey.keyCount))
    }

    @Test("Enumerating every key completes despite all three failure modes")
    func fullEnumerationSurvivesFailures() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let count = try await connection.keyCount()
        var readable = 0
        var failed = 0

        for index in 0..<count {
            guard let key = try? await connection.key(at: index) else {
                failed += 1
                continue
            }
            if (try? await connection.read(key)) != nil {
                readable += 1
            } else {
                failed += 1
            }
        }

        #expect(readable + failed == count)
        #expect(readable > 0)
        // Observed on Mac16,5: 3 keyinfo failures + 52 declared-unreadable + 52
        // readable-but-erroring + 30 oversized = 137 of 3385 do not yield a value.
        // Assert the shape (some, but a small minority, fail) rather than the exact
        // count, which is a hardware fact recorded in docs/SMC-RESEARCH.md instead —
        // and which should hold on any Mac's key table, not just this one.
        #expect(failed < count / 10)
    }
}

/// Facts specific to this project's sole verified machine, `Mac16,5` (see
/// `docs/SMC-RESEARCH.md`): that fan 0 exists at all, and the exact keys behind its three
/// observed read-failure modes and its one observed oversized key.
///
/// `SMCConnection.isHardwareAvailable()` alone is true of every Mac — a fanless MacBook
/// Air has an `AppleSMC` IOService and no `F0Ac`/`F0Mn`/`F0Mx` at all — so gating these on
/// it alone would skip correctly on CI but genuinely fail on other real hardware. Gating
/// additionally on `isDevelopmentMachine()` means a contributor running this suite
/// elsewhere gets a skip, never a failure.
@Suite(
    "SMC connection, Mac16,5-specific facts",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct SMCConnectionMac165Tests {

    @Test("Fan bounds are present, non-zero, and ordered")
    func fanBoundsArePresentAndOrdered() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let min = try await connection.read(SMCKey.fanMinimumRPM(0)!)
        let max = try await connection.read(SMCKey.fanMaximumRPM(0)!)
        guard let minRPM = try min.scalar(), let maxRPM = try max.scalar() else {
            Issue.record("F0Mn / F0Mx did not decode to a scalar")
            return
        }

        // Hard rule: never allow 0 RPM to be representable or reachable. This is a
        // firmware-declared bound, not an observation — see actualBelowMinimumDoesNotThrow
        // below for why an *observed* reading is held to no such floor.
        #expect(minRPM > 0)
        #expect(maxRPM > minRPM)
    }

    /// `F0Ac` was observed reading below the declared `F0Mn` on `Mac16,5`
    /// (1343.07 < 1350). This does not assert that relationship — it would be a
    /// hardware fact, not a property of the code — it only asserts that a below-minimum
    /// actual reading is not itself treated as an error. Clamping governs targets, never
    /// observations.
    @Test("An actual RPM reading below the declared minimum is not itself an error")
    func actualBelowMinimumDoesNotThrow() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let actual = try await connection.read(SMCKey.fanActualRPM(0)!)
        let scalar = try actual.scalar()
        #expect(scalar != nil)
    }

    /// The three failure modes observed on `Mac16,5`. If a future macOS update removes
    /// one of these specific keys the test degrades to "key not present", which is
    /// itself informative rather than a false failure — see the `guard` below.
    @Test("READ_KEYINFO failing outright does not abort a single read")
    func keyInfoFailureIsSurfacedAsAnError() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        guard let key = SMCKey("BDFU") else { return }
        await #expect(throws: SMCError.self) {
            _ = try await connection.keyInfo(for: key)
        }
    }

    @Test("A key that declares itself unreadable throws notReadable")
    func declaredUnreadableKeyThrows() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        // rBK0 is one of the 52 keys observed to clear attribute bit 0x80.
        guard let key = SMCKey("rBK0") else { return }
        let info = try? await connection.keyInfo(for: key)
        guard let info, !info.isReadable else { return }

        await #expect(throws: SMCError.notReadable(key)) {
            _ = try await connection.read(key)
        }
    }

    @Test("A key that claims readable and errors anyway still throws, not crashes")
    func readableButErroringKeyThrows() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        // aP70 is one of the 52 keys observed to set the readable bit and still error
        // on READ_BYTES. If firmware behaviour differs here, the guard below no-ops
        // rather than failing on an assumption about a key this project does not own.
        guard let key = SMCKey("aP70") else { return }
        guard let info = try? await connection.keyInfo(for: key), info.isReadable else { return }

        await #expect(throws: SMCError.self) {
            _ = try await connection.read(key)
        }
    }

    @Test("A key with dataSize above 32 bytes is refused rather than truncated")
    func oversizedKeyRefusesRatherThanTruncates() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        // ATP0 was observed at 96 bytes on Mac16,5. Metadata must still be readable. As
        // with the failure-mode keys above, `keyInfo(for:)` is wrapped in `try?` so a
        // firmware update that removes or resizes this key degrades to a no-op rather
        // than an uncaught throw.
        guard let key = SMCKey("ATP0"), let info = try? await connection.keyInfo(for: key) else {
            return
        }
        guard info.dataSize > 32 else { return }

        let expected = SMCError.valueTooLargeForSingleRead(key: key, dataSize: info.dataSize)
        await #expect(throws: expected) {
            _ = try await connection.read(key)
        }
    }

    /// `open()` resolves the interface generation from the `AppleSMC` service's own
    /// IORegistry provenance (never `uname -m`) — see `smcGeneration(for:)`.
    /// Observed on `Mac16,5`: `IOProviderClass` is `"RTBuddyEndpointService"`, so this
    /// resolves `.modern`. A single-machine fact, hence gated here rather than in the
    /// broader hardware suite.
    @Test("open() resolves the interface generation as modern")
    func interfaceGenerationResolvesModern() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let generation = await connection.interfaceGeneration
        #expect(generation == .modern)
    }

    /// ADR 0003's runtime tripwire: `#KEY`'s own decoded value against an independent
    /// walk of the key table. A live pass here is direct evidence the resolver's
    /// hypothesis holds on this machine, right now, not just at the moment the bytes in
    /// `SMCByteOrderResolverTests` were captured.
    @Test("#KEY cross-check passes on live hardware")
    func keyCountCrossCheckPassesLive() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let result = try await connection.verifyKeyCountCrossCheck()
        #expect(result.matches)
        #expect(result.declaredCount > 1000)
    }

    /// The cell-sum identity, read live rather than from a fixed capture. `B0AV`,
    /// `BC1V`, `BC2V`, and `BC3V` are four separate IPC round trips, not one atomic
    /// snapshot, so a live pack under charge can drift a millivolt between them —
    /// observed on this machine. A tolerance of 50 mV absorbs that jitter while still
    /// failing hard if the byte order were actually wrong: a wrong order does not read a
    /// few mV off, it reads tens of thousands off (see `SMCByteOrderCapturedBytesTests`
    /// for the exact, non-fuzzy version of this same identity, pinned to fixed bytes).
    /// Skips rather than fails if any of the four keys is absent, since battery key sets
    /// vary even within this one model's configurations.
    @Test("Live cell-sum identity: B0AV ≈ BC1V + BC2V + BC3V")
    func liveCellSumIdentity() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        guard
            let b0av = SMCKey("B0AV"), let bc1v = SMCKey("BC1V"),
            let bc2v = SMCKey("BC2V"), let bc3v = SMCKey("BC3V"),
            let pack = try? await connection.read(b0av).scalar(),
            let cell1 = try? await connection.read(bc1v).scalar(),
            let cell2 = try? await connection.read(bc2v).scalar(),
            let cell3 = try? await connection.read(bc3v).scalar()
        else { return }

        #expect(abs(pack - (cell1 + cell2 + cell3)) < 50.0)
    }
}

// swiftlint:enable force_unwrapping
