import Testing

@testable import SMCCore
@testable import fanctl

// swiftlint:disable force_unwrapping

/// `describeSMCError(_:)` must never hand back the default `String(describing:)` dump of
/// an `SMCError` case, and must never be a bare stack trace — every case gets a
/// human-readable, specific message. Pure and synchronous.
///
/// Moved here from `DumpCommandTests.swift` when #531 made the describer `dump`'s and
/// `sensors`' shared one; it was `describeDumpError(_:)` before.
@Suite("fanctl — SMC error descriptions")
struct SMCErrorDescriptionTests {

    @Test("notReadable names the key and the attribute bit, not just the enum case")
    func notReadableIsSpecific() {
        let key = SMCKey("AC-E")!
        let description = describeSMCError(SMCError.notReadable(key))
        #expect(description.contains("AC-E"))
        #expect(description.contains("0x80"))
    }

    @Test("firmware includes the SMC result code as hex")
    func firmwareIncludesResultCode() {
        let description = describeSMCError(SMCError.firmware(code: 0x82))
        #expect(description.contains("0x82"))
    }

    @Test("valueTooLargeForSingleRead names the key and the declared size")
    func oversizedIsSpecific() {
        let key = SMCKey("ATP0")!
        let description = describeSMCError(
            SMCError.valueTooLargeForSingleRead(key: key, dataSize: 96))
        #expect(description.contains("ATP0"))
        #expect(description.contains("96"))
    }

    @Test("unrepresentableKeyCount names the declared type and the raw bytes")
    func unrepresentableKeyCountIsSpecific() {
        let description = describeSMCError(
            SMCError.unrepresentableKeyCount(type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00]))
        #expect(description.contains("#KEY"))
        #expect(description.contains("flt"))
        #expect(description.contains("7fc00000"))
    }

    /// Before #531 a non-numeric `#KEY` threw `integerByteOrderUndetectable` even when the
    /// generation was known, and this function described it as "SMC interface generation
    /// unknown". The description must name the declared type, say that it is not numeric,
    /// and say nothing about the generation, which has nothing to do with it.
    @Test("nonNumericKeyCount names the declared type as non-numeric, not the generation")
    func nonNumericKeyCountIsSpecific() {
        let description = describeSMCError(
            SMCError.nonNumericKeyCount(type: .hex, bytes: [0x00, 0x00, 0x0D, 0x39]))
        #expect(description.contains("#KEY"))
        #expect(description.contains("hex_"))
        #expect(description.contains("00000d39"))
        #expect(description.contains("not a numeric type"))
        #expect(!description.contains("generation"))
    }

    /// Every case in the switch inside `describeSMCError(_:)` is exhaustive over
    /// `SMCError` at compile time — if a case were missing, this file would not build.
    /// What this test adds is the runtime guarantee the compiler cannot: every case
    /// actually produces a non-empty, readable string rather than an empty fallthrough.
    @Test("Every SMCError case produces a non-empty description")
    func everyCaseIsHandled() {
        let key = SMCKey("F0Ac")!
        let cases: [SMCError] = [
            .connectionFailed(kernReturn: -1),
            .keyNotFound(key),
            .firmware(code: 0x00),
            .sizeMismatch(key: key, declared: .flt, reportedBytes: 2),
            .invalidFlagValue(key: key, byte: 0x02),
            .encodingFailed(key: key, type: .flt),
            .encodingNotImplemented(type: .flt),
            .notPermitted,
            .notReadable(key),
            .valueTooLargeForSingleRead(key: key, dataSize: 96),
            .malformedKeyCode(0),
            .invalidIndex(-1),
            .truncatedReply(expected: 80, received: 40),
            .integerByteOrderUndetectable(key: key),
            .implausibleKeyCount(declared: 957_153_280),
            .unrepresentableKeyCount(type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00]),
            .nonNumericKeyCount(type: .hex, bytes: [0x00, 0x00, 0x0D, 0x39]),
        ]
        for error in cases {
            #expect(!describeSMCError(error).isEmpty)
        }
    }

    @Test("A non-SMCError still produces a description rather than crashing")
    func nonSMCErrorFallsBackGracefully() {
        struct OtherError: Error {}
        #expect(!describeSMCError(OtherError()).isEmpty)
    }
}

// swiftlint:enable force_unwrapping
