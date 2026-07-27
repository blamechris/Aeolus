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
    /// provenance, once, before the connection is opened — see `smcGeneration(for:)`.
    public func open() throws {
        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCError.connectionFailed(kernReturn: kIOReturnNotFound)
        }
        defer { IOObjectRelease(service) }

        generation = Self.smcGeneration(for: service)

        var newConnection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &newConnection)
        guard openResult == kIOReturnSuccess else {
            throw SMCError.connectionFailed(kernReturn: openResult)
        }

        connection = newConnection
    }

    /// The SMC interface generation resolved by `open()`. Plain-integer keys decode only
    /// when this is non-`nil` — see `SMCValue.scalar()`.
    public var interfaceGeneration: SMCInterfaceGeneration? { generation }

    /// Detects which SMC firmware interface `service` is, from the service's own
    /// IORegistry provenance — **never** from `uname -m`/`utsname`, which report the
    /// running process's architecture, not the firmware, and lie outright under Rosetta.
    /// See ADR 0003 and `resolveByteOrder(generation:attributes:)`.
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
    public func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
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

    /// The number of keys this machine exposes, read from `#KEY`.
    ///
    /// `#KEY` declares `ui32` with attribute bit `0x04` clear, so
    /// `resolveByteOrder(generation:attributes:)` predicts big-endian — exactly what
    /// `#KEY` needs, with no special-casing. See `verifyKeyCountCrossCheck()` for the
    /// tripwire that checks this decode against an independent walk of the table.
    public func keyCount() throws -> Int {
        let value = try read(SMCKey.keyCount)
        guard let scalar = try value.scalar() else {
            throw SMCError.integerByteOrderUndetectable(key: SMCKey.keyCount)
        }
        return Int(scalar)
    }

    /// Returns the key at `index` in the SMC's key table. Used to enumerate every key on
    /// the machine without a hard-coded list.
    public func key(at index: Int) throws -> SMCKey {
        guard let index32 = UInt32(exactly: index) else {
            throw SMCError.invalidIndex(index)
        }
        let reply = try call(key: 0, selector: Self.selectorReadIndex, data32: index32)
        guard let key = SMCKey(fourCharCode: reply.key) else {
            throw SMCError.malformedKeyCode(reply.key)
        }
        return key
    }

    /// Reads a key's declared type, size, and attribute byte without attempting to read
    /// its value. Always available, even for keys `read(_:)` refuses — an unreadable key
    /// or one whose `dataSize` exceeds 32 bytes still has metadata worth showing.
    public func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        let reply = try call(key: key.fourCharCode, selector: Self.selectorReadKeyInfo)
        return SMCKeyInfo(
            key: key,
            type: SMCKeyType(fourCharCode: reply.dataType),
            dataSize: Int(reply.dataSize),
            attributes: reply.attributes
        )
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
    /// The returned value's `integerByteOrder` comes from `interfaceGeneration` and the
    /// key's attribute byte, via `resolveByteOrder(generation:attributes:)` — `nil`, and
    /// plain-integer keys `nil` from `scalar()`, when the generation is undetermined.
    public func read(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(for: key)

        guard info.isReadable else {
            throw SMCError.notReadable(key)
        }
        guard info.dataSize <= Self.maxPayloadBytes else {
            throw SMCError.valueTooLargeForSingleRead(key: key, dataSize: info.dataSize)
        }

        let integerByteOrder = generation.map {
            resolveByteOrder(generation: $0, attributes: info.attributes)
        }

        guard info.dataSize > 0 else {
            return SMCValue(
                key: key, type: info.type, bytes: [], integerByteOrder: integerByteOrder)
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

        return SMCValue(
            key: key, type: info.type, bytes: reply.bytes, integerByteOrder: integerByteOrder)
    }

    /// A free runtime tripwire on `resolveByteOrder(generation:attributes:)`'s central
    /// hypothesis (ADR 0003): `#KEY`'s own decoded value should exactly equal the number of
    /// indices this connection can actually retrieve by walking the key table from 0. `#KEY`
    /// is decoded by the very resolver this checks, so a wrong rule is likely to show up
    /// here as a loud, logged mismatch rather than a silently wrong reading downstream.
    ///
    /// Intended to run once, near startup. `SMCSensorProvider.readAll()` performs the same
    /// comparison from the walk it already does for enumeration, at no extra cost; this
    /// method is the standalone, independently testable version of that check.
    public func verifyKeyCountCrossCheck() throws -> KeyCountCrossCheck {
        let declaredCount = try keyCount()

        var walkedCount = 0
        for index in 0..<declaredCount where (try? key(at: index)) != nil {
            walkedCount += 1
        }

        let result = KeyCountCrossCheck(declaredCount: declaredCount, walkedCount: walkedCount)
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
            \(result.declaredCount, privacy: .public) keys but only \
            \(result.walkedCount, privacy: .public) were walkable. This is the tripwire on \
            ADR 0003's byte-order hypothesis — see docs/ADR/0003-integer-byte-order.md.
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

/// One decoded `IOConnectCallStructMethod` reply. Internal: callers see `SMCKeyInfo` and
/// `SMCValue`, never this.
private struct RawSMCReply {
    let key: FourCharCode
    let dataSize: UInt32
    let dataType: FourCharCode
    let attributes: UInt8
    let bytes: [UInt8]
}
