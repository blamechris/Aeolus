import Foundation
import Testing

@testable import SMCCore

/// `SMCConnection.decodeKeyCount(value:generation:)` is everything `keyCount()` does after its
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
    /// silently truncated by it. `flt` can carry all of them. Among the other declared types
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
        Reply(
            name: "ui64 2^63", type: .ui64,
            bytes: [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], decodesTo: twoToThe63),
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
            _ = try SMCConnection.decodeKeyCount(value: reply.value, generation: .modern)
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
            _ = try SMCConnection.decodeKeyCount(value: reply.value, generation: .modern)
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
        #expect(try SMCConnection.decodeKeyCount(value: reply.value, generation: .modern) == 3385)
    }

    /// The generation-undetermined branch moved into the same function, so it is pinned here
    /// too: with no byte order, `scalar()` declines and the `ui32` fallback answers.
    @Test("With no generation, a ui32 #KEY still decodes through the big-endian fallback")
    func undeterminedGenerationUsesTheFallback() throws {
        let value = SMCValue(
            key: SMCKey.keyCount, type: .ui32, bytes: [0x00, 0x00, 0x0D, 0x39], byteOrder: nil)
        #expect(try SMCConnection.decodeKeyCount(value: value, generation: nil) == 3385)
    }

    @Test("With no generation and no fallback for the declared type, the decode refuses")
    func undeterminedGenerationWithoutFallbackRefuses() {
        let value = SMCValue(
            key: SMCKey.keyCount, type: .flt, bytes: [0x45, 0x53, 0x90, 0x00], byteOrder: nil)
        #expect(throws: SMCError.integerByteOrderUndetectable(key: SMCKey.keyCount)) {
            _ = try SMCConnection.decodeKeyCount(value: value, generation: nil)
        }
    }
}
