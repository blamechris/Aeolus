import Testing

@testable import SMCCore

@Suite("SMC key type registry")
struct SMCKeyTypeTests {

    @Test("Recognised four-character codes map to their types")
    func recognisesKnownTypes() {
        #expect(SMCKeyType(fourCharCode: fourCC("flt ")) == .flt)
        #expect(SMCKeyType(fourCharCode: fourCC("fpe2")) == .fpe2)
        #expect(SMCKeyType(fourCharCode: fourCC("sp78")) == .sp78)
        #expect(SMCKeyType(fourCharCode: fourCC("{fds")) == .fds)
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
        for type in [SMCKeyType.flt, .fpe2, .fp78, .sp78, .ui8, .ui16, .ui32, .si8, .si16] {
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

    /// Apple Silicon fan RPM: little-endian IEEE-754.
    @Test("Decodes flt as a little-endian float")
    func decodesFloat() throws {
        // 1000.0f == 0x447A0000, little-endian on the wire.
        let value = SMCValue(key: SMCKey("F0Ac")!, type: .flt, bytes: [0x00, 0x00, 0x7A, 0x44])
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
}
