import Foundation
import os

/// A raw SMC read: the declared type, the bytes the firmware handed back, and — for the
/// plain integer types only — the byte order resolved for this key by `SMCConnection`.
///
/// Decoding is driven by `type`. The one exception is deliberate: byte order for a plain
/// integer is not implied by its declared type, so it travels alongside the value instead
/// — see `integerByteOrder` and `docs/ADR/0003-integer-byte-order.md`.
public struct SMCValue: Sendable, Hashable {
    public let key: SMCKey
    public let type: SMCKeyType
    public let bytes: [UInt8]

    /// The byte order resolved for this key's plain-integer decode, or `nil` if the SMC
    /// interface generation could not be determined for the connection that produced this
    /// value. Ignored by every type except `ui16`/`si16`/`ui32`/`si32`/`ui64`/`si64` — see
    /// `scalar()`.
    public let integerByteOrder: SMCByteOrder?

    public init(
        key: SMCKey, type: SMCKeyType, bytes: [UInt8], integerByteOrder: SMCByteOrder? = nil
    ) {
        self.key = key
        self.type = type
        self.bytes = bytes
        self.integerByteOrder = integerByteOrder
    }
}

extension SMCValue {
    /// Decodes the value as a scalar, or returns `nil` for non-numeric types.
    ///
    /// Byte order is a genuine, unconditional property of the type for five formats:
    /// `flt` and `ioft` are little-endian by construction; `fpe2`, `fp78`, and `sp78` are
    /// big-endian by definition. Those decode below without consulting anything else.
    ///
    /// It is **not** a property of the type for the plain integers (`ui16`, `si16`,
    /// `ui32`, `si32`, `ui64`, `si64`). Byte order for those is firmware-declared per key
    /// — resolved by `resolveByteOrder(generation:attributes:)` and carried on
    /// `integerByteOrder` — per `docs/ADR/0003-integer-byte-order.md`. When that has not
    /// been resolved (the SMC interface generation was undetectable for this connection),
    /// this function refuses to guess: it logs and returns `nil` rather than decoding with
    /// an assumed order. `bytes` remains available on this value regardless, so a caller
    /// that wants the raw payload still has it.
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
            // Little-endian IEEE-754 single precision.
            let bits =
                UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
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

        case .ioft:
            // Little-endian 48.16 fixed point. Derived by this project, not from a
            // published source — see the doc comment on SMCKeyType.ioft and
            // docs/SMC-RESEARCH.md §5. Read the 8 bytes as a little-endian UInt64 and
            // divide by 65536.
            return Double(littleEndianUInt64) / 65536.0

        case .fds, .jst, .ch8, .hex, .unknown:
            return nil
        }
    }

    /// Decodes a plain integer (`ui16`, `si16`, `ui32`, `si32`, `ui64`, `si64`) using
    /// `integerByteOrder`, or returns `nil` — via `resolvedIntegerByteOrder()` — if that
    /// was never resolved. Split out of `scalar()`'s switch purely for readability: these
    /// six cases share one guard and differ only in width and signedness.
    private func decodePlainInteger() -> Double? {
        guard let order = resolvedIntegerByteOrder() else { return nil }

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

    /// Returns the byte order this value's plain-integer decode should use, or logs and
    /// returns `nil` if it was never resolved. The log line is the "plus a log line" half
    /// of ADR 0003's fail-safe: a caller that only inspects the returned `nil` cannot tell
    /// "non-numeric type" apart from "refused to guess", but the log can.
    private func resolvedIntegerByteOrder() -> SMCByteOrder? {
        guard let order = integerByteOrder else {
            Self.logger.error(
                """
                \(self.key.rawValue, privacy: .public) is a plain integer \
                (\(self.type.fourCharString, privacy: .public)) whose byte order could not \
                be resolved — the SMC interface generation was undetectable for this \
                connection. Refusing to guess; see docs/ADR/0003-integer-byte-order.md. \
                Raw bytes remain on SMCValue.bytes.
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
    /// which means only inside `AeolusHelper`. It is deliberately not `public`.
    ///
    /// - Note: Implemented in E3 (Intel, `fpe2`) and E4 (Apple Silicon, `flt`), each with
    ///   round-trip tests against `SMCValue.scalar()`. Left unimplemented rather than
    ///   guessed: a wrong encoding here writes a wrong RPM to real hardware.
    package func encode(scalar: Double) throws -> [UInt8] {
        throw SMCError.encodingNotImplemented(type: self)
    }
}
