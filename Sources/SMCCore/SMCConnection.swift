import Foundation
import IOKit
import os

/// A connection to the `AppleSMC` IOService.
///
/// ## Read and write are not peers
///
/// Reading is safe, unprivileged, and available to every client. Writing requires root,
/// can damage hardware, and is therefore reachable only from `AeolusHelper`: the write
/// entry points are `package`-scoped, not `public`. Widening that access is a change to
/// the project's safety posture and needs review under the rules in `docs/SAFETY.md` —
/// it is not a refactor.
///
/// ## `SMCKeyData_t` is read at explicit byte offsets, not as a Swift struct
///
/// Swift does not guarantee C struct layout. Rather than define a Swift type mirroring
/// the 80-byte kernel structure and hope the fields line up, every field is read from and
/// written to an explicit byte offset in a raw buffer. This is the approach a read-only
/// enumeration spike validated against `Mac16,5`, successfully enumerating all 3385 keys
/// the machine exposes; see `docs/SMC-RESEARCH.md`.
///
/// ```
///   0  key                     UInt32
///   4  vers / pLimitData       (unused by this project)
///  28  keyInfo.dataSize        UInt32
///  32  keyInfo.dataType        UInt32 (four-character code)
///  36  keyInfo.dataAttributes  UInt8  (bit 0x80 is "readable")
///  40  result                  UInt8  (SMC status code; 0 is success)
///  42  data8                   UInt8  (selector on the way in)
///  44  data32                  UInt32 (index, on `READ_INDEX`)
///  48  bytes[32]                      (payload, both directions)
/// ```
public actor SMCConnection {
    private var connection: io_connect_t = 0

    /// The SMC interface generation, resolved once by `open()` from the `AppleSMC`
    /// service's own IORegistry provenance. `nil` before `open()`, or if undetermined —
    /// see `smcGeneration(for:)`.
    private var generation: SMCInterfaceGeneration?

    // MARK: - Read cache
    //
    // A full enumeration is a one-time discovery cost, not a per-refresh one: a key's
    // four-character code, declared type, dataSize, and attribute byte do not change
    // while the machine is running, only the bytes behind them do. See `read(keys:)` and
    // `docs/ARCHITECTURE.md`.
    //
    // - Important: **Never a cache of values.** Only metadata lives here — `SMCKeyInfo`
    //   and the index → key mapping. Every `SMCValue` is read fresh, on every call, via
    //   `READ_BYTES`; nothing in this type ever hands back a value it did not just read.
    //   A cached *reading* served as though current is exactly the failure mode CLAUDE.md
    //   hard rule 6 exists to prevent — a UI showing a number nothing is currently
    //   honouring.
    //
    // - Note: Whether these attributes are actually stable across sleep/wake or a reboot
    //   is **unverified** on this project's one development machine. ADR 0004 already
    //   requires the write path to re-resolve byte order from a fresh `keyInfo(for:)` at
    //   write time rather than trust an earlier enumeration, for exactly this reason.
    //   This cache is a read-path performance optimisation only, and nothing in the write
    //   path may come to rely on it. `close()` deliberately leaves it populated (see its
    //   documentation); `invalidate()` is the explicit escape hatch for a caller who
    //   suspects staleness. Nothing currently calls `invalidate()` automatically — wiring
    //   it to a sleep/wake notification, if warranted, is a decision for whoever owns
    //   that lifecycle, not this cache.

    /// Per-key metadata: `dataType`, `dataSize`, and the attribute byte, keyed by
    /// `SMCKey`. Populated as each key is first looked up via `keyInfo(for:)` — most
    /// commonly by `SMCSensorProvider.readAll()`'s enumeration walk, but equally by an
    /// individual `read(_:)` or `read(keys:)` call that has never seen this key before.
    private var keyInfoCache: [SMCKey: SMCKeyInfo] = [:]

    /// The index → key table, populated as `key(at:)` resolves each index. Lets a
    /// repeated walk over the same index range skip `READ_INDEX` entirely.
    private var keyTableCache: [Int: SMCKey] = [:]

    /// The complete key set this machine is known to expose, recorded once a full
    /// enumeration walk has finished — see `markDiscoveryComplete(_:)`, called by
    /// `SMCSensorProvider.readAll()`. `nil` until that has happened at least once.
    ///
    /// Used only so `read(keys:)` can report a key this machine provably does not have
    /// without spending a round trip on it — see that method. A subset read never
    /// requires this to be populated; before any full enumeration, an unrecognised key is
    /// simply attempted like any other.
    private var knownKeys: Set<SMCKey>?

    /// Counts each `READ_KEYINFO` attempt actually issued — cache misses only, since a
    /// cache hit in `keyInfo(for:)` never reaches `call(key:selector:data32:dataSize:)`
    /// at all. Not `private`, so `@testable import SMCCore` can prove the cache actually
    /// skips the round trip it claims to, without needing an open hardware connection to
    /// observe it — see `SMCConnectionCacheTests`. Not `public`: no real caller has a
    /// legitimate reason to read call-count telemetry through the public API.
    private(set) var readKeyInfoAttempts = 0

    /// Counts each `READ_INDEX` attempt actually issued — cache misses only. Same
    /// rationale as `readKeyInfoAttempts`.
    private(set) var readIndexAttempts = 0

    private static let logger = Logger(subsystem: "dev.aeolus.SMCCore", category: "SMCConnection")

    // MARK: - Wire format

    /// `SMCKeyData_t` is 80 bytes; see the struct layout note above.
    private static let structSize = 80
    private static let offsetKey = 0
    private static let offsetDataSize = 28
    private static let offsetDataType = 32
    private static let offsetAttributes = 36
    private static let offsetResult = 40
    private static let offsetData8 = 42
    private static let offsetData32 = 44
    private static let offsetBytes = 48

    /// The `bytes[32]` payload field. Any key whose declared `dataSize` exceeds this
    /// cannot be read through a single `READ_BYTES` call — see `read(_:)`.
    private static let maxPayloadBytes = 32

    // Read-only selectors. No write selector is defined here: this project's write path
    // is entirely out of scope for E1 and lives behind `write(_:to:)` below, unimplemented.
    private static let selectorReadBytes: UInt8 = 5
    private static let selectorReadIndex: UInt8 = 8
    private static let selectorReadKeyInfo: UInt8 = 9
    private static let kernelIndexSMC: UInt32 = 2

    public init() {}

    deinit {
        guard connection != 0 else { return }
        IOServiceClose(connection)
    }

    // MARK: - Lifecycle

    /// Opens the connection. Idempotent: calling this again while already open is a
    /// harmless no-op rather than a second `IOServiceOpen`.
    ///
    /// Also resolves `interfaceGeneration` from the matched service's own IORegistry
    /// provenance — see `smcGeneration(for:)`. Resolution happens before `IOServiceOpen`
    /// runs (the service is only available to inspect while this function still holds it),
    /// but `generation` and `connection` are only ever assigned together, after
    /// `IOServiceOpen` actually succeeds: a failed open must leave both `connection == 0`
    /// and `interfaceGeneration == nil`, never a non-`nil` generation paired with no open
    /// connection. See `interfaceGeneration`.
    public func open() throws {
        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCError.connectionFailed(kernReturn: kIOReturnNotFound)
        }
        defer { IOObjectRelease(service) }

        let resolvedGeneration = Self.smcGeneration(for: service)

        var newConnection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &newConnection)
        guard openResult == kIOReturnSuccess else {
            throw SMCError.connectionFailed(kernReturn: openResult)
        }

        connection = newConnection
        generation = resolvedGeneration
    }

    /// The SMC interface generation resolved by `open()`. Plain-integer keys decode only
    /// when this is non-`nil` — see `SMCValue.scalar()`.
    ///
    /// Consistent by construction with whether the connection is actually open: `nil`
    /// before the first successful `open()`, after a failed `open()`, and after `close()`;
    /// non-`nil` only once `open()` has actually succeeded. Never inspect this to infer
    /// that the connection is open — use it only after `open()` has not thrown.
    public var interfaceGeneration: SMCInterfaceGeneration? { generation }

    /// Detects which SMC firmware interface `service` is, from the service's own
    /// IORegistry provenance — **never** from `uname -m`/`utsname`, which report the
    /// running process's architecture, not the firmware, and lie outright under Rosetta.
    /// See ADR 0003, ADR 0004, and `resolveByteOrder(generation:attributes:type:)`.
    ///
    /// Observed on `Mac16,5`: `IOProviderClass` is `"RTBuddyEndpointService"` — the modern
    /// SMC is reached over the always-on coprocessor's RTKit mailbox, not a direct ACPI
    /// device. A single-machine observation, kept only for the `.modern` branch below. The
    /// `.legacy` branch (`IOProviderClass` containing `"ACPI"`) is not observed on any
    /// hardware available to this project; it follows documented, corroborated community
    /// sources (VirtualSMC and others) and ships `untested` until an Intel report confirms
    /// it, same as the rest of the Intel path.
    ///
    /// Returns `nil` — undetectable — if the property is absent or matches neither branch,
    /// rather than guessing. Every caller must treat `nil` as "do not resolve plain-integer
    /// byte order for this connection" (ADR 0003's fail-safe).
    private static func smcGeneration(for service: io_service_t) -> SMCInterfaceGeneration? {
        guard
            let providerClass = IORegistryEntryCreateCFProperty(
                service, "IOProviderClass" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
        else {
            logger.error(
                """
                AppleSMC has no readable IOProviderClass; the SMC interface generation is \
                undetectable for this connection. Plain-integer keys will surface raw \
                bytes only — see docs/ADR/0003-integer-byte-order.md.
                """
            )
            return nil
        }

        if providerClass.contains("RTBuddy") {
            return .modern
        }
        if providerClass.contains("ACPI") {
            return .legacy
        }

        logger.error(
            """
            AppleSMC's IOProviderClass '\(providerClass, privacy: .public)' does not match \
            a recognised SMC interface generation. Plain-integer keys will surface raw \
            bytes only — see docs/ADR/0003-integer-byte-order.md.
            """
        )
        return nil
    }

    /// Closes the connection. Safe to call when already closed, and safe to `open()`
    /// again afterwards.
    ///
    /// Clears `interfaceGeneration` along with `connection`, so the two stay consistent —
    /// see `interfaceGeneration` — and a subsequent `open()` re-resolves the generation
    /// rather than trusting a value captured by a now-closed connection.
    ///
    /// - Important: Deliberately does **not** clear the read cache
    ///   (`keyInfoCache`/`keyTableCache`/`knownKeys`). The cache is firmware-static
    ///   metadata, not connection state — a `close()`/`open()` cycle means the IOKit
    ///   handle was recycled, not that the machine's key table changed underneath it.
    ///   Clearing here would cost a full rediscovery (~4.5 s on `Mac16,5`) on every
    ///   reopen for no established benefit; the alternative that does clear it is
    ///   `invalidate()`, kept separate and explicit so a caller who actually suspects
    ///   staleness (a wake from sleep, say — unverified either way, see the read-cache
    ///   note above `keyInfoCache`) can ask for it deliberately rather than paying the
    ///   cost on every ordinary reconnect.
    public func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
        generation = nil
    }

    /// Whether the `AppleSMC` IOService is present on this machine at all. Cheap,
    /// synchronous, and opens no connection — used to skip hardware-dependent tests
    /// cleanly on CI, where GitHub's macOS runners have no SMC, rather than failing them.
    public static func isHardwareAvailable() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    // MARK: - Read path (public)

    /// The largest `#KEY` decode this project will trust as a genuine firmware value,
    /// rather than a byte-order decode fault.
    ///
    /// `Mac16,5` reports 3385. No hardware report this project has seen — its own dump or
    /// any community source cited in `docs/SMC-RESEARCH.md` — describes an SMC key table
    /// within even one order of magnitude of six figures; the most densely instrumented
    /// Macs documented anywhere are in the low thousands. 100,000 is roughly 30x
    /// `Mac16,5`'s own count: generous headroom for a Mac with meaningfully more sensors
    /// than any observed so far, while sitting almost four orders of magnitude below the
    /// one byte-swap artefact this project has actually measured — `#KEY`'s own raw bytes
    /// (`00000d39`) decode to 957,153,280 read little-endian instead of the correct
    /// big-endian 3385 (see ADR 0003). This ceiling only has to separate "any plausible
    /// key table" from "a byte order got flipped"; it does not need to be tight, and
    /// picking it wide keeps a legitimately larger future Mac from tripping it.
    static let maxPlausibleKeyCount = 100_000

    /// Sanity-bounds a decoded `#KEY` value before it is trusted to size an allocation or
    /// bound a loop — the fix for the scenario `SMCError.implausibleKeyCount` documents.
    ///
    /// Pure and synchronous, deliberately not private, so the exact failure value ADR 0003
    /// records (957,153,280, `#KEY` misdecoded little-endian on `Mac16,5`) is directly
    /// unit-testable via `@testable import SMCCore` without hardware — see
    /// `SMCConnectionKeyCountPlausibilityTests`.
    static func validatePlausibleKeyCount(_ count: Int) throws -> Int {
        guard count >= 0, count <= maxPlausibleKeyCount else {
            logger.fault(
                """
                #KEY decoded to \(count, privacy: .public), outside the plausible range \
                0...\(maxPlausibleKeyCount, privacy: .public). Refusing to use it to size \
                an allocation or bound an enumeration — this is ADR 0003's byte-order \
                tripwire firing on a decode fault, not a real key count. See \
                docs/ADR/0003-integer-byte-order.md.
                """
            )
            throw SMCError.implausibleKeyCount(declared: count)
        }
        return count
    }

    /// The number of keys this machine exposes, read from `#KEY`.
    ///
    /// `#KEY` declares `ui32` with attribute bit `0x04` clear, so
    /// `resolveByteOrder(generation:attributes:type:)` predicts big-endian — exactly what
    /// `#KEY` needs, with no special-casing, whenever the interface generation is known.
    /// See `verifyKeyCountCrossCheck()` for the tripwire that checks this decode against an
    /// independent walk of the table.
    ///
    /// - Important: When the generation is **not** known, `value.scalar()` correctly
    ///   returns `nil` per ADR 0003's fail-safe — `SMCValue` itself never guesses. But
    ///   `#KEY` is not an ordinary plain integer: without a key count, nothing can be
    ///   enumerated, `#KEY` included, so declining here would silently take out every
    ///   sensor reading on a machine with an undetectable generation, not just the
    ///   display-grade integers the fail-safe is scoped to (`docs/ARCHITECTURE.md` and
    ///   ADR 0003 both promise the control path is unaffected). This method therefore
    ///   falls back to `decodeKeyCountFallback(bytes:)` for `#KEY` specifically, in this
    ///   enumeration layer rather than through the resolver — ADR 0003's own designated
    ///   fallback shape. See that function's documentation for the justification and for
    ///   why `verifyKeyCountCrossCheck()` still catches a wrong guess.
    ///
    /// The decoded value — resolved or guessed — is sanity-bounded by
    /// `validatePlausibleKeyCount(_:)` before it is returned: every caller of this method —
    /// `SMCSensorProvider.readAll()` and `verifyKeyCountCrossCheck()` both allocate and
    /// iterate on this value — inherits the bound automatically rather than needing to
    /// apply it themselves.
    public func keyCount() throws -> Int {
        let value = try read(SMCKey.keyCount)

        let decoded: Int
        if let scalar = try value.scalar() {
            decoded = Int(scalar)
        } else if generation == nil, let fallback = Self.decodeKeyCountFallback(value: value) {
            decoded = fallback
        } else {
            throw SMCError.integerByteOrderUndetectable(key: SMCKey.keyCount)
        }

        return try Self.validatePlausibleKeyCount(decoded)
    }

    /// Decodes `#KEY` directly as big-endian, bypassing
    /// `resolveByteOrder(generation:attributes:type:)` and `SMCValue.scalar()` entirely,
    /// for the one case both of those correctly refuse:
    /// the SMC interface generation could not be determined for this connection.
    ///
    /// This is ADR 0003's own designated fallback shape for exactly this situation —
    /// "`#KEY` handled by the enumeration layer instead of this rule" — because without a
    /// key count `SMCSensorProvider.readAll()` cannot enumerate a single reading, control
    /// path included, which is a stronger failure than the fail-safe is meant to cause.
    ///
    /// Justification for guessing big-endian specifically here, when every other plain
    /// integer correctly declines rather than guess:
    /// - Unconditionally correct on `.legacy` (Intel), where all plain integers are
    ///   big-endian regardless of the attribute byte — so this guess is right by
    ///   construction on one of the two generations this project models.
    /// - Correct on the only `.modern` case this project has observed: `#KEY` on
    ///   `Mac16,5` carries attribute bit `0x04` clear (128), which
    ///   `resolveByteOrder(generation:attributes:type:)` already resolves to big-endian
    ///   when the generation *is* known — see `SMCByteOrderCapturedBytesTests`.
    /// - The Asahi Linux SMC documentation names `#KEY` explicitly as one of the
    ///   byte-reversed quirk keys on Apple Silicon, independent of and prior to this
    ///   project's own attribute-bit hypothesis.
    ///
    /// This is a guess, not a resolved fact, and is not treated as one:
    /// `verifyKeyCountCrossCheck()` independently validates whatever `keyCount()` returns —
    /// resolved or guessed — against an actual walk of the key table. If `#KEY` were ever
    /// little-endian on some future machine with an undetectable generation, the walk would
    /// not reach the guessed count and the tripwire fires loudly, exactly as it would for a
    /// wrong resolver decode. See issue #35 for the open question of whether attribute bit
    /// `0x04` governs byte order beyond the plain integers this resolver actually covers.
    ///
    /// Scoped to `#KEY` only — `value.key` and `value.type` are checked so a caller cannot
    /// accidentally widen this into a general "guess big-endian" escape hatch for other
    /// plain integers, which must keep declining per the fail-safe. Returns `nil` if either
    /// check fails, or if `bytes` is not the 4 bytes a `ui32` should be (defensive; not
    /// expected, since `SMCValue.scalar()` already validates width before this is reached).
    static func decodeKeyCountFallback(value: SMCValue) -> Int? {
        guard value.key == SMCKey.keyCount, value.type == .ui32, value.bytes.count == 4 else {
            return nil
        }
        let bytes = value.bytes
        let bits =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        return Int(bits)
    }

    /// Returns the key at `index` in the SMC's key table. Used to enumerate every key on
    /// the machine without a hard-coded list.
    ///
    /// Consults `keyTableCache` first: the index → key mapping is firmware-static (see
    /// the read cache note above), so once an index has been resolved once — typically
    /// by a prior `readAll()` walk — a repeated lookup at the same index is a dictionary
    /// read, not a second `READ_INDEX` round trip.
    public func key(at index: Int) throws -> SMCKey {
        if let cached = keyTableCache[index] {
            return cached
        }
        guard let index32 = UInt32(exactly: index) else {
            throw SMCError.invalidIndex(index)
        }
        readIndexAttempts += 1
        let reply = try call(key: 0, selector: Self.selectorReadIndex, data32: index32)
        guard let key = SMCKey(fourCharCode: reply.key) else {
            throw SMCError.malformedKeyCode(reply.key)
        }
        keyTableCache[index] = key
        return key
    }

    /// Reads a key's declared type, size, and attribute byte without attempting to read
    /// its value. Always available, even for keys `read(_:)` refuses — an unreadable key
    /// or one whose `dataSize` exceeds 32 bytes still has metadata worth showing.
    ///
    /// Consults `keyInfoCache` first: this metadata is firmware-static for the life of
    /// the machine (see the read cache note above `keyInfoCache`), so once a key's
    /// metadata has been read once — by a prior `readAll()`, a prior `read(_:)`, or a
    /// prior `keyInfo(for:)` call on this same connection — every later lookup for that
    /// key is a dictionary read, not a second `READ_KEYINFO` round trip. This is what
    /// lets `read(_:)` and `read(keys:)` cost one round trip instead of two once a key is
    /// warm.
    public func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] {
            return cached
        }
        readKeyInfoAttempts += 1
        let reply = try call(key: key.fourCharCode, selector: Self.selectorReadKeyInfo)
        let info = SMCKeyInfo(
            key: key,
            type: SMCKeyType(fourCharCode: reply.dataType),
            dataSize: Int(reply.dataSize),
            attributes: reply.attributes
        )
        keyInfoCache[key] = info
        return info
    }

    /// Reads a key's declared type and current bytes.
    ///
    /// Three failure modes are distinct and all are observed on real hardware (see
    /// `docs/SMC-RESEARCH.md`):
    ///
    /// 1. `READ_KEYINFO` itself fails — propagates as `SMCError.firmware`.
    /// 2. The key declares itself unreadable (attribute bit `0x80` clear) —
    ///    `SMCError.notReadable`.
    /// 3. The key claims readable and `READ_BYTES` errors anyway — the readable bit is
    ///    necessary, not sufficient — propagates as `SMCError.firmware`.
    ///
    /// A `dataSize` above the 32-byte payload throws `SMCError.valueTooLargeForSingleRead`
    /// rather than silently truncating: see the type's documentation for why.
    ///
    /// The returned value's `byteOrder` comes from `interfaceGeneration`, the key's
    /// attribute byte, and its declared type, via
    /// `resolveByteOrder(generation:attributes:type:)` — `nil` when the generation is
    /// undetermined, which in turn makes `scalar()` return `nil` for the plain-integer and
    /// `flt`/`ioft` keys that consume it (see ADR 0003 and ADR 0004).
    public func read(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(for: key)

        guard info.isReadable else {
            throw SMCError.notReadable(key)
        }
        guard info.dataSize <= Self.maxPayloadBytes else {
            throw SMCError.valueTooLargeForSingleRead(key: key, dataSize: info.dataSize)
        }

        let byteOrder = generation.map {
            resolveByteOrder(generation: $0, attributes: info.attributes, type: info.type)
        }

        guard info.dataSize > 0 else {
            return SMCValue(key: key, type: info.type, bytes: [], byteOrder: byteOrder)
        }

        let reply = try call(
            key: key.fourCharCode,
            selector: Self.selectorReadBytes,
            dataSize: UInt32(info.dataSize))

        // A short read is an error, never a silently truncated value. `bytes` is sized
        // from what this call requested (already validated against the 32-byte payload
        // above), not from the response's own `dataSize` field — observed on `Mac16,5`
        // to read back as 0 on a `READ_BYTES` reply even on success. Only `READ_KEYINFO`
        // populates that field reliably; see `call(key:selector:data32:dataSize:)`.
        guard reply.bytes.count == info.dataSize else {
            throw SMCError.sizeMismatch(
                key: key, declared: info.type, reportedBytes: reply.bytes.count)
        }

        return SMCValue(key: key, type: info.type, bytes: reply.bytes, byteOrder: byteOrder)
    }

    /// A free runtime tripwire on `resolveByteOrder(generation:attributes:type:)`'s central
    /// hypothesis (ADR 0003): `#KEY`'s own decoded value should exactly equal the number of
    /// indices this connection can actually retrieve by walking the key table from 0. `#KEY`
    /// is decoded by the very resolver this checks, so a wrong rule is likely to show up
    /// here as a loud, logged mismatch rather than a silently wrong reading downstream.
    ///
    /// - Important: `declaredCount` comes from `keyCount()`, which refuses — via
    ///   `validatePlausibleKeyCount(_:)` — to hand back a value outside
    ///   `maxPlausibleKeyCount`. That refusal *is* this tripwire firing: it throws
    ///   `SMCError.implausibleKeyCount` instead of entering a walk bounded by a decode
    ///   fault, which is a stronger, more specific signal than letting the walk run and
    ///   reporting a `KeyCountCrossCheck` whose `matches` happens to be `false` — and it is
    ///   what stops a misdecoded `#KEY` (957,153,280 on `Mac16,5`, decoded little-endian
    ///   instead of the correct big-endian 3385) from turning this check into the
    ///   ~957-million-iteration walk it exists to catch before it can complete.
    ///
    /// Intended to run once, near startup. `SMCSensorProvider.readAll()` performs the same
    /// comparison from the walk it already does for enumeration, at no extra cost; this
    /// method is the standalone, independently testable version of that check.
    ///
    /// - Note: The walk bounded by `0..<declaredCount` is one-sided — it can only detect a
    ///   declared count that is too *large* (some index inside the bound fails). A count
    ///   that is too *small* would walk exactly that many indices, all succeed, and report
    ///   a spurious match while a real key sits just past where the walk stopped looking.
    ///   This method additionally probes index `declaredCount` itself and expects it to
    ///   fail; `KeyCountCrossCheck.keyExistsPastDeclaredCount` carries the result, and
    ///   `matches` folds it in, making the tripwire two-sided.
    public func verifyKeyCountCrossCheck() throws -> KeyCountCrossCheck {
        let declaredCount = try keyCount()

        var walkedCount = 0
        for index in 0..<declaredCount where (try? key(at: index)) != nil {
            walkedCount += 1
        }
        let keyExistsPastDeclaredCount = (try? key(at: declaredCount)) != nil

        let result = KeyCountCrossCheck(
            declaredCount: declaredCount, walkedCount: walkedCount,
            keyExistsPastDeclaredCount: keyExistsPastDeclaredCount)
        Self.logCrossCheck(result)
        return result
    }

    /// Logs loudly when a `KeyCountCrossCheck` disagrees; silent when it matches. Shared
    /// by `verifyKeyCountCrossCheck()` and `SMCSensorProvider.readAll()`, which computes
    /// the same comparison from a walk it is already doing rather than repeating it.
    static func logCrossCheck(_ result: KeyCountCrossCheck) {
        guard !result.matches else { return }
        logger.fault(
            """
            #KEY cross-check failed: the firmware declares \
            \(result.declaredCount, privacy: .public) keys, \
            \(result.walkedCount, privacy: .public) were walkable in that range, and a key \
            past the declared bound \
            \(result.keyExistsPastDeclaredCount ? "exists" : "does not exist", privacy: .public). \
            This is the tripwire on ADR 0003's byte-order hypothesis — see \
            docs/ADR/0003-integer-byte-order.md.
            """
        )
    }

    // MARK: - Write path (helper-only)

    /// Writes raw bytes to a key.
    ///
    /// - Important: Requires root. Every caller must be inside `AeolusHelper`, and every
    ///   fan-speed write must already have been clamped to the firmware's own
    ///   `[F0Mn, F0Mx]` bounds and rate-limited. See E5.
    package func write(_ bytes: [UInt8], to key: SMCKey) throws {
        throw SMCError.notPermitted
    }

    // MARK: - Wire-level call

    /// One `IOConnectCallStructMethod` round trip. Every field of the response the rest
    /// of this type needs is decoded here and copied out as plain Swift values — no raw
    /// pointer escapes this function.
    ///
    /// - Note: The response's `keyInfo.dataSize` field (offset 28) is only reliable on a
    ///   `READ_KEYINFO` reply. Observed on `Mac16,5`: a `READ_BYTES` reply reports that
    ///   field as 0 even on success, matching the enumeration spike, which reads the
    ///   payload using the *requested* `dataSize` rather than the response's. The payload
    ///   here is sized the same way, from what every caller already knows from a prior
    ///   `READ_KEYINFO`, not from the response.
    private func call(
        key: FourCharCode, selector: UInt8, data32: UInt32 = 0, dataSize: UInt32 = 0
    ) throws -> RawSMCReply {
        guard connection != 0 else {
            throw SMCError.connectionFailed(kernReturn: kIOReturnNotOpen)
        }

        let input = UnsafeMutableRawPointer.allocate(byteCount: Self.structSize, alignment: 8)
        defer { input.deallocate() }
        input.initializeMemory(as: UInt8.self, repeating: 0, count: Self.structSize)
        input.storeBytes(of: key, toByteOffset: Self.offsetKey, as: UInt32.self)
        input.storeBytes(of: selector, toByteOffset: Self.offsetData8, as: UInt8.self)
        input.storeBytes(of: data32, toByteOffset: Self.offsetData32, as: UInt32.self)
        input.storeBytes(of: dataSize, toByteOffset: Self.offsetDataSize, as: UInt32.self)

        let output = UnsafeMutableRawPointer.allocate(byteCount: Self.structSize, alignment: 8)
        defer { output.deallocate() }
        output.initializeMemory(as: UInt8.self, repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize

        let kernResult = IOConnectCallStructMethod(
            connection, Self.kernelIndexSMC, input, Self.structSize, output, &outputSize)
        guard kernResult == kIOReturnSuccess else {
            throw SMCError.connectionFailed(kernReturn: kernResult)
        }

        // The reply is decoded from fixed byte offsets into a zero-initialised buffer, so
        // a short write by the kernel does not fail loudly — it decodes as zeros, and a
        // zeroed `result` byte reads as *success*. A truncated `READ_BYTES` reply would
        // therefore become a legitimate-looking all-zero value: 0 RPM, 0 °C. That is the
        // fabricated data this project refuses to produce, so the reply length is checked
        // before any field is read. `IOConnectCallStructMethod` reports what it actually
        // wrote in `outputSize`; nothing else in this function can detect the shortfall.
        guard outputSize == Self.structSize else {
            throw SMCError.truncatedReply(expected: Self.structSize, received: outputSize)
        }

        let resultByte = output.load(fromByteOffset: Self.offsetResult, as: UInt8.self)
        let outKey = output.load(fromByteOffset: Self.offsetKey, as: UInt32.self)
        // Meaningful on a READ_KEYINFO reply; see the note above on why it is not used
        // to size the payload below.
        let outDataSize = output.load(fromByteOffset: Self.offsetDataSize, as: UInt32.self)
        let outDataType = output.load(fromByteOffset: Self.offsetDataType, as: UInt32.self)
        let outAttributes = output.load(fromByteOffset: Self.offsetAttributes, as: UInt8.self)

        let payloadCount = min(Int(dataSize), Self.maxPayloadBytes)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payloadCount)
        for offset in 0..<payloadCount {
            bytes.append(output.load(fromByteOffset: Self.offsetBytes + offset, as: UInt8.self))
        }

        guard resultByte == 0 else {
            throw SMCError.firmware(code: resultByte)
        }

        return RawSMCReply(
            key: outKey, dataSize: outDataSize, dataType: outDataType, attributes: outAttributes,
            bytes: bytes)
    }
}

// MARK: - Subset reads and cache management
//
// Split into its own extension, separate from the actor's primary declaration above,
// purely for file organisation — actor isolation applies identically to members declared
// in an extension, so every method here runs on the same actor as `read(_:)`,
// `keyInfo(for:)`, and `key(at:)` above.
extension SMCConnection {
    /// Reads a subset of keys directly, without enumerating the full key table — the
    /// whole point of this method next to `readAll()`. `keyInfo(for:)` and `READ_BYTES`
    /// both address a key by its four-character code, so nothing here ever walks the
    /// index: a cold cache costs at most `READ_KEYINFO` + `READ_BYTES` (2 round trips)
    /// per key, and a warm one — a key `readAll()` or a prior `read(_:)`/`read(keys:)`
    /// has already seen — costs exactly 1.
    ///
    /// Returns one `SMCKeyReadOutcome` per requested key, in the order requested,
    /// including duplicates if `keys` has any. Never a filtered array: a caller asking
    /// for 40 keys and getting 3 failures can tell which 3 failed, rather than silently
    /// receiving 37 successes and having to infer the rest — collapsing that distinction
    /// is exactly the "renders a shorter list as though it were the whole answer"
    /// mistake this exists to avoid.
    ///
    /// A key this machine is *known* not to expose — because a prior `readAll()` walk
    /// completed and did not see it, recorded via `markDiscoveryComplete(_:)` — reports
    /// `.keyNotFound` at zero round trips. Before any full enumeration has completed,
    /// `knownKeys` is `nil` and an unrecognised key is simply attempted like any other:
    /// this method never guesses that a failure means "does not exist" when the honest
    /// answer is "was never asked" — it reports whatever `SMCError` firmware actually
    /// produced instead.
    public func read(keys: [SMCKey]) -> [SMCKeyReadOutcome] {
        keys.map(readOutcome(for:))
    }

    /// One key's outcome from `read(keys:)`, split out purely for readability.
    private func readOutcome(for key: SMCKey) -> SMCKeyReadOutcome {
        if let knownKeys, !knownKeys.contains(key) {
            return SMCKeyReadOutcome(key: key, result: .failure(.keyNotFound(key)))
        }
        do {
            return SMCKeyReadOutcome(key: key, result: .success(try read(key)))
        } catch {
            // Every throw site reachable from read(_:) — keyInfo(for:), the READ_BYTES
            // call, and read(_:) itself — is SMCError; see SMCError.swift. This is not
            // a real fallback path, only a way to make that invariant loud rather than
            // silently coercing an unexpected error into a fabricated SMCError case.
            guard let smcError = error as? SMCError else {
                preconditionFailure(
                    "SMCConnection.read(_:) threw a non-SMCError for \(key): \(error)")
            }
            return SMCKeyReadOutcome(key: key, result: .failure(smcError))
        }
    }

    /// Clears the metadata and index caches, forcing the next `keyInfo(for:)`,
    /// `key(at:)`, `read(_:)`, or `read(keys:)` to rediscover from firmware rather than
    /// trust anything seen before this call — including the "does this machine expose
    /// this key at all" answer `read(keys:)` otherwise gets to skip.
    ///
    /// Does not touch the underlying IOKit connection — see `close()`, which
    /// deliberately does the opposite (closes the connection, leaves the cache alone)
    /// for the reasoning captured there. Call this, not `close()`/`open()`, when the
    /// cache itself — not the connection — is what is suspected stale.
    public func invalidate() {
        keyInfoCache.removeAll()
        keyTableCache.removeAll()
        knownKeys = nil
    }

    /// Records `keys` as the complete key set this machine is known to expose, once a
    /// full enumeration walk has finished. Called by `SMCSensorProvider.readAll()` after
    /// its walk completes, from the same keys it already collected — this never issues a
    /// round trip of its own.
    ///
    /// Internal rather than `public`: `readAll()`'s full walk over `0..<keyCount()` is
    /// the only pass this project performs that can honestly claim to have seen "every
    /// key," so recording is scoped to that caller rather than opened up to arbitrary
    /// partial sets, which would let `read(keys:)` report a false `.keyNotFound` for a
    /// key that exists but simply was not part of whatever was recorded. Visible to
    /// `SensorProvider.swift` within this module, and directly unit-testable via
    /// `@testable import SMCCore`.
    func markDiscoveryComplete(_ keys: Set<SMCKey>) {
        knownKeys = keys
    }

    // MARK: - Test-only cache seams
    //
    // Neither of these issues a round trip; both exist purely so cache-hit behaviour is
    // directly assertable via @testable import without an open hardware connection — see
    // SMCConnectionCacheTests. Not private (so @testable import can reach them), not
    // public (no real caller has a legitimate reason to seed the cache with data it did
    // not itself read from firmware).

    /// Seeds `keyInfoCache` directly, as if `keyInfo(for:)` had already read it once.
    func seedKeyInfoCacheForTesting(_ info: SMCKeyInfo) {
        keyInfoCache[info.key] = info
    }

    /// Seeds `keyTableCache` directly, as if `key(at:)` had already resolved `index`.
    func seedKeyTableCacheForTesting(index: Int, key: SMCKey) {
        keyTableCache[index] = key
    }
}

/// One decoded `IOConnectCallStructMethod` reply. Internal: callers see `SMCKeyInfo` and
/// `SMCValue`, never this.
private struct RawSMCReply {
    let key: FourCharCode
    let dataSize: UInt32
    let dataType: FourCharCode
    let attributes: UInt8
    let bytes: [UInt8]
}

/// One key's outcome from `SMCConnection.read(keys:)`.
///
/// Deliberately not a filtered array of successes: see that method's documentation for
/// why a caller must be able to tell a key that failed apart from one silently omitted.
/// `result`'s failure case is `SMCError`, not `any Error` — every throw site reachable
/// from `read(_:)` is already `SMCError` (see `SMCError.swift`), so this stays strongly
/// typed rather than erasing that back to `any Error` for no benefit.
public struct SMCKeyReadOutcome: Sendable, Equatable {
    public let key: SMCKey
    public let result: Result<SMCValue, SMCError>

    public init(key: SMCKey, result: Result<SMCValue, SMCError>) {
        self.key = key
        self.result = result
    }
}
