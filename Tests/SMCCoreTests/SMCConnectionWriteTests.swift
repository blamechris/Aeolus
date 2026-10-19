import IOKit
import Testing

// `write(_:to:)` is `@_spi(FanWrite) public`, and `@testable` widens internal access only, so
// naming it needs the opt-in by name. This file and `SMCConnectionTests.swift` are the only
// test files allowed that opt-in, and neither may obtain an opened connection. Everything either
// declares is `private`, so no other file can call a helper here that writes
// (`WriteSeamTestIsolationTests`, rule 5).
@_spi(FanWrite) @testable import SMCCore

// swiftlint:disable force_unwrapping

/// The write body, tested with no SMC and with nothing sent.
///
/// **Nothing in this file may ever write to a real SMC.** Every write here is made on one of
/// two handles:
/// - a connection that was never opened, which `call(_:)` refuses before the stamp;
/// - `adoptUnusableHandleForTesting()`'s handle, `MACH_PORT_DEAD`, which is not a send right
///   to anything, so `IOConnectCallStructMethod` fails at once and no message leaves the
///   process.
///
/// Every payload sent to that handle is `0x00` anyway, the automatic direction for a mode key,
/// so that even a handle that did reach a driver would be asked for nothing but automatic.
///
/// These suites run on CI's virtual machines, which have no SMC, exactly as they run on
/// `Mac16,5`. Whether `AppleSMC` accepts the request is first seen at run 1, not here.
@Suite("SMC write body, with no SMC", .timeLimit(.minutes(1)))
private struct SMCConnectionWriteTests {

    private static let modeKey = SMCKey("F0Md")!

    /// A1: one round trip, stamped with the write's own key and selector 6, through the one
    /// site `call(_:)` brackets. The count is what shows the write reads nothing first: a
    /// `READ_KEYINFO` ahead of it would be a second round trip, or would leave its own
    /// selector, 9, as the last one begun.
    @Test("A write on the dead port is exactly one round trip, stamped with selector 6")
    func aWriteIsOneStampedRoundTripWithSelectorSix() async throws {
        let connection = SMCConnection()
        let monitor = connection.roundTrips
        await connection.adoptUnusableHandleForTesting()
        let before = monitor.issuedCount

        let error = await #expect(throws: SMCError.self) {
            try await connection.write([0x00], to: Self.modeKey)
        }

        #expect(monitor.issuedCount == before + 1, "a write is one round trip and no more")
        #expect(monitor.lastBegunOperation == .call(key: Self.modeKey.fourCharCode, selector: 6))
        #expect(monitor.inFlight() == nil, "and nothing is left in flight")
        // The kernel's refusal of the dead port, not one of SMCCore's own: the call was made.
        guard case .connectionFailed(let kernReturn) = error else {
            Issue.record("expected the kernel's refusal: \(String(describing: error))")
            return
        }
        #expect(kernReturn != kIOReturnSuccess)
        #expect(kernReturn != kIOReturnNotOpen)

        await connection.close()
    }

    /// The largest payload the field carries is accepted: the guard below is not tighter than
    /// the 32-byte field.
    @Test("A 32-byte payload is accepted and is one round trip")
    func aFullPayloadIsAccepted() async {
        let connection = SMCConnection()
        await connection.adoptUnusableHandleForTesting()

        await #expect(throws: SMCError.self) {
            try await connection.write([UInt8](repeating: 0x00, count: 32), to: Self.modeKey)
        }

        #expect(connection.roundTrips.issuedCount == 1)
        #expect(
            connection.roundTrips.lastBegunOperation
                == .call(key: Self.modeKey.fourCharCode, selector: 6))
        await connection.close()
    }

    /// A3, the empty half: refused by SMCCore's own guard before the stamp. The dead port is
    /// what makes "before any round trip" observable — without the guard this call would be
    /// stamped and refused by the kernel instead.
    @Test("An empty payload is refused before any round trip")
    func anEmptyPayloadIsRefusedBeforeAnyRoundTrip() async {
        let connection = SMCConnection()
        await connection.adoptUnusableHandleForTesting()

        await #expect(throws: SMCError.notPermitted) {
            try await connection.write([], to: Self.modeKey)
        }

        #expect(connection.roundTrips.issuedCount == 0, "nothing was stamped, so nothing was sent")
        #expect(connection.roundTrips.lastBegunOperation == nil)
        await connection.close()
    }

    /// A3, the long half. This one is made on a connection that was never opened, and the
    /// error is what is asserted. On the dead port, a payload past 32 bytes that got through
    /// the guard would stop at `Request.bytes`'s precondition — a second control, and a trap
    /// rather than an answer. Unopened, a payload that got through the guard is refused as
    /// not open instead, so `notPermitted` can only have come from the guard.
    @Test("A payload longer than 32 bytes is refused by the guard, before any round trip")
    func aLongPayloadIsRefusedBeforeAnyRoundTrip() async {
        let connection = SMCConnection()

        for count in [33, 80] {
            await #expect(throws: SMCError.notPermitted, "\(count) bytes") {
                try await connection.write([UInt8](repeating: 0x00, count: count), to: Self.modeKey)
            }
        }

        #expect(connection.roundTrips.issuedCount == 0)
    }
}

/// A2: the request `call(_:)` sends, checked byte by byte against offsets written out here,
/// not read from the code under test.
///
/// The offsets are `SMCKeyData_t`'s: key at 0, `keyInfo.dataSize` at 28, `data8` at 42,
/// `data32` at 44, `bytes` from 48, 80 bytes in all. Every read this project has made used the
/// same layout, and the reads are what `Mac16,5` has answered, so these tests also pin that a
/// read request is still laid out exactly as before. Whether `AppleSMC` accepts a *write*
/// laid out this way is first seen at run 1. Integers are in host byte order, which is
/// little-endian on every Mac this builds for, so the expected bytes are written that way.
@Suite("SMC request layout, byte by byte")
private struct SMCRequestLayoutTests {

    /// `F0Tg` is `0x46305467` (`F`, `0`, `T`, `g`); stored little-endian at offset 0.
    private static let targetKey = SMCKey("F0Tg")!
    private static let targetKeyWire: [UInt8] = [0x67, 0x54, 0x30, 0x46]

    private static func zeros() -> [UInt8] { [UInt8](repeating: 0, count: 80) }

    @Test("A write request: key at 0, dataSize at 28, 6 at 42, the payload from 48, zero elsewhere")
    func aWriteRequestIsLaidOutByteByByte() {
        let payload: [UInt8] = [0x00, 0x50, 0x9A, 0x44]
        let bytes = SMCConnection.Request.writeBytes(Self.targetKey.fourCharCode, payload: payload)
            .bytes

        #expect(bytes.count == 80)
        #expect(Array(bytes[0..<4]) == Self.targetKeyWire, "key")
        #expect(Array(bytes[28..<32]) == [0x04, 0x00, 0x00, 0x00], "dataSize: the payload length")
        #expect(bytes[42] == 6, "data8 is WRITE_BYTES")
        #expect(Array(bytes[44..<48]) == [0, 0, 0, 0], "data32 is unused by a write")
        #expect(Array(bytes[48..<52]) == payload, "the payload starts at 48")

        var expected = Self.zeros()
        expected.replaceSubrange(0..<4, with: Self.targetKeyWire)
        expected[28] = 0x04
        expected[42] = 6
        expected.replaceSubrange(48..<52, with: payload)
        #expect(bytes == expected, "and every other byte is zero")
    }

    @Test("A one-byte write's dataSize is 1, and a full one's is 32")
    func aWriteRequestsDataSizeIsItsPayloadLength() {
        let key = SMCKey("F0Md")!.fourCharCode
        let one = SMCConnection.Request.writeBytes(key, payload: [0x00]).bytes
        #expect(Array(one[28..<32]) == [0x01, 0x00, 0x00, 0x00])

        let full = SMCConnection.Request.writeBytes(
            key, payload: (1...32).map { UInt8($0) }
        ).bytes
        #expect(Array(full[28..<32]) == [0x20, 0x00, 0x00, 0x00])
        #expect(Array(full[48..<80]) == (1...32).map { UInt8($0) }, "all 32, from 48 to the end")
    }

    @Test("A READ_BYTES request is laid out as reads always were: key, dataSize, 5, nothing else")
    func aReadBytesRequestIsUnchanged() {
        let bytes = SMCConnection.Request.readBytes(Self.targetKey.fourCharCode, dataSize: 4).bytes
        var expected = Self.zeros()
        expected.replaceSubrange(0..<4, with: Self.targetKeyWire)
        expected[28] = 0x04
        expected[42] = 5
        #expect(bytes == expected)
    }

    @Test("A READ_KEYINFO request carries the key and 9, and nothing else")
    func aReadKeyInfoRequestIsUnchanged() {
        let bytes = SMCConnection.Request.readKeyInfo(Self.targetKey.fourCharCode).bytes
        var expected = Self.zeros()
        expected.replaceSubrange(0..<4, with: Self.targetKeyWire)
        expected[42] = 9
        #expect(bytes == expected)
    }

    @Test("A READ_INDEX request carries key 0, 8, and the index at 44, and nothing else")
    func aReadIndexRequestIsUnchanged() {
        let bytes = SMCConnection.Request.readIndex(0x0102_0304).bytes
        var expected = Self.zeros()
        expected[42] = 8
        expected.replaceSubrange(44..<48, with: [0x04, 0x03, 0x02, 0x01])
        #expect(bytes == expected)
    }
}

/// A5: `encode(scalar:byteOrder:)` for the two types the write plane writes, round-tripped
/// through the production decoder, `SMCValue.scalar()`, in both byte orders.
///
/// A round trip alone cannot see a byte swap made the same way in both directions, so `flt`'s
/// little-endian output is also pinned to bytes this machine produced: `F0Tg` and `F1Tg` read
/// 1350 and 1458 as raw `00c0a844` and `0040b644` on `Mac16,5` (`docs/SMC-RESEARCH.md`, the
/// sleep/wake section). Those are the key and the order the write plane targets.
@Suite("SMC key type encode, ui8 and flt")
private struct SMCKeyTypeEncodeTests {

    private static let modeKey = SMCKey("F0Md")!
    private static let targetKey = SMCKey("F0Tg")!

    @Test("ui8 encodes one byte, whatever the order, and decodes back to the same value")
    func ui8RoundTrips() throws {
        for value in [0.0, 1.0, 2.0, 255.0] {
            for order in [nil, SMCByteOrder.littleEndian, .bigEndian] {
                let bytes = try SMCKeyType.ui8.encode(scalar: value, byteOrder: order)
                #expect(bytes == [UInt8(value)])
                let decoded = try SMCValue(key: Self.modeKey, type: .ui8, bytes: bytes).scalar()
                #expect(decoded == value)
            }
        }
    }

    @Test("ui8 refuses a fraction, a value out of range, NaN and the infinities")
    func ui8RefusesWhatIsNotAByte() {
        for value in [0.5, 1.000_001, -1.0, 256.0, Double.nan, .infinity, -.infinity] {
            #expect(throws: SMCError.notPermitted, "\(value)") {
                _ = try SMCKeyType.ui8.encode(scalar: value, byteOrder: nil)
            }
        }
    }

    @Test("flt little-endian is the bytes F0Tg and F1Tg were observed holding on Mac16,5")
    func fltLittleEndianMatchesObservedBytes() throws {
        #expect(
            try SMCKeyType.flt.encode(scalar: 1350, byteOrder: .littleEndian) == [
                0x00, 0xC0, 0xA8, 0x44,
            ])
        #expect(
            try SMCKeyType.flt.encode(scalar: 1458, byteOrder: .littleEndian) == [
                0x00, 0x40, 0xB6, 0x44,
            ])
    }

    @Test("flt big-endian is the same four bytes, reversed")
    func fltBigEndianIsReversed() throws {
        #expect(
            try SMCKeyType.flt.encode(scalar: 1350, byteOrder: .bigEndian) == [
                0x44, 0xA8, 0xC0, 0x00,
            ])
    }

    @Test("flt round-trips through scalar() in both byte orders")
    func fltRoundTripsInBothOrders() throws {
        for value in [1350.0, 1458.0, 1234.5, 7826.0, 0.0, -12.25, 3.0e38] {
            for order in [SMCByteOrder.littleEndian, .bigEndian] {
                let bytes = try SMCKeyType.flt.encode(scalar: value, byteOrder: order)
                #expect(bytes.count == 4)
                let decoded = try SMCValue(
                    key: Self.targetKey, type: .flt, bytes: bytes, byteOrder: order
                ).scalar()
                #expect(decoded == Double(Float(value)), "\(value), \(order)")
            }
        }
    }

    @Test("flt refuses NaN, the infinities, and a Double past Float's range")
    func fltRefusesWhatIsNotAFiniteFloat() {
        for value in [Double.nan, .infinity, -.infinity, 1.0e39, -1.0e39] {
            for order in [SMCByteOrder.littleEndian, .bigEndian] {
                #expect(throws: SMCError.notPermitted, "\(value), \(order)") {
                    _ = try SMCKeyType.flt.encode(scalar: value, byteOrder: order)
                }
            }
        }
    }

    /// The range is the `Double`'s, judged before it converts. Just past
    /// `Float.greatestFiniteMagnitude` a value rounds down to it and is finite, so the check
    /// #431 made after the conversion let it through as less than was asked for (#433).
    @Test("flt refuses a Double just past Float's largest finite value, and encodes that value")
    func fltRefusesJustPastTheLargestFloat() throws {
        let largest = Double(Float.greatestFiniteMagnitude)
        let quarterULP = Double(Float.greatestFiniteMagnitude.ulp) / 4
        let pastTheBound = [
            largest.nextUp, largest + quarterULP, -largest.nextUp, -largest - quarterULP,
        ]
        for value in pastTheBound {
            // The premise: each converts to a finite Float, so only a check before it refuses.
            #expect(Float(value).isFinite, "\(value)")
            for order in [SMCByteOrder.littleEndian, .bigEndian] {
                #expect(throws: SMCError.notPermitted, "\(value), \(order)") {
                    _ = try SMCKeyType.flt.encode(scalar: value, byteOrder: order)
                }
            }
        }
        let accepted: [(value: Double, littleEndian: [UInt8])] = [
            (largest, [0xFF, 0xFF, 0x7F, 0x7F]), (-largest, [0xFF, 0xFF, 0x7F, 0xFF]),
        ]
        try Self.expectEncodedInBothOrders(accepted)
    }

    /// Each value's `flt` bytes: `littleEndian` in that order, and the same four reversed.
    private static func expectEncodedInBothOrders(
        _ accepted: [(value: Double, littleEndian: [UInt8])]
    ) throws {
        for (value, littleEndian) in accepted {
            #expect(
                try SMCKeyType.flt.encode(scalar: value, byteOrder: .littleEndian) == littleEndian,
                "\(value)")
            #expect(
                try SMCKeyType.flt.encode(scalar: value, byteOrder: .bigEndian)
                    == Array(littleEndian.reversed()),
                "\(value)")
        }
    }

    /// A non-zero request is never written as zero, for the reason a value past the bound is
    /// refused: the bytes would not say what was asked for. Zero itself is exact, and so is the
    /// smallest non-zero `Float`; a value that rounds to that one stays non-zero and encodes
    /// (#433). This is not rule 3's control, which is the clamp: see `encode`'s documentation.
    @Test("flt refuses a non-zero Double that underflows to zero, and encodes zero itself")
    func fltRefusesAnUnderflowToZero() throws {
        let smallest = Double(Float.leastNonzeroMagnitude)
        for value in [1e-50, -1e-50, Double.leastNonzeroMagnitude, smallest / 2, -smallest / 2] {
            // The premise: each converts to a zero Float.
            #expect(Float(value) == 0, "\(value)")
            for order in [SMCByteOrder.littleEndian, .bigEndian] {
                #expect(throws: SMCError.notPermitted, "\(value), \(order)") {
                    _ = try SMCKeyType.flt.encode(scalar: value, byteOrder: order)
                }
            }
        }
        try Self.expectEncodedInBothOrders([
            (0, [0, 0, 0, 0]), (smallest, [1, 0, 0, 0]), (-smallest, [1, 0, 0, 0x80]),
            (smallest * 0.75, [1, 0, 0, 0]),
        ])
    }

    @Test("flt with no resolved byte order is refused rather than guessed")
    func fltRefusesWithoutAByteOrder() {
        #expect(throws: SMCError.notPermitted) {
            _ = try SMCKeyType.flt.encode(scalar: 1350, byteOrder: nil)
        }
    }

    @Test("Every other type still has no encoder")
    func otherTypesAreNotImplemented() {
        for type in [SMCKeyType.fpe2, .sp78, .ui16, .ui32, .si8, .flag, .ioft, .hex] {
            #expect(throws: SMCError.encodingNotImplemented(type: type)) {
                _ = try type.encode(scalar: 1, byteOrder: .littleEndian)
            }
        }
    }
}

// swiftlint:enable force_unwrapping
