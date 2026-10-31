import Foundation
import Testing

@testable import SMCCore

/// An `SMCKey` is four bytes, each printable ASCII (U+0020 to U+007E), and nothing else
/// (#620).
///
/// The string initialiser used to check `count == 4` and `allSatisfy(\.isASCII)`. `count`
/// counts `Character`s, and `"\r\n"` is one `Character` of two bytes that is ASCII, so
/// `"ab\r\nc"` was four characters, five bytes and a key: `fourCharCode` folded all five bytes
/// into 32 bits, the first fell off the top, and the key named a code its own `rawValue` did
/// not spell. `isASCII` also admits NUL, newline and the rest of C0, and DEL.
///
/// The alphabet is the one `AeolusXPCValidation.validateSensorKey` holds a client's sensor key
/// to (#619). `SMCCore` cannot import it, so the two are mirrored and
/// `SMCKeyBoundaryAgreementTests` in `IntegrationTests` pins them equal.
@Suite("SMC key: four bytes, each printable ASCII")
struct SMCKeyByteExactTests {

    /// A key whose byte at `position` is `byte`, the others a legal filler, as a code.
    private static func code(placing byte: UInt8, at position: Int) -> FourCharCode {
        var bytes: [UInt8] = Array("Tp09".utf8)
        bytes[position] = byte
        return bytes.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
    }

    private static func string(placing byte: UInt8, at position: Int) -> String {
        var bytes: [UInt8] = Array("Tp09".utf8)
        bytes[position] = byte
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Length is bytes, not Characters

    /// Four `Character`s and five bytes, with the `\r\n` pair in each place it can sit. All
    /// four are ASCII by `Character.isASCII`, which is the whole of what the old check asked.
    ///
    /// **Mutation:** put the string initialiser back to `rawValue.count == 4,
    /// rawValue.allSatisfy(\.isASCII)`. Run: red on all four rows, here and in
    /// `SMCKeyBoundaryAgreementTests`.
    @Test(
        "Four Characters but five bytes is refused",
        arguments: ["ab\r\nc", "\r\nabc", "a\r\nbc", "abc\r\n"])
    func fourCharactersFiveBytesIsRefused(_ raw: String) {
        #expect(raw.count == 4)
        #expect(raw.utf8.count == 5)
        #expect(SMCKey(raw) == nil)
    }

    /// Anything whose byte count is not four, however the characters are counted. The rows
    /// past ASCII are refused by the alphabet whatever their length, so the rows that need
    /// the length guard are the printable ASCII ones.
    ///
    /// **Mutation:** delete the `utf8.count` guard in the string initialiser. Run: red on
    /// `""`, `T`, `Tp0`, `Tp091` and `Tp09Tp09`, and on no other row.
    @Test(
        "A string that is not four bytes long is refused",
        arguments: [
            "", "T", "Tp0", "Tp091", "Tp09Tp09",
            "\u{E9}", "Tp\u{E9}9", "\u{E9}\u{E9}\u{E9}", "\u{1F321}\u{1F321}",
        ])
    func aStringNotFourBytesLongIsRefused(_ raw: String) {
        #expect(raw.utf8.count != 4)
        #expect(SMCKey(raw) == nil)
    }

    // MARK: - The alphabet

    /// Every byte the alphabet excludes below it, and DEL, in every position. Four bytes
    /// each, so the length guard passes them and the alphabet is what refuses.
    ///
    /// **Mutation:** delete the alphabet guard in the string initialiser. Run: red on every
    /// byte here.
    @Test("A control byte or DEL anywhere in a key is refused")
    func controlBytesAreRefused() {
        let excluded = Array(UInt8(0x00)...0x1F) + [0x7F]
        for position in 0..<4 {
            for byte in excluded {
                let raw = Self.string(placing: byte, at: position)
                #expect(raw.utf8.count == 4)
                #expect(SMCKey(raw) == nil, "byte \(byte) at \(position) was admitted")
            }
        }
    }

    /// Four bytes whose scalars are outside ASCII, so the length guard admits them and only
    /// the alphabet refuses them.
    @Test(
        "A four-byte key past ASCII is refused",
        arguments: ["\u{E9}\u{E9}", "T\u{E9}0", "\u{1F321}"])
    func aFourByteNonASCIIKeyIsRefused(_ raw: String) {
        #expect(raw.utf8.count == 4)
        #expect(SMCKey(raw) == nil)
    }

    /// Every byte in the alphabet, in every position, builds a key that is four bytes and
    /// four `Character`s, spells what it was given, and survives the code and back.
    ///
    /// Space is in it, because `FS! ` has one. That a legal key's `Character` count is also
    /// four is what makes the old and new checks agree on every key a real SMC has.
    ///
    /// **Mutation:** narrow the lower bound of `permittedBytes` to `0x21`. Run: red at every
    /// position, on the space.
    @Test("Every printable ASCII byte is accepted in every position and round-trips")
    func printableASCIIRoundTrips() throws {
        for position in 0..<4 {
            for byte in UInt8(0x20)...0x7E {
                let raw = Self.string(placing: byte, at: position)
                let key = try #require(SMCKey(raw), "byte \(byte) at \(position) was refused")
                #expect(key.rawValue == raw)
                #expect(key.rawValue.utf8.count == 4)
                #expect(key.rawValue.count == 4)
                #expect(key.fourCharCode == Self.code(placing: byte, at: position))
                #expect(SMCKey(fourCharCode: key.fourCharCode) == key)
            }
        }
    }

    // MARK: - init?(fourCharCode:)

    /// Firmware data. A byte outside the alphabet, in any of the four places, is refused
    /// rather than decoded: control bytes used to be admitted, and a byte past ASCII became
    /// part of a replacement character.
    ///
    /// **Mutation:** delete the byte guard in `init?(fourCharCode:)`. Run: red on every
    /// excluded byte.
    @Test("A code with a byte outside the alphabet is refused, in every position")
    func codeWithAnExcludedByteIsRefused() {
        for position in 0..<4 {
            for byte in UInt8.min...UInt8.max {
                let key = SMCKey(fourCharCode: Self.code(placing: byte, at: position))
                let inAlphabet = (0x20...0x7E).contains(byte)
                #expect((key != nil) == inAlphabet, "byte \(byte) at \(position)")
            }
        }
    }

    /// A deterministic spread of codes, built from alphabet bytes so that most are accepted,
    /// and each one a round trip through both initialisers and `fourCharCode`.
    @Test("An accepted code round-trips through rawValue and back")
    func acceptedCodesRoundTrip() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        for _ in 0..<20_000 {
            let bytes = (0..<4).map { _ in UInt8(0x20 + next() % 95) }
            let code = bytes.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }

            let key = try #require(SMCKey(fourCharCode: code), "\(bytes)")
            #expect(key.fourCharCode == code)
            #expect(key.rawValue == String(decoding: bytes, as: UTF8.self))
            #expect(SMCKey(key.rawValue) == key)
        }
    }

    /// Any 32 bits at all. The code is accepted exactly when all four bytes are in the
    /// alphabet, and then it is the key's own code.
    @Test("Arbitrary codes are accepted exactly when every byte is in the alphabet")
    func arbitraryCodesAreAcceptedExactlyWhenInAlphabet() {
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        func next() -> UInt32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt32(truncatingIfNeeded: state >> 32)
        }
        for _ in 0..<20_000 {
            let code = next()
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            let inAlphabet = bytes.allSatisfy { (0x20...0x7E).contains($0) }
            let key = SMCKey(fourCharCode: code)
            #expect((key != nil) == inAlphabet, "\(String(code, radix: 16))")
            if let key {
                #expect(key.fourCharCode == code)
            }
        }
    }

    // MARK: - What the project builds by name

    @Test("Every named constant constructs, is four bytes, and round-trips")
    func namedConstantsConstruct() {
        let named: [(SMCKey, String)] = [
            (.keyCount, "#KEY"), (.fanCount, "FNum"), (.fanForceBitmask, "FS! "),
            (.forceTest, "Ftst"),
        ]
        for (key, spelling) in named {
            #expect(key.rawValue == spelling)
            #expect(key.rawValue.utf8.count == 4)
            #expect(SMCKey(spelling) == key)
            #expect(SMCKey(fourCharCode: key.fourCharCode) == key)
        }
    }

    /// `F<n>…` is four bytes for `n` of 0 to 9, and five from 10, which is refused by length
    /// and not by a narrowing of this change: `FanEnumeration` documents that behaviour.
    @Test("The per-fan keys construct for one-digit fan indexes and for no other")
    func perFanKeysConstructForOneDigitIndexes() {
        for index in 0...9 {
            let keys = [
                SMCKey.fanActualRPM(index), .fanTargetRPM(index), .fanMinimumRPM(index),
                .fanMaximumRPM(index), .fanMode(index),
            ]
            for key in keys {
                #expect(key != nil, "fan \(index)")
                #expect(key.flatMap { SMCKey(fourCharCode: $0.fourCharCode) } == key)
            }
        }
        for index in [10, 64, -1] {
            #expect(SMCKey.fanActualRPM(index) == nil, "fan \(index)")
        }
    }
}

/// Facts about the keys this project's sole verified machine, `Mac16,5`, holds: all of them
/// are inside the alphabet, so narrowing it dropped none from enumeration. Read-only.
///
/// Gated as `SMCConnectionHardwareTests` is, and for the reason `DevelopmentMachine.swift`
/// gives: this is a fact about `Mac16,5`'s table, and a contributor's other Mac gets a skip.
@Suite(
    "SMC key alphabet against the real key table",
    .enabled(if: SMCConnection.isHardwareAvailable() && isDevelopmentMachine())
)
struct SMCKeyRealTableTests {

    /// Every index of the table is walked, each key is four printable ASCII bytes, and each
    /// one is the key its own code names. `key(at:)` throws `malformedKeyCode` for a code the
    /// alphabet refuses, so a key it narrowed away would fail here by name.
    @Test("Every key this machine enumerates is in the alphabet and round-trips")
    func everyEnumeratedKeyIsInTheAlphabet() async throws {
        let connection = SMCConnection()
        try await connection.open()
        defer { Task { await connection.close() } }

        let count = try await connection.keyCount()
        #expect(count > 1000)
        for index in 0..<count {
            let key = try await connection.key(at: index)
            let bytes = Array(key.rawValue.utf8)
            #expect(bytes.count == 4, "index \(index)")
            #expect(bytes.allSatisfy { (0x20...0x7E).contains($0) }, "index \(index)")
            #expect(SMCKey(fourCharCode: key.fourCharCode) == key, "index \(index)")
        }
    }
}
