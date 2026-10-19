import Foundation
import os

/// A raw SMC read: the declared type, the bytes the firmware handed back, and — for the
/// types whose byte order is firmware-declared per key rather than fixed by the type —
/// the byte order resolved for this key by `SMCConnection`.
///
/// Decoding is driven by `type`. The one exception is deliberate: byte order is not
/// implied by the declared type for every numeric format, so it travels alongside the
/// value instead — see `byteOrder`, `docs/ADR/0003-integer-byte-order.md`, and
/// `docs/ADR/0004-float-byte-order.md`.
public struct SMCValue: Sendable, Hashable {
    public let key: SMCKey
    public let type: SMCKeyType
    public let bytes: [UInt8]

    /// The byte order resolved for this key by
    /// `resolveByteOrder(generation:attributes:type:)`, or `nil` if the SMC interface
    /// generation could not be determined for the connection that produced this value.
    ///
    /// Consumed by `scalar()` for the six plain-integer types
    /// (`ui16`/`si16`/`ui32`/`si32`/`ui64`/`si64`) and, since ADR 0004, `flt`/`ioft` — the
    /// types whose byte order the firmware declares per key rather than fixing by type.
    /// Ignored by every other type: `fpe2`/`fp78`/`sp78` are big-endian by definition of
    /// the type, and `ui8`/`si8`/`flag` are a single byte with no order to resolve.
    public let byteOrder: SMCByteOrder?

    public init(
        key: SMCKey, type: SMCKeyType, bytes: [UInt8], byteOrder: SMCByteOrder? = nil
    ) {
        self.key = key
        self.type = type
        self.bytes = bytes
        self.byteOrder = byteOrder
    }
}

extension SMCValue {
    /// Decodes the value as a scalar, or returns `nil` for non-numeric types.
    ///
    /// Byte order is a genuine, unconditional property of the type for exactly three
    /// formats: `fpe2`, `fp78`, and `sp78` are big-endian by definition. Those decode
    /// below without consulting anything else.
    ///
    /// It is **not** a property of the type for the plain integers (`ui16`, `si16`,
    /// `ui32`, `si32`, `ui64`, `si64`) or, since
    /// [ADR 0004](../../docs/ADR/0004-float-byte-order.md), for `flt`/`ioft`. Byte order
    /// for those is firmware-declared per key — resolved by
    /// `resolveByteOrder(generation:attributes:type:)` and carried on `byteOrder` — per
    /// `docs/ADR/0003-integer-byte-order.md` and ADR 0004. When that has not been resolved
    /// (the SMC interface generation was undetectable for this connection), this function
    /// refuses to guess: it logs and returns `nil` rather than decoding with an assumed
    /// order. `bytes` remains available on this value regardless, so a caller that wants
    /// the raw payload still has it.
    public func scalar() throws -> Double? {
        guard type.isNumeric else { return nil }

        // A byte count that disagrees with the declared type's width — short or long —
        // is an error. Decoding a prefix of the wrong-sized bytes would fabricate a
        // value; the firmware's own report of how many bytes it sent wins.
        if let expected = type.expectedByteWidth, bytes.count != expected {
            throw SMCError.sizeMismatch(key: key, declared: type, reportedBytes: bytes.count)
        }

        switch type {
        case .flt:
            // IEEE-754 single precision. Byte order is firmware-declared per key, not
            // implied by the type — see resolvedByteOrder() and
            // docs/ADR/0004-float-byte-order.md.
            guard let order = resolvedByteOrder() else { return nil }
            let bits = order == .littleEndian ? littleEndianUInt32 : bigEndianUInt32
            return Double(Float(bitPattern: bits))

        case .fpe2:
            // Big-endian unsigned 14.2: the stored value is the reading << 2.
            return Double(bigEndianUInt16) / 4.0

        case .fp78:
            // Big-endian unsigned 7.8.
            return Double(bigEndianUInt16) / 256.0

        case .sp78:
            // Big-endian signed 7.8.
            return Double(Int16(bitPattern: bigEndianUInt16)) / 256.0

        case .ui8:
            return Double(bytes[0])

        case .si8:
            return Double(Int8(bitPattern: bytes[0]))

        case .ui16, .si16, .ui32, .si32, .ui64, .si64:
            // Byte order is firmware-declared per key, not implied by the type — see
            // decodePlainInteger() and docs/ADR/0003-integer-byte-order.md.
            return decodePlainInteger()

        case .ioft:
            // Little-endian 48.16 fixed point, derived by this project — see the doc
            // comment on SMCKeyType.ioft and docs/SMC-RESEARCH.md §5. As of ADR 0004,
            // byte order is firmware-declared per key like flt, not fixed by the type;
            // divide the resolved-order UInt64 by 65536.
            guard let order = resolvedByteOrder() else { return nil }
            let bits = order == .littleEndian ? littleEndianUInt64 : bigEndianUInt64
            return Double(bits) / 65536.0

        case .flag:
            // A single byte, expected to be 0x00 or 0x01 — observed as exactly that
            // across all 50 flag keys on Mac16,5. No endianness applies to a single
            // byte. But this type is documented and tested as a boolean, so a byte
            // outside that set means the firmware is not honouring its own declared
            // type; passing it through as an arbitrary Double would fabricate a
            // reading nothing observed, so it is reported as an error instead.
            guard bytes[0] == 0x00 || bytes[0] == 0x01 else {
                throw SMCError.invalidFlagValue(key: key, byte: bytes[0])
            }
            return Double(bytes[0])

        case .fds, .jst, .ch8, .hex, .unknown:
            return nil
        }
    }

    /// Decodes a plain integer (`ui16`, `si16`, `ui32`, `si32`, `ui64`, `si64`) using
    /// `byteOrder`, or returns `nil` — via `resolvedByteOrder()` — if that was never
    /// resolved. Split out of `scalar()`'s switch purely for readability: these six cases
    /// share one guard and differ only in width and signedness.
    private func decodePlainInteger() -> Double? {
        guard let order = resolvedByteOrder() else { return nil }

        switch type {
        case .ui16:
            return Double(order == .littleEndian ? littleEndianUInt16 : bigEndianUInt16)
        case .si16:
            let bits = order == .littleEndian ? littleEndianUInt16 : bigEndianUInt16
            return Double(Int16(bitPattern: bits))
        case .ui32:
            return Double(order == .littleEndian ? littleEndianUInt32 : bigEndianUInt32)
        case .si32:
            let bits = order == .littleEndian ? littleEndianUInt32 : bigEndianUInt32
            return Double(Int32(bitPattern: bits))
        case .ui64:
            return Double(order == .littleEndian ? littleEndianUInt64 : bigEndianUInt64)
        case .si64:
            let bits = order == .littleEndian ? littleEndianUInt64 : bigEndianUInt64
            return Double(Int64(bitPattern: bits))
        default:
            // Unreachable: scalar() only calls this for the six plain-integer cases.
            return nil
        }
    }

    /// Returns the byte order this value's decode should use — for the plain integers and,
    /// since ADR 0004, `flt`/`ioft` — or logs and returns `nil` if it was never resolved.
    /// The log line is the "plus a log line" half of the fail-safe both ADRs share: a
    /// caller that only inspects the returned `nil` cannot tell "non-numeric type" apart
    /// from "refused to guess", but the log can.
    private func resolvedByteOrder() -> SMCByteOrder? {
        guard let order = byteOrder else {
            Self.logger.error(
                """
                \(self.key.rawValue, privacy: .public) \
                (\(self.type.fourCharString, privacy: .public)) has no resolved byte order \
                — the SMC interface generation was undetectable for this connection. \
                Refusing to guess; see docs/ADR/0003-integer-byte-order.md and \
                docs/ADR/0004-float-byte-order.md. Raw bytes remain on SMCValue.bytes.
                """
            )
            return nil
        }
        return order
    }

    private static let logger = Logger(subsystem: "dev.aeolus.SMCCore", category: "ByteOrder")

    private var bigEndianUInt16: UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private var littleEndianUInt16: UInt16 {
        UInt16(bytes[1]) << 8 | UInt16(bytes[0])
    }

    private var bigEndianUInt32: UInt32 {
        UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }

    private var littleEndianUInt32: UInt32 {
        UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    private var bigEndianUInt64: UInt64 {
        UInt64(bytes[0]) << 56
            | UInt64(bytes[1]) << 48
            | UInt64(bytes[2]) << 40
            | UInt64(bytes[3]) << 32
            | UInt64(bytes[4]) << 24
            | UInt64(bytes[5]) << 16
            | UInt64(bytes[6]) << 8
            | UInt64(bytes[7])
    }

    private var littleEndianUInt64: UInt64 {
        UInt64(bytes[0])
            | UInt64(bytes[1]) << 8
            | UInt64(bytes[2]) << 16
            | UInt64(bytes[3]) << 24
            | UInt64(bytes[4]) << 32
            | UInt64(bytes[5]) << 40
            | UInt64(bytes[6]) << 48
            | UInt64(bytes[7]) << 56
    }
}

extension SMCKeyType {
    /// Encodes a scalar into this key type's wire representation.
    ///
    /// This is the inverse of `SMCValue.scalar()` and is used only on the write path,
    /// which means only inside `AeolusHelper`. It is deliberately not reachable through a
    /// plain `import SMCCore`: `@_spi(FanWrite)` makes the symbol public in the binary but
    /// unnameable except from a module that opts in with `@_spi(FanWrite) import SMCCore`,
    /// and only `Sources/AeolusHelper` does. It is here rather than `package` because the
    /// Xcode `AeolusHelper` target consumes `SMCCore` as a package *product* and so is
    /// outside the package `package` visibility is computed against — see the 2026-09-06
    /// amendment in [ADR 0008](../../docs/ADR/0008-write-authorisation.md). Encoding is
    /// half of a write, so it is gated exactly as the write is.
    ///
    /// `byteOrder` is the order to encode with — resolved the same way a read resolves
    /// it, via `resolveByteOrder(generation:attributes:type:)` from a fresh `keyInfo` at
    /// write time, per [ADR 0004](../../docs/ADR/0004-float-byte-order.md). `nil` means
    /// the interface generation was undetectable; a multi-byte numeric type whose order is
    /// firmware-declared (the plain integers, `flt`, `ioft`) must throw rather than guess,
    /// exactly as `scalar()` refuses to decode. `ui8`/`flag` ignore this argument — a
    /// single byte has no byte order to apply — and so do `fpe2`/`fp78`/`sp78`, which are
    /// big-endian by definition of the type.
    ///
    /// Two types are encoded, the two the Apple Silicon write plane writes (ADR 0014's B1
    /// amendment):
    /// - **`ui8`**, for `F<n>Md` and `Ftst`: one byte, exactly an integer in `0...255`. A
    ///   fraction, a value out of range, `NaN` or an infinity is refused rather than rounded
    ///   or wrapped, because a rounded mode byte is a different mode. The order is ignored.
    /// - **`flt`**, for `F<n>Tg`: IEEE-754 single precision, in the order given, which must be
    ///   given. The `Double` is judged before it converts, so what rounding makes of it can
    ///   neither admit nor refuse it:
    ///   - a magnitude above `Float.greatestFiniteMagnitude` is refused. That is `NaN`, an
    ///     infinity, and a value just past the bound, which would round down to it and be
    ///     written as less than was asked for;
    ///   - **a non-zero value that underflows to zero**, such as `1e-50`, is refused. Written to
    ///     `F<n>Tg`, a zero asks the fan to stop, which `CLAUDE.md` rule 3 forbids, so a request
    ///     that is not zero must never be written as one. Zero itself is exact and encodes, and
    ///     a value that underflows to a subnormal stays non-zero and rounds, as any value between
    ///     two floats does.
    ///
    ///   ADR 0008's clamp only ever produces finite targets inside the fan's envelope, and this
    ///   does not trust that it did (ADR 0004).
    ///
    /// A refusal throws `SMCError.notPermitted`. `encodingFailed(key:type:)` is the case for
    /// "the value does not fit the type", but it carries a key, and this function — whose
    /// signature the SPI census pins — has none. Every other type still throws
    /// `encodingNotImplemented(type:)`: E3's `fpe2`, and anything the write plane does not
    /// write, stay unwritten rather than guessed — a wrong encoding writes a wrong RPM to
    /// real hardware.
    ///
    /// Encoding is type-level only. Whether a value is a *safe* RPM is `FanKit`'s
    /// `FanControlEnvelope`'s question, answered before anything reaches here, and a
    /// restore's zero bytes never come through this function at all (ADR 0014's B1 amendment).
    ///
    /// - Note: `flt`'s little-endian output is pinned to the bytes `F0Tg` and `F1Tg` were
    ///   observed holding on `Mac16,5`, so a byte swap made symmetrically here and in
    ///   `scalar()` cannot pass as a round trip. See `SMCKeyTypeEncodeTests`.
    @_spi(FanWrite) public func encode(scalar: Double, byteOrder: SMCByteOrder?) throws -> [UInt8] {
        switch self {
        case .ui8:
            guard let byte = UInt8(exactly: scalar) else {
                Self.logRefusal(scalar, of: self, reason: "not an integer in 0...255")
                throw SMCError.notPermitted
            }
            return [byte]

        case .flt:
            guard let order = byteOrder else {
                Self.logRefusal(scalar, of: self, reason: "no resolved byte order")
                throw SMCError.notPermitted
            }
            // On the `Double`, before it converts: just past the bound, `Float(scalar)` rounds
            // down to `greatestFiniteMagnitude` and is finite. `NaN` fails the comparison too.
            guard scalar.magnitude <= Double(Float.greatestFiniteMagnitude) else {
                Self.logRefusal(scalar, of: self, reason: "outside Float's finite range")
                throw SMCError.notPermitted
            }
            let single = Float(scalar)
            guard single != 0 || scalar == 0 else {
                Self.logRefusal(scalar, of: self, reason: "non-zero, and underflows to zero")
                throw SMCError.notPermitted
            }
            let bits = single.bitPattern
            let littleEndian: [UInt8] = [
                UInt8(bits & 0xFF),
                UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF),
                UInt8((bits >> 24) & 0xFF),
            ]
            return order == .littleEndian ? littleEndian : littleEndian.reversed()

        default:
            throw SMCError.encodingNotImplemented(type: self)
        }
    }

    private static func logRefusal(_ scalar: Double, of type: SMCKeyType, reason: String) {
        encodeLogger.fault(
            """
            Refused to encode \(scalar, privacy: .public) as \
            \(type.fourCharString, privacy: .public): \(reason, privacy: .public). Nothing was \
            written.
            """
        )
    }

    private static let encodeLogger = Logger(subsystem: "dev.aeolus.SMCCore", category: "Encode")
}
