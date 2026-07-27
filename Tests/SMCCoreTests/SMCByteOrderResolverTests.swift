import Testing

@testable import SMCCore

// swiftlint:disable force_unwrapping

/// `resolveByteOrder(generation:attributes:)` is the single function ADR 0003 asks for:
/// the whole bit-`0x04` hypothesis, in one place, over plain arithmetic. None of this
/// needs hardware.
@Suite("Byte order resolver — the rule itself")
struct SMCByteOrderResolverTests {

    @Test("Modern interface: bit 0x04 set resolves little-endian")
    func modernBitSetIsLittleEndian() {
        #expect(resolveByteOrder(generation: .modern, attributes: 0x84) == .littleEndian)
        #expect(resolveByteOrder(generation: .modern, attributes: 0x04) == .littleEndian)
    }

    @Test("Modern interface: bit 0x04 clear resolves big-endian")
    func modernBitClearIsBigEndian() {
        #expect(resolveByteOrder(generation: .modern, attributes: 0x80) == .bigEndian)
        #expect(resolveByteOrder(generation: .modern, attributes: 0x90) == .bigEndian)
        #expect(resolveByteOrder(generation: .modern, attributes: 0x00) == .bigEndian)
    }

    /// The whole point of scoping the rule to `.modern`: on legacy firmware, bit `0x04` is
    /// `ATTR_ATOMIC` (VirtualSMC), not byte order, so it must never be consulted there —
    /// see ADR 0003's "an unscoped attribute-bit rule" alternative, rejected for exactly
    /// this reason.
    @Test("Legacy interface is always big-endian, regardless of the attribute byte")
    func legacyIgnoresTheAttributeByte() {
        #expect(resolveByteOrder(generation: .legacy, attributes: 0x84) == .bigEndian)
        #expect(resolveByteOrder(generation: .legacy, attributes: 0x04) == .bigEndian)
        #expect(resolveByteOrder(generation: .legacy, attributes: 0x00) == .bigEndian)
        #expect(resolveByteOrder(generation: .legacy, attributes: 0xFF) == .bigEndian)
    }
}

/// Table-driven tests against bytes actually captured from `Mac16,5` (see
/// `docs/SMC-RESEARCH.md` and issue #30). Each case constructs `SMCValue` with the byte
/// order `resolveByteOrder(generation: .modern, attributes:)` predicts for that key's real
/// attribute byte, then checks the decode against the independently-known-correct value.
/// None of this needs hardware — the bytes are fixed captures, not a live read.
@Suite("Byte order resolver — real captured bytes (Mac16,5)")
struct SMCByteOrderCapturedBytesTests {

    /// `B0AV` (pack voltage, `ui16`, attrs 132, raw `fd2e`). Bit `0x04` set predicts
    /// little-endian, which decodes to 12029 mV.
    @Test("B0AV decodes little-endian to 12029 mV")
    func b0avDecodesLittleEndian() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 132)
        let value = SMCValue(
            key: SMCKey("B0AV")!, type: .ui16, bytes: [0xFD, 0x2E], integerByteOrder: order)
        #expect(try value.scalar() == 12029.0)
    }

    /// The single strongest piece of evidence for the whole rule: a pack voltage summing
    /// exactly to its three cell voltages can only be right by construction. Pinned here
    /// as a regression test — if this ever goes red, the resolver's little-endian branch
    /// is wrong, full stop.
    @Test("Cell-sum identity: B0AV == BC1V + BC2V + BC3V")
    func cellSumIdentity() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 132)

        let b0av = SMCValue(
            key: SMCKey("B0AV")!, type: .ui16, bytes: [0xFD, 0x2E], integerByteOrder: order)
        let bc1v = SMCValue(
            key: SMCKey("BC1V")!, type: .ui16, bytes: [0xA9, 0x0F], integerByteOrder: order)
        let bc2v = SMCValue(
            key: SMCKey("BC2V")!, type: .ui16, bytes: [0xAB, 0x0F], integerByteOrder: order)
        let bc3v = SMCValue(
            key: SMCKey("BC3V")!, type: .ui16, bytes: [0xA9, 0x0F], integerByteOrder: order)

        let pack = try #require(try b0av.scalar())
        let cell1 = try #require(try bc1v.scalar())
        let cell2 = try #require(try bc2v.scalar())
        let cell3 = try #require(try bc3v.scalar())

        #expect(cell1 == 4009.0)
        #expect(cell2 == 4011.0)
        #expect(cell3 == 4009.0)
        #expect(pack == cell1 + cell2 + cell3)
    }

    /// `#KEY` (`ui32`, attrs 128, raw `00000d39`). Bit `0x04` clear predicts big-endian —
    /// no special case required, per ADR 0003 — decoding to 3385, the walked index count
    /// on `Mac16,5`.
    @Test("#KEY decodes big-endian to 3385 with no special case")
    func keyCountDecodesBigEndian() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 128)
        let value = SMCValue(
            key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39],
            integerByteOrder: order)
        #expect(try value.scalar() == 3385.0)
    }

    /// `B0RM` (battery remaining capacity, `ui16`, attrs 144, raw `185e`). Bit `0x04`
    /// clear predicts big-endian, decoding to 6238 mAh — little-endian would read 24088,
    /// a confidently wrong number a user would act on.
    @Test("B0RM decodes big-endian to 6238 mAh")
    func b0rmDecodesBigEndian() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 144)
        let value = SMCValue(
            key: SMCKey("B0RM")!, type: .ui16, bytes: [0x18, 0x5E], integerByteOrder: order)
        #expect(try value.scalar() == 6238.0)
    }

    /// `RBID` (`ui32`, attrs 128, raw `00000006`). Bit clear predicts big-endian.
    @Test("RBID decodes big-endian to 6")
    func rbidDecodesBigEndian() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 128)
        let value = SMCValue(
            key: SMCKey("RBID")!, type: .ui32, bytes: [0x00, 0x00, 0x00, 0x06],
            integerByteOrder: order)
        #expect(try value.scalar() == 6.0)
    }

    /// `RCRV` (`ui32`, attrs 128, raw `00000011`). Bit clear predicts big-endian.
    @Test("RCRV decodes big-endian to 17")
    func rcrvDecodesBigEndian() throws {
        let order = resolveByteOrder(generation: .modern, attributes: 128)
        let value = SMCValue(
            key: SMCKey("RCRV")!, type: .ui32, bytes: [0x00, 0x00, 0x00, 0x11],
            integerByteOrder: order)
        #expect(try value.scalar() == 17.0)
    }
}

/// The fail-safe: an undetectable interface generation must never be guessed. `scalar()`
/// returns `nil` for a plain integer whose `integerByteOrder` was never resolved, exactly
/// as if the connection had never determined the generation — while every other numeric
/// type keeps decoding normally, because the ambiguity is specific to plain integers.
@Suite("Byte order resolver — undetectable generation refuses to guess")
struct SMCUndetectableGenerationTests {

    @Test("A plain-integer key with no resolved byte order decodes to nil, not a guess")
    func plainIntegerWithoutOrderIsNil() throws {
        let ui16Value = SMCValue(key: SMCKey("B0AV")!, type: .ui16, bytes: [0xFD, 0x2E])
        #expect(try ui16Value.scalar() == nil)

        let ui32Value = SMCValue(
            key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39])
        #expect(try ui32Value.scalar() == nil)

        let si32Value = SMCValue(
            key: SMCKey("B0AP")!, type: .si32, bytes: [0x44, 0x64, 0xFF, 0xFF])
        #expect(try si32Value.scalar() == nil)

        let ui64Value = SMCValue(
            key: SMCKey("AOPb")!, type: .ui64,
            bytes: [0x00, 0xC1, 0xE7, 0x0D, 0x05, 0x00, 0x00, 0x00])
        #expect(try ui64Value.scalar() == nil)
    }

    @Test("Raw bytes stay available on SMCValue even when scalar() refuses to decode")
    func rawBytesSurviveAnUndecodedValue() {
        let value = SMCValue(key: SMCKey("B0AV")!, type: .ui16, bytes: [0xFD, 0x2E])
        #expect(value.bytes == [0xFD, 0x2E])
    }

    /// Types outside the ambiguous class are unaffected by an undetectable generation —
    /// the fail-safe is scoped to plain integers, per ADR 0003 and the "scope note" in
    /// issue #30: no control-path key (fan RPM, temperatures, mode keys) is ambiguous.
    @Test("Non-plain-integer types keep decoding even with no resolved byte order")
    func unaffectedTypesStillDecode() throws {
        let flt = SMCValue(
            key: SMCKey("F0Ac")!, type: .flt, bytes: [0x00, 0x00, 0x7A, 0x44])
        #expect(try flt.scalar() == 1000.0)

        let sp78 = SMCValue(key: SMCKey("TC0P")!, type: .sp78, bytes: [0x32, 0x00])
        #expect(try sp78.scalar() == 50.0)

        let ui8 = SMCValue(key: SMCKey("FNum")!, type: .ui8, bytes: [0x02])
        #expect(try ui8.scalar() == 2.0)
    }
}

/// Synthetic big-endian patterns for the types that exist **only** on the legacy
/// (Intel) SMC interface. Unobservable on this project's development hardware (`Mac16,5`,
/// Apple Silicon) — no key on that machine declares any of these types — so these are
/// derived from the documented format, not a captured read. See
/// `docs/SMC-RESEARCH.md` § "Untestable on this hardware".
///
/// These three are unconditionally big-endian *by definition of the type*, on both
/// interface generations — they never call `resolveByteOrder`, unlike the plain
/// integers above.
@Suite("Synthetic Intel-only fixed-point types (unobservable on Mac16,5)")
struct SMCIntelFixedPointSyntheticTests {

    @Test("fpe2 (Intel fan RPM: unsigned 14.2 fixed point) is unconditionally big-endian")
    func fpe2IsBigEndian() throws {
        // 0x0FA0 >> 2 == 1000.
        let value = SMCValue(key: SMCKey("F0Ac")!, type: .fpe2, bytes: [0x0F, 0xA0])
        #expect(try value.scalar() == 1000.0)
    }

    @Test("fp78 (unsigned 7.8 fixed point) is unconditionally big-endian")
    func fp78IsBigEndian() throws {
        // 0x1900 / 256 == 25.0.
        let value = SMCValue(key: SMCKey("TC0P")!, type: .fp78, bytes: [0x19, 0x00])
        #expect(try value.scalar() == 25.0)
    }

    @Test("sp78 (Intel temperature: signed 7.8 fixed point) is unconditionally big-endian")
    func sp78IsBigEndian() throws {
        let positive = SMCValue(key: SMCKey("TC0P")!, type: .sp78, bytes: [0x32, 0x00])
        #expect(try positive.scalar() == 50.0)

        // A negative reading exercises the sign bit, not just the byte order.
        let negative = SMCValue(key: SMCKey("TC0P")!, type: .sp78, bytes: [0xFF, 0x00])
        #expect(try negative.scalar() == -1.0)
    }
}

// swiftlint:enable force_unwrapping
