import SMCCore
import Testing

// swiftlint:disable force_unwrapping

/// `SMCError.readableDescription` must never hand back the default `String(describing:)` dump
/// of an `SMCError` case, and must never be a bare stack trace — every case gets a
/// human-readable, specific message. Pure and synchronous.
///
/// Moved here from `fanctlTests` by #536, with the wording it tests. It was `fanctl`'s
/// `describeSMCError(_:)`, which `SMCCore` could not call, so `SMCCore`'s own per-key and
/// `FNum` failures printed the raw case. Imported without `@testable`: `fanctl` and the app
/// call this, so it has to be public.
@Suite("SMCCore — SMC error descriptions")
struct SMCErrorReadableDescriptionTests {

    @Test("notReadable names the key and the attribute bit, not just the enum case")
    func notReadableIsSpecific() {
        let key = SMCKey("AC-E")!
        let description = SMCError.notReadable(key).readableDescription
        #expect(description.contains("AC-E"))
        #expect(description.contains("0x80"))
    }

    /// `notPermitted` is SMCCore refusing by its own rule before any round trip, an empty or
    /// oversized write or a value its type cannot hold. It said "this connection has no write
    /// access" while the write had no body, which a reader would take as a reason to retry as
    /// root (#433).
    @Test("notPermitted says it was refused before any round trip, not that access was missing")
    func notPermittedSaysNothingWasSent() {
        let description = SMCError.notPermitted.readableDescription
        #expect(description.contains("before any round trip"))
        #expect(!description.contains("access"))
    }

    @Test("firmware includes the SMC result code as hex")
    func firmwareIncludesResultCode() {
        let description = SMCError.firmware(code: 0x82).readableDescription
        #expect(description.contains("0x82"))
    }

    @Test("valueTooLargeForSingleRead names the key and the declared size")
    func oversizedIsSpecific() {
        let key = SMCKey("ATP0")!
        let description = SMCError.valueTooLargeForSingleRead(key: key, dataSize: 96)
            .readableDescription
        #expect(description.contains("ATP0"))
        #expect(description.contains("96"))
    }

    @Test("unrepresentableKeyCount names the declared type and the raw bytes")
    func unrepresentableKeyCountIsSpecific() {
        let description = SMCError.unrepresentableKeyCount(
            type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00]
        ).readableDescription
        #expect(description.contains("#KEY"))
        #expect(description.contains("flt"))
        #expect(description.contains("7fc00000"))
    }

    /// Before #531 a non-numeric `#KEY` threw `integerByteOrderUndetectable` even when the
    /// generation was known, and it was described as "SMC interface generation unknown". The
    /// description must name the declared type, say that it is not numeric, and say nothing
    /// about the generation, which has nothing to do with it.
    @Test("nonNumericKeyCount names the declared type as non-numeric, not the generation")
    func nonNumericKeyCountIsSpecific() {
        let description = SMCError.nonNumericKeyCount(
            type: .hex, bytes: [0x00, 0x00, 0x0D, 0x39]
        ).readableDescription
        #expect(description.contains("#KEY"))
        #expect(description.contains("hex_"))
        #expect(description.contains("00000d39"))
        #expect(description.contains("not a numeric type"))
        #expect(!description.contains("generation"))
    }

    /// The wording `integerByteOrderUndetectable` shares with `SMCSensorProvider`'s per-key
    /// failure for an unresolved byte order. Pinned exactly, so a change to the shared phrase
    /// shows up here as well as in the provider's test.
    @Test("integerByteOrderUndetectable names the key and the unknown generation")
    func byteOrderUndetectableIsSpecific() {
        let description = SMCError.integerByteOrderUndetectable(key: SMCKey("#KEY")!)
            .readableDescription
        #expect(description == "#KEY byte order undetectable (SMC interface generation unknown)")
    }

    // MARK: - A type code padded to four characters (#544)

    /// `flt `, `ui8 ` and `si8 ` are three-character codes the SMC pads to four with a space.
    /// Named in a sentence, the padding put a second space after the type: "F0Ac declares
    /// flt  but returned 2 bytes". Pinned exactly, one case per description that names a type.
    @Test("A padded type code is named without its padding")
    func paddedTypeCodeIsNamedWithoutPadding() {
        let key = SMCKey("F0Ac")!
        #expect(
            SMCError.sizeMismatch(key: key, declared: .flt, reportedBytes: 2).readableDescription
                == "F0Ac declares flt but returned 2 bytes")
        #expect(
            SMCError.encodingFailed(key: key, type: .ui8).readableDescription
                == "F0Ac (ui8) value could not be encoded")
        #expect(
            SMCError.encodingNotImplemented(type: .si8).readableDescription
                == "no encoder implemented yet for si8")
        #expect(
            SMCError.unrepresentableKeyCount(type: .flt, bytes: [0x7F, 0xC0, 0x00, 0x00])
                .readableDescription
                == "#KEY (flt, raw bytes 7fc00000) did not decode to a whole number within "
                + "Int's range")
        #expect(
            SMCError.nonNumericKeyCount(type: .unknown(0x6162_2020), bytes: [0x00, 0x0D])
                .readableDescription
                == "#KEY declares ab (raw bytes 000d), which is not a numeric type, so it "
                + "holds no key count")
    }

    /// The same rule as a property, over every description that names a type: no run of two
    /// spaces and no trailing space, for each padded code `SMCKeyType` knows and for an
    /// unrecognised code padded by two.
    @Test(
        "No description that names a padded type has a double or trailing space",
        arguments: [SMCKeyType.flt, .ui8, .si8, .unknown(0x6162_2020)])
    func noDoubleSpaceAfterAPaddedType(type: SMCKeyType) {
        let key = SMCKey("F0Ac")!
        let naming: [SMCError] = [
            .sizeMismatch(key: key, declared: type, reportedBytes: 2),
            .encodingFailed(key: key, type: type),
            .encodingNotImplemented(type: type),
            .unrepresentableKeyCount(type: type, bytes: [0x00]),
            .nonNumericKeyCount(type: type, bytes: [0x00]),
        ]
        for error in naming {
            let description = error.readableDescription
            #expect(!description.contains("  "), "\(description)")
            #expect(!description.hasSuffix(" "), "\(description)")
        }
    }

    /// A code that is nothing but padding has no name to trim down to. It is shown as the
    /// firmware declared it, so the text still carries what the SMC sent rather than nothing.
    @Test("A type code that is all spaces is shown as declared, not trimmed away")
    func blankTypeCodeIsShownAsDeclared() {
        #expect(
            SMCError.encodingNotImplemented(type: .unknown(0x2020_2020)).readableDescription
                == "no encoder implemented yet for     ")
    }

    /// The switch inside `readableDescription` is exhaustive over `SMCError` with no
    /// `default:` arm, so a missing case does not build. What this test adds is what the
    /// compiler cannot check: every case produces a non-empty string, and none of them is the
    /// enum-case dump this property exists to replace.
    @Test("Every SMCError case is described in words, never as its enum-case dump")
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
            #expect(!error.readableDescription.isEmpty)
            #expect(error.readableDescription != String(describing: error))
        }
    }

    @Test("readableDescription(of:) describes an SMCError held as any Error in words")
    func anyErrorThatIsAnSMCErrorIsDescribed() {
        let error: any Error = SMCError.connectionFailed(kernReturn: -536_870_212)
        #expect(
            SMCError.readableDescription(of: error)
                == "connection to AppleSMC failed (kernel result -536870212)")
    }

    @Test("A non-SMCError falls back to its own description rather than crashing")
    func nonSMCErrorFallsBackGracefully() {
        struct OtherError: Error, CustomStringConvertible {
            var description: String { "the other provider's own words" }
        }
        #expect(SMCError.readableDescription(of: OtherError()) == "the other provider's own words")
    }
}

// swiftlint:enable force_unwrapping
