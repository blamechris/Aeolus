import Testing

@testable import SMCCore

// Force unwrapping is fine in tests: a malformed key literal here is a typo, and a
// crashing test is simply a failing test. In Sources it is a warning, and inside the
// helper it is an error — see .swiftlint.yml.
// swiftlint:disable force_unwrapping

@Suite("SMC key type registry")
struct SMCKeyTypeTests {

    @Test("Recognised four-character codes map to their types")
    func recognisesKnownTypes() {
        #expect(SMCKeyType(fourCharCode: fourCC("flt ")) == .flt)
        #expect(SMCKeyType(fourCharCode: fourCC("fpe2")) == .fpe2)
        #expect(SMCKeyType(fourCharCode: fourCC("sp78")) == .sp78)
        #expect(SMCKeyType(fourCharCode: fourCC("{fds")) == .fds)
    }

    /// The six types added by the E1 hardware spike — 177 keys (5.2% of the 3385 on
    /// `Mac16,5`) that previously fell through to `.unknown`.
    @Test("Recognises the six types found by the E1 hardware spike")
    func recognisesSpikeTypes() {
        #expect(SMCKeyType(fourCharCode: fourCC("flag")) == .flag)
        #expect(SMCKeyType(fourCharCode: fourCC("si32")) == .si32)
        #expect(SMCKeyType(fourCharCode: fourCC("ui64")) == .ui64)
        #expect(SMCKeyType(fourCharCode: fourCC("si64")) == .si64)
        #expect(SMCKeyType(fourCharCode: fourCC("ioft")) == .ioft)
        #expect(SMCKeyType(fourCharCode: fourCC("{jst")) == .jst)
    }

    @Test("expectedByteWidth for the six new types")
    func expectedByteWidthOfSpikeTypes() {
        #expect(SMCKeyType.flag.expectedByteWidth == 1)
        #expect(SMCKeyType.si32.expectedByteWidth == 4)
        #expect(SMCKeyType.ui64.expectedByteWidth == 8)
        #expect(SMCKeyType.si64.expectedByteWidth == 8)
        #expect(SMCKeyType.ioft.expectedByteWidth == 8)
        #expect(SMCKeyType.jst.expectedByteWidth == nil)
    }

    @Test("isNumeric for the six new types")
    func isNumericOfSpikeTypes() {
        #expect(SMCKeyType.flag.isNumeric == true)
        #expect(SMCKeyType.si32.isNumeric == true)
        #expect(SMCKeyType.ui64.isNumeric == true)
        #expect(SMCKeyType.si64.isNumeric == true)
        #expect(SMCKeyType.ioft.isNumeric == true)
        #expect(SMCKeyType.jst.isNumeric == false)
    }

    /// An unrecognised type must survive as data rather than being dropped. A Mac we have
    /// never seen should still show every sensor it has.
    @Test("Unrecognised types are carried through, not discarded")
    func preservesUnknownTypes() {
        let type = SMCKeyType(fourCharCode: fourCC("zzzz"))
        #expect(type == .unknown(fourCC("zzzz")))
        #expect(type.fourCharString == "zzzz")
        #expect(type.isNumeric == false)
    }

    @Test("Round-trips through its four-character representation")
    func roundTripsFourCharString() {
        let types: [SMCKeyType] = [
            .flt, .fpe2, .fp78, .sp78, .ui8, .ui16, .ui32, .si8, .si16,
            .si32, .ui64, .si64, .flag, .ioft, .fds, .jst, .ch8, .hex,
        ]
        for type in types {
            #expect(SMCKeyType(fourCharCode: fourCC(type.fourCharString)) == type)
        }
    }

    private func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

@Suite("SMC value decoding")
struct SMCValueTests {

    /// Intel fan RPM: big-endian 14.2 fixed point, so the stored value is RPM << 2.
    @Test("Decodes fpe2 as RPM shifted left by two")
    func decodesFPE2() throws {
        let value = SMCValue(key: SMCKey("F0Ac")!, type: .fpe2, bytes: [0x0F, 0xA0])
        #expect(try value.scalar() == 1000.0)
    }

    /// Apple Silicon fan RPM: little-endian IEEE-754. Byte order is firmware-declared per
    /// key since ADR 0004, so the resolved order is supplied explicitly here — `F0Ac`
    /// carries attribute bit `0x04` set (132) on `Mac16,5`, which resolves little-endian.
    @Test("Decodes flt as a little-endian float")
    func decodesFloat() throws {
        // 1000.0f == 0x447A0000, little-endian on the wire.
        let value = SMCValue(
            key: SMCKey("F0Ac")!, type: .flt, bytes: [0x00, 0x00, 0x7A, 0x44],
            byteOrder: .littleEndian)
        #expect(try value.scalar() == 1000.0)
    }

    /// The classic Intel temperature encoding, and it is signed.
    @Test("Decodes sp78 including negative temperatures")
    func decodesSignedFixedPoint() throws {
        let positive = SMCValue(key: SMCKey("TC0P")!, type: .sp78, bytes: [0x32, 0x00])
        #expect(try positive.scalar() == 50.0)

        let negative = SMCValue(key: SMCKey("TC0P")!, type: .sp78, bytes: [0xFF, 0x00])
        #expect(try negative.scalar() == -1.0)
    }

    /// Big-endian unsigned 7.8 fixed point. Not observed on `Mac16,5` (Apple Silicon
    /// carries no `fp78` keys) — this is a synthetic pattern derived from the documented
    /// format, not a captured read. See docs/SMC-RESEARCH.md on Intel-only encodings.
    @Test("Decodes fp78 (synthetic pattern; unobservable on Apple Silicon)")
    func decodesUnsignedFixedPoint() throws {
        let value = SMCValue(key: SMCKey("TC0P")!, type: .fp78, bytes: [0x19, 0x00])
        #expect(try value.scalar() == 25.0)
    }

    @Test("Non-numeric types decode to nil rather than a fabricated number")
    func nonNumericDecodesToNil() throws {
        let value = SMCValue(key: SMCKey("FDSP")!, type: .hex, bytes: [0xDE, 0xAD])
        #expect(try value.scalar() == nil)
    }

    @Test("A short read is an error, not a silently truncated value")
    func shortReadThrows() {
        let value = SMCValue(key: SMCKey("F0Ac")!, type: .flt, bytes: [0x00, 0x00])
        #expect(throws: SMCError.self) { try value.scalar() }
    }

    /// A byte count *longer* than declared must also be rejected. Decoding a prefix of
    /// the wrong-sized bytes would fabricate a value rather than reporting the mismatch.
    @Test("A long read is also an error, not silently truncated to the expected width")
    func longReadThrows() {
        let value = SMCValue(
            key: SMCKey("B0AP")!, type: .si32, bytes: [0x44, 0x64, 0xFF, 0xFF, 0x00])
        #expect(throws: SMCError.self) { try value.scalar() }
    }

    // MARK: - Types added by the E1 hardware spike (real bytes captured on Mac16,5)

    /// `flag` bytes are observed as only `0x00` or `0x01` across all 50 keys on
    /// `Mac16,5`. Real captured bytes: `AC-S` (charger present) and `AC-C`.
    @Test("Decodes flag as a boolean-valued scalar")
    func decodesFlag() throws {
        let asserted = SMCValue(key: SMCKey("AC-S")!, type: .flag, bytes: [0x01])
        #expect(try asserted.scalar() == 1.0)

        let clear = SMCValue(key: SMCKey("AC-C")!, type: .flag, bytes: [0x00])
        #expect(try clear.scalar() == 0.0)
    }

    /// Never observed on `Mac16,5`, but a firmware that returns anything other than
    /// 0x00/0x01 for a `flag` key is not honouring the boolean type it declared. Passing
    /// that byte through as a scalar would fabricate a reading nobody measured, so this
    /// must throw rather than silently surface an arbitrary number.
    @Test("A flag byte outside {0, 1} is an error, not a silently fabricated number")
    func flagRejectsNonBooleanByte() {
        let value = SMCValue(key: SMCKey("AC-S")!, type: .flag, bytes: [0x42])
        #expect(throws: SMCError.self) { try value.scalar() }
    }

    /// Little-endian signed 32-bit. Real captured bytes from `Mac16,5`: `BC1I`
    /// (positive battery current, attrs 132) and `B0AP` (negative battery power, attrs
    /// 132) — bit `0x04` set on both, so `resolveByteOrder` predicts little-endian; see
    /// ADR 0003.
    @Test("Decodes si32 as little-endian, including negative values")
    func decodesSignedInt32() throws {
        let positive = SMCValue(
            key: SMCKey("BC1I")!, type: .si32, bytes: [0xF3, 0x00, 0x00, 0x00],
            byteOrder: .littleEndian)
        #expect(try positive.scalar() == 243.0)

        let negative = SMCValue(
            key: SMCKey("B0AP")!, type: .si32, bytes: [0x44, 0x64, 0xFF, 0xFF],
            byteOrder: .littleEndian)
        #expect(try negative.scalar() == -39868.0)
    }

    /// Little-endian unsigned 64-bit. Real captured bytes from `Mac16,5`: `AOPb`
    /// (attrs 132, bit `0x04` set).
    @Test("Decodes ui64 as little-endian")
    func decodesUnsignedInt64() throws {
        let value = SMCValue(
            key: SMCKey("AOPb")!, type: .ui64,
            bytes: [0x00, 0xC1, 0xE7, 0x0D, 0x05, 0x00, 0x00, 0x00],
            byteOrder: .littleEndian)
        #expect(try value.scalar() == 21_708_128_512.0)
    }

    /// Little-endian signed 64-bit. Real captured bytes from `Mac16,5`: `BAAC`
    /// (positive) and `zSDa` (negative — top byte `0xff`), both attrs 132 (bit `0x04`
    /// set).
    @Test("Decodes si64 as little-endian, including negative values")
    func decodesSignedInt64() throws {
        let positive = SMCValue(
            key: SMCKey("BAAC")!, type: .si64,
            bytes: [0xFF, 0x1D, 0x54, 0x01, 0x00, 0x00, 0x00, 0x00],
            byteOrder: .littleEndian)
        #expect(try positive.scalar() == 22_289_919.0)

        let negative = SMCValue(
            key: SMCKey("zSDa")!, type: .si64,
            bytes: [0x51, 0x57, 0x1B, 0xEB, 0xFF, 0xFF, 0xFF, 0xFF],
            byteOrder: .littleEndian)
        #expect(try negative.scalar() == -350_529_711.0)
    }

    /// `ioft`: little-endian 48.16 fixed point. Derived by this project — see the doc
    /// comment on `SMCKeyType.ioft`. `TG0C`'s bytes divide out to an exact 30.0, useful
    /// as a sanity check on the shift/divide independent of floating-point tolerance.
    /// Since ADR 0004, `ioft` consumes the resolved byte order like `flt` — `TG0C`
    /// carries attribute bit `0x04` set on `Mac16,5`, which resolves little-endian.
    @Test("Decodes ioft as little-endian 48.16 fixed point (TG0C, exact)")
    func decodesIOFTExact() throws {
        let value = SMCValue(
            key: SMCKey("TG0C")!, type: .ioft,
            bytes: [0x00, 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00],
            byteOrder: .littleEndian)
        #expect(try value.scalar() == 30.0)
    }

    /// The specific corroborating case from the E1 spike: `TR0Z`'s raw bytes
    /// `9ad9330000000000`, which `IOHIDEventSystemClient`'s `PMU tcal` independently
    /// reports as 51.850. Required by the E1.1 acceptance criteria.
    @Test("Decodes ioft as little-endian 48.16 fixed point (TR0Z, corroborated by IOHID)")
    func decodesIOFTCorroborated() throws {
        let value = SMCValue(
            key: SMCKey("TR0Z")!, type: .ioft,
            bytes: [0x9A, 0xD9, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00],
            byteOrder: .littleEndian)
        let scalar = try #require(try value.scalar())
        #expect(abs(scalar - 51.85) < 0.001)
    }

    /// `{jst` is a 21-byte structured record with no derived field layout. It stays
    /// non-numeric and opaque, like `{fds` — real captured bytes from `Mac16,5` (`D1JD`).
    @Test("Decodes {jst as non-numeric, preserving the raw bytes")
    func jstIsNonNumeric() throws {
        let bytes: [UInt8] = [
            0x4C, 0x1D, 0x00, 0x00, 0x4C, 0x1D, 0x00, 0x00, 0x4C, 0x1D, 0x4C, 0x1D,
            0x00, 0x00, 0x00, 0x00, 0x4C, 0x1D, 0x00, 0x00, 0x00,
        ]
        let value = SMCValue(key: SMCKey("D1JD")!, type: .jst, bytes: bytes)
        #expect(try value.scalar() == nil)
        #expect(value.bytes == bytes)
    }
}

// swiftlint:enable force_unwrapping
