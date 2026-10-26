import Foundation
import Testing

@testable import SMCCore

/// `SMCConnection.decodeKeyCount(value:)` is everything `keyCount()` does after its
/// one `READ_BYTES`. `SMCConnection` has no scripted transport, so this is the seam that lets a
/// test hand `#KEY` a value no real Mac has produced, the same way
/// `SMCConnectionKeyCountFallbackTests` drives `decodeKeyCountFallback(value:)`.
///
/// The firmware declares `#KEY`'s type, and `scalar()` decodes whatever it declares. Before
/// #397 the result went through `Int(_: Double)`, which traps on NaN, on ±infinity and on any
/// magnitude of 2^63 or more. A trap there would kill the root helper and `fanctl` on a firmware
/// value, before `validatePlausibleKeyCount(_:)` could refuse it. A trap in this suite ends the
/// test process, which is a red run.
@Suite("SMC #KEY decode never traps on a value that does not fit an Int")
struct SMCConnectionKeyCountDecodeTests {

    /// One scripted `#KEY` reply: the declared type, the raw bytes in big-endian order, and the
    /// scalar those bytes decode to. The scalar is checked before the refusal is asserted, so a
    /// fixture that stopped producing its hostile value would fail here instead of passing
    /// for the wrong reason.
    struct Reply: Sendable, CustomTestStringConvertible {
        let name: String
        let type: SMCKeyType
        let bytes: [UInt8]
        let decodesTo: Double

        var testDescription: String { name }

        var value: SMCValue {
            SMCValue(key: SMCKey.keyCount, type: type, bytes: bytes, byteOrder: .bigEndian)
        }

        /// Whether `scalar` is the value this fixture claims to produce. NaN is compared by
        /// kind, since `.nan == .nan` is false.
        func isDecodedValue(_ scalar: Double?) -> Bool {
            guard let scalar else { return false }
            return decodesTo.isNaN ? scalar.isNaN : scalar == decodesTo
        }
    }

    /// 2^63, one past `Int.max`. `Double(Int.max)` rounds up to exactly this value.
    static let twoToThe63: Double = 9_223_372_036_854_775_808

    /// Every value here would have trapped `Int(_: Double)`, or, for the fraction, been
    /// silently truncated by it. `flt` can carry all of them, and a fixed-point type the
    /// fraction (`fpe2` here). Among the other declared types
    /// only `ui64` and `si64` can reach 2^63: `ioft` tops out near 2.8e14, and the narrower
    /// integers and fixed-point types are far smaller still.
    static let unrepresentable: [Reply] = [
        Reply(name: "flt NaN", type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00], decodesTo: .nan),
        Reply(
            name: "flt +infinity", type: .flt, bytes: [0x7F, 0x80, 0x00, 0x00],
            decodesTo: .infinity),
        Reply(
            name: "flt -infinity", type: .flt, bytes: [0xFF, 0x80, 0x00, 0x00],
            decodesTo: -.infinity),
        Reply(
            name: "flt 2^63", type: .flt, bytes: [0x5F, 0x00, 0x00, 0x00],
            decodesTo: twoToThe63),
        Reply(
            name: "flt greatest finite magnitude", type: .flt, bytes: [0x7F, 0x7F, 0xFF, 0xFF],
            decodesTo: Double(Float.greatestFiniteMagnitude)),
        Reply(
            name: "flt -2^64, below Int.min", type: .flt, bytes: [0xDF, 0x80, 0x00, 0x00],
            decodesTo: -2 * twoToThe63),
        Reply(
            name: "flt 3385.5, a fraction", type: .flt, bytes: [0x45, 0x53, 0x98, 0x00],
            decodesTo: 3385.5),
        // fpe2 is unsigned 14.2 fixed point: 0x34E5 is 13541, a quarter of which is 3385.25.
        Reply(
            name: "fpe2 3385.25, a fixed-point fraction", type: .fpe2, bytes: [0x34, 0xE5],
            decodesTo: 3385.25),
        Reply(
            name: "ui64 2^63", type: .ui64,
            bytes: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], decodesTo: twoToThe63),
        // 2^63 − 512 is the smallest value Double rounds up to 2^63: it sits exactly halfway
        // between 2^63 − 1024 and 2^63, and the tie goes to 2^63, whose significand is even.
        // `representableEdges` holds the value one below it.
        Reply(
            name: "ui64 2^63 − 512, the smallest value that rounds up to 2^63", type: .ui64,
            bytes: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0x00], decodesTo: twoToThe63),
        Reply(
            name: "ui64 max", type: .ui64,
            bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], decodesTo: 2 * twoToThe63),
        // Int64.max fits an Int, but it is decoded through Double, which rounds the 512
        // largest si64 values up to 2^63. That is how an si64 reaches past Int.max.
        Reply(
            name: "si64 Int64.max, which rounds to 2^63", type: .si64,
            bytes: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], decodesTo: twoToThe63),
    ]

    @Test(
        "A #KEY value that is not a whole number within Int's range is refused with a typed error",
        arguments: unrepresentable)
    func unrepresentableValueIsRefused(_ reply: Reply) throws {
        #expect(reply.isDecodedValue(try reply.value.scalar()))
        #expect(
            throws: SMCError.unrepresentableKeyCount(type: reply.type, bytes: reply.bytes)
        ) {
            _ = try SMCConnection.decodeKeyCount(value: reply.value)
        }
    }

    /// -1 fits an `Int`, so it converts and reaches `validatePlausibleKeyCount(_:)`, which
    /// refuses it. Each of these types can declare -1. The assertion names the plausibility
    /// error, so a conversion guard that swallowed negatives would turn this red.
    static let minusOne: [Reply] = [
        Reply(name: "si32 -1", type: .si32, bytes: [0xFF, 0xFF, 0xFF, 0xFF], decodesTo: -1),
        Reply(
            name: "si64 -1", type: .si64,
            bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], decodesTo: -1),
        Reply(name: "flt -1", type: .flt, bytes: [0xBF, 0x80, 0x00, 0x00], decodesTo: -1),
    ]

    @Test("A #KEY of -1 converts, then the plausibility bound refuses it", arguments: minusOne)
    func minusOneReachesThePlausibilityBound(_ reply: Reply) throws {
        #expect(reply.isDecodedValue(try reply.value.scalar()))
        #expect(throws: SMCError.implausibleKeyCount(declared: -1)) {
            _ = try SMCConnection.decodeKeyCount(value: reply.value)
        }
    }

    /// One scripted reply that converts to a whole `Int`, and the `Int` it must convert to.
    /// `declared` is written out as a literal, not derived from `reply.decodesTo`, so the
    /// assertion does not compare a number to itself.
    struct Edge: Sendable, CustomTestStringConvertible {
        let reply: Reply
        let declared: Int

        var testDescription: String { reply.name }
    }

    /// 2^63 − 1024, the largest `Double` below 2^63, and so the largest value
    /// `Int(exactly:)` can return from a decoded scalar. `Int.max` itself has no `Double`.
    static let largestDoubleBelowTwoToThe63: Double = 9_223_372_036_854_774_784

    /// The representable side of both edges of `Int`'s range. Each converts to a whole `Int`,
    /// so it must reach `validatePlausibleKeyCount(_:)` and be refused there as
    /// `implausibleKeyCount`, carrying the converted value, never as
    /// `unrepresentableKeyCount`. A conversion guard written one step too tight at either end
    /// would refuse these as unrepresentable, and these turn red on the error's case.
    static let representableEdges: [Edge] = [
        // −2^63 is Int.min exactly, and a Double holds it exactly.
        Edge(
            reply: Reply(
                name: "si64 Int64.min, −2^63 exactly", type: .si64,
                bytes: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], decodesTo: -twoToThe63),
            declared: Int.min),
        Edge(
            reply: Reply(
                name: "flt −2^63 exactly", type: .flt, bytes: [0xDF, 0x00, 0x00, 0x00],
                decodesTo: -twoToThe63),
            declared: Int.min),
        // 2^63 − 513 is the largest ui64 that stays below 2^63 through Double: it is 511 from
        // 2^63 − 1024 and 513 from 2^63, so it rounds down.
        Edge(
            reply: Reply(
                name: "ui64 2^63 − 513, which rounds down to 2^63 − 1024", type: .ui64,
                bytes: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD, 0xFF],
                decodesTo: largestDoubleBelowTwoToThe63),
            declared: 9_223_372_036_854_774_784),
        Edge(
            reply: Reply(
                name: "si64 2^63 − 513, which rounds down to 2^63 − 1024", type: .si64,
                bytes: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD, 0xFF],
                decodesTo: largestDoubleBelowTwoToThe63),
            declared: 9_223_372_036_854_774_784),
    ]

    @Test(
        "A #KEY at either representable edge of Int converts and is refused as implausible",
        arguments: representableEdges)
    func representableEdgeReachesThePlausibilityBound(_ edge: Edge) throws {
        #expect(edge.reply.isDecodedValue(try edge.reply.value.scalar()))
        #expect(throws: SMCError.implausibleKeyCount(declared: edge.declared)) {
            _ = try SMCConnection.decodeKeyCount(value: edge.reply.value)
        }
    }

    /// A non-numeric declared type has no count in it, and that is the error, whether or not
    /// the byte order was resolved. Each type appears twice, once with an order and once
    /// without: before #531 both reported `integerByteOrderUndetectable`, which `fanctl`
    /// describes as "SMC interface generation unknown". The bytes are `#KEY`'s own
    /// `Mac16,5` bytes, so a decode that ignored the declared type would find a count in them.
    static let nonNumeric: [SMCValue] = [SMCKeyType.hex, .ch8, .unknown(0x7A7A_7A7A)]
        .flatMap { type in
            [SMCByteOrder.bigEndian, nil].map { order in
                SMCValue(
                    key: SMCKey.keyCount, type: type, bytes: [0x00, 0x00, 0x0D, 0x39],
                    byteOrder: order)
            }
        }

    @Test(
        "A #KEY declaring a non-numeric type is refused as non-numeric, whatever its byte order",
        arguments: nonNumeric)
    func nonNumericTypeIsRefusedAsNonNumeric(_ value: SMCValue) {
        #expect(!value.type.isNumeric)
        #expect(
            throws: SMCError.nonNumericKeyCount(type: value.type, bytes: [0x00, 0x00, 0x0D, 0x39])
        ) {
            _ = try SMCConnection.decodeKeyCount(value: value)
        }
    }

    /// The other side of the refusal: a real count still decodes. Without this, a conversion
    /// that refused every value would pass the two tests above.
    static let wholeCounts: [Reply] = [
        Reply(
            name: "ui32 3385, Mac16,5's own #KEY", type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39],
            decodesTo: 3385),
        Reply(name: "flt 3385", type: .flt, bytes: [0x45, 0x53, 0x90, 0x00], decodesTo: 3385),
        Reply(
            name: "ui64 3385", type: .ui64,
            bytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0D, 0x39], decodesTo: 3385),
    ]

    @Test("A whole, plausible #KEY value still decodes", arguments: wholeCounts)
    func wholeCountDecodes(_ reply: Reply) throws {
        #expect(reply.isDecodedValue(try reply.value.scalar()))
        #expect(try SMCConnection.decodeKeyCount(value: reply.value) == 3385)
    }

    /// The generation-undetermined branch moved into the same function, so it is pinned here
    /// too: with no byte order, `scalar()` declines and the `ui32` fallback answers. An unknown
    /// generation reaches this function only as `byteOrder == nil`, which `read(_:)` sets.
    /// `SMCConnectionKeyCountGenerationFlowTests` pins part of that route; #539 records the
    /// part nothing pins.
    @Test("With no generation, a ui32 #KEY still decodes through the big-endian fallback")
    func undeterminedGenerationUsesTheFallback() throws {
        let value = SMCValue(
            key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39], byteOrder: nil)
        #expect(try SMCConnection.decodeKeyCount(value: value) == 3385)
    }

    @Test("With no generation and no fallback for the declared type, the decode refuses")
    func undeterminedGenerationWithoutFallbackRefuses() {
        let value = SMCValue(
            key: SMCKey.keyCount, type: .flt, bytes: [0x45, 0x53, 0x90, 0x00], byteOrder: nil)
        #expect(throws: SMCError.integerByteOrderUndetectable(key: SMCKey.keyCount)) {
            _ = try SMCConnection.decodeKeyCount(value: value)
        }
    }
}
