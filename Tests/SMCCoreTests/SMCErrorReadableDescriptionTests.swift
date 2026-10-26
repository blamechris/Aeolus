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
