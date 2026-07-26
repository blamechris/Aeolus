import Foundation

/// A raw SMC read: the declared type plus the bytes the firmware handed back.
///
/// Decoding is driven entirely by `type`. Nothing here knows or cares which machine it
/// is running on.
public struct SMCValue: Sendable, Hashable {
    public let key: SMCKey
    public let type: SMCKeyType
    public let bytes: [UInt8]

    public init(key: SMCKey, type: SMCKeyType, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }
}

extension SMCValue {
    /// Decodes the value as a scalar, or returns `nil` for non-numeric types.
    ///
    /// Byte order is a genuine property of the type for the fixed-point formats only:
    /// `flt` and `ioft` are little-endian by construction, and `fpe2`/`fp78`/`sp78` are
    /// big-endian by definition — those five decode unconditionally and correctly below.
    ///
    /// It is **not** a property of the type for the plain integers (`ui16`, `si16`,
    /// `ui32`, `si32`, `ui64`, `si64`). Byte order for those is firmware-declared per
    /// key — bit `0x04` of the key's attribute byte on the modern SMC interface, per
    /// `docs/ADR/0003-integer-byte-order.md` — and this decoder does not yet resolve it.
    /// The `ui16`/`si16`/`ui32` cases below decode big-endian unconditionally and the
    /// `si32`/`ui64`/`si64` cases decode little-endian unconditionally, regardless of
    /// what the key actually declares. Measured on `Mac16,5`, the big-endian guess for
    /// `ui16`/`ui32` alone is **known to be wrong** for the majority of the roughly 459
    /// affected keys — see issue #30, which is the tracked fix for this function. Until
    /// that lands, do not treat a plain-integer reading from this decoder as trustworthy
    /// beyond the specific keys covered by a passing test.
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

        case .ui16:
            return Double(bigEndianUInt16)

        case .si16:
            return Double(Int16(bitPattern: bigEndianUInt16))

        case .ui32:
            let value =
                UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3])
            return Double(value)

        case .si32:
            // Little-endian signed 32-bit. Observed on Mac16,5 (battery current/power).
            return Double(Int32(bitPattern: littleEndianUInt32))

        case .ui64:
            // Little-endian unsigned 64-bit. Observed on Mac16,5 (energy accumulators).
            return Double(littleEndianUInt64)

        case .si64:
            // Little-endian signed 64-bit. Observed on Mac16,5.
            return Double(Int64(bitPattern: littleEndianUInt64))

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

    private var bigEndianUInt16: UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private var littleEndianUInt32: UInt32 {
        UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
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
