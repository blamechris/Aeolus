import SMCCore
import Testing

@testable import AeolusHelper

/// What the hardware prints that feed `docs/SMC-RESEARCH.md` say about `F<n>Md`
/// ([#208](https://github.com/blamechris/Aeolus/issues/208)).
///
/// The hardware tests that print these lines are gated on `Mac16,5` and skipped on CI, so the
/// *rendering* is tested here over constructed `SMCValue`s, where it runs everywhere. What
/// these tests exist to refuse is the old print: `state.mode == .automatic ? 0 : 1`, which
/// turned every non-zero byte into the digit `1` and was then transcribed as a register
/// value. A rendering that folded would print `0x01` for a `0x02` byte, which is the case
/// `aNonZeroByteIsPrintedAsItself` pins on five different bytes.
@Suite("The raw F<n>Md recording")
struct RawFanModeReadingTests {

    private static func reading(
        fan: Int = 0, type: SMCKeyType = .ui8, bytes: [UInt8], byteOrder: SMCByteOrder? = nil
    ) throws -> RawFanModeReading {
        let key = try #require(SMCKey.fanMode(fan))
        return RawFanModeReading(
            fan: fan,
            outcome: .read(SMCValue(key: key, type: type, bytes: bytes, byteOrder: byteOrder)))
    }

    private static func unreadable(_ reason: String) -> RawFanModeReading {
        RawFanModeReading(fan: 0, outcome: .unreadable(reason: reason))
    }

    @Test("A zero byte is printed as the byte, beside the automatic decode")
    func aZeroByteIsPrintedAsTheByte() throws {
        let zero = try Self.reading(bytes: [0x00])

        #expect(zero.rawDescription == "ui8 0x00")
        #expect(zero.entry(decodedAutomatic: true) == "F0Md raw ui8 0x00; decoded automatic")
    }

    /// The test the fold fails. `FirmwareFanMode` maps all of these to `.manual`, so a print
    /// built from it shows the same thing five times; a print of the bytes shows five
    /// different ones. Each case also asserts the *other* digits are absent from the raw
    /// part, so `0x01` cannot satisfy a `0x02` case by being a substring of something else.
    @Test(
        "A non-zero byte is printed as itself, never as 1",
        arguments: [
            (UInt8(0x01), "0x01"), (UInt8(0x02), "0x02"), (UInt8(0x03), "0x03"),
            (UInt8(0x80), "0x80"), (UInt8(0xff), "0xff"),
        ])
    func aNonZeroByteIsPrintedAsItself(byte: UInt8, hex: String) throws {
        let held = try Self.reading(bytes: [byte])
        let line = held.entry(decodedAutomatic: false)

        #expect(held.rawDescription == "ui8 \(hex)")
        #expect(line == "F0Md raw ui8 \(hex); decoded manual (non-zero)")
        // The decoded side says "non-zero", and says nothing about which value.
        #expect(!line.contains("decoded manual (1)") && !line.contains("=1"))
    }

    @Test("A key that could not be read is never printed as a zero byte")
    func anUnreadableKeyIsNotAZero() {
        let failed = Self.unreadable("firmware: 0x82")

        #expect(failed.rawDescription == "unreadable (firmware: 0x82)")
        #expect(!failed.rawDescription.contains("0x00"))
        // Decoded `manual` needs no caveat: a failed raw read cannot contradict it, and the
        // production read that said so did read something.
        #expect(
            failed.entry(decodedAutomatic: false)
                == "F0Md raw unreadable (firmware: 0x82); decoded manual (non-zero)")
    }

    /// #178: the snapshot folds an unreadable mode key into `.automatic`. The raw read is the
    /// one that can tell that case from "firmware declared 0", so when it is the one that
    /// failed, the line has to say the `automatic` beside it has nothing behind it but the
    /// production read.
    @Test("An unreadable raw read beside a decoded automatic says what that automatic rests on")
    func anUnreadableRawReadQualifiesTheAutomatic() {
        let line = Self.unreadable("no outcome").entry(decodedAutomatic: true)

        #expect(line.contains("raw unreadable (no outcome); decoded automatic"))
        #expect(line.contains("rests on the production read alone"))
    }

    @Test(
        "Two reads that fold differently are reported as a disagreement, not reconciled",
        arguments: [
            (UInt8(0x02), true, true), (UInt8(0x00), false, true),
            (UInt8(0x00), true, false), (UInt8(0x02), false, false),
        ])
    func disagreementIsReported(byte: UInt8, decodedAutomatic: Bool, disagrees: Bool) throws {
        let line = try Self.reading(bytes: [byte]).entry(decodedAutomatic: decodedAutomatic)

        #expect(line.contains("DISAGREE") == disagrees)
        // Either way, the raw byte is still printed as read.
        #expect(line.contains(String(format: "0x%02x", byte)))
    }

    @Test("A multi-byte or non-ui8 payload is printed whole, and makes no fold claim")
    func aWiderPayloadIsPrintedWhole() throws {
        // `byteOrder` is nil, so `scalar()` refuses to decode a `ui16`. The recording must
        // still show every byte, and must not invent a disagreement from a value it cannot
        // decode.
        let wide = try Self.reading(type: .ui16, bytes: [0x01, 0x02])

        #expect(wide.rawDescription == "ui16 0x0102")
        #expect(!wide.entry(decodedAutomatic: true).contains("DISAGREE"))
        #expect(!wide.entry(decodedAutomatic: false).contains("DISAGREE"))
    }

    @Test("An empty payload is reported as having no bytes, not as zero")
    func anEmptyPayloadIsNotAZero() throws {
        let empty = try Self.reading(bytes: [])

        #expect(empty.rawDescription == "ui8 (no bytes)")
        #expect(!empty.entry(decodedAutomatic: true).contains("DISAGREE"))
    }

    /// The print the research document's table is transcribed from. Both fans' entries must
    /// survive into it as written, one per line, with the legend that says what `decoded`
    /// folds, and the row's note last.
    @Test("The startup report carries every entry, the legend, and the note")
    func theStartupReportCarriesEveryEntry() throws {
        let zero = try Self.reading(fan: 0, bytes: [0x00]).entry(decodedAutomatic: true)
        let held = try Self.reading(fan: 1, bytes: [0x02]).entry(decodedAutomatic: false)

        let report = RawFanModeReading.startupReport(entries: [zero, held], note: " NOTE: held.")

        #expect(
            report.hasPrefix(
                """
                startup fan modes on Mac16,5:
                  F0Md raw ui8 0x00; decoded automatic
                  F1Md raw ui8 0x02; decoded manual (non-zero)

                """))
        #expect(report.contains("A decoded `manual` therefore means non-zero"))
        #expect(report.hasSuffix(" NOTE: held."))
    }

    @Test("A fan index that does not form a four-character key is unreadable, not a crash")
    func aMalformedKeyIsReportedUnreadable() async {
        // `F10Md` is five characters. The guard answers before the connection is touched, so
        // this runs without hardware.
        let reading = await RawFanModeReading.read(fan: 10, through: SMCConnection())

        #expect(reading.rawDescription == "unreadable (F10Md is not a well-formed key)")
    }
}
