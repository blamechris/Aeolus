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
    /// Fixed-point types are big-endian; `flt` is little-endian. That asymmetry is real
    /// firmware behaviour, not a mistake — see `docs/SMC-RESEARCH.md`.
    public func scalar() throws -> Double? {
        guard type.isNumeric else { return nil }

        if let expected = type.expectedByteWidth, bytes.count < expected {
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

        case .fds, .ch8, .hex, .unknown:
            return nil
        }
    }

    private var bigEndianUInt16: UInt16 {
        UInt16(bytes[0]) << 8 | UInt16(bytes[1])
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
