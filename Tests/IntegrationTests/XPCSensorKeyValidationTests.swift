import FanKit
import Foundation
import Testing

@testable import AeolusXPC

/// What a curve may name as its sensors: SMC keys, by shape (#566).
///
/// Every refusal is asserted by its detail, because five guards share the name `sensorKeys` and
/// the point of each test is which one refused. `SensorKeyBoundaryTests` sends the same cases
/// across the helper's real boundary; this suite holds the rule itself, and its edges.
@Suite("XPC sensor keys: the shape of an SMC key")
struct XPCSensorKeyValidationTests {

    static let lengthRefusal = "each key must be exactly 4 bytes, as an SMC key is"
    static let alphabetRefusal = "each key must be printable ASCII, as an SMC key is"
    static let emptyRefusal = "a curve must name at least one sensor"
    static let countRefusal = "a curve may name at most 16 sensors"
    static let repeatRefusal = "a curve names the same sensor twice"

    /// Real keys: `Tp09` and `#KEY` from `Mac16,5`, `aDC?` and `aDC!` its two keys with `?` and
    /// `!`, `TC0P` the Intel CPU proximity sensor every fixture here names, and `FS! `, the Intel
    /// force bitmask `SMCKey` names, which is why a space is in the alphabet.
    @Test(
        "A key shaped like an SMC key is accepted",
        arguments: ["Tp09", "#KEY", "aDC?", "aDC!", "TC0P", "FS! "])
    func anSMCKeyIsAccepted(_ key: String) {
        #expect(fault(from: { try AeolusXPCValidation.validateSensorKey(key) }) == nil)
    }

    /// Bytes, not characters. `Tp0é` and `ab\r\nc` are four characters and five bytes; the
    /// second is four ASCII characters by `Character.isASCII`, which is what `SMCKey`'s own
    /// check admits.
    ///
    /// **Mutation:** delete the length guard in `validateSensorKey`. Run: red on every row; the
    /// two five-byte rows are then refused by the alphabet guard, so red on the detail.
    @Test(
        "A key that is not four bytes is refused by length",
        arguments: ["", "Tp0", "Tp091", "Tp0\u{E9}", "ab\r\nc"])
    func aKeyOfAnotherLengthIsRefused(_ key: String) {
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKey(key) })
                == Self.lengthRefusal)
    }

    /// Four bytes each, so the length guard passes them and the alphabet guard is the one that
    /// refuses. The first three are ASCII, and only the display half of `isSensorKeyScalar`
    /// refuses them; the next three are removed from display and outside ASCII, so either half
    /// does; the last two are displayed and outside ASCII, so only the ASCII half does.
    ///
    /// **Mutation:** make `isSensorKeyScalar` `scalar.isASCII` alone. Run: red on the first three
    /// rows. **Mutation:** make it `!FaultText.isRemovedFromDisplay(scalar)` alone. Run: red on
    /// the last two.
    @Test(
        "A four-byte key outside the alphabet is refused",
        arguments: [
            "Tp0\n", "Tp0\u{0}", "Tp0\u{7F}",
            "\u{2028}T", "\u{202E}T", "T\u{200B}",
            "T\u{E9}0", "\u{1F321}",
        ])
    func aKeyOutsideTheAlphabetIsRefused(_ key: String) {
        #expect(key.utf8.count == AeolusXPCValidation.sensorKeyUTF8Bytes)
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKey(key) })
                == Self.alphabetRefusal)
    }

    /// The oracle, written out rather than asked of `isSensorKeyScalar`: printable ASCII.
    private static func inTheAlphabet(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value)
    }

    /// `scalar`, padded with `A` to the four bytes an SMC key is, so the length guard passes
    /// every key this builds and the alphabet guard alone decides it.
    private static func fourBytes(around scalar: Unicode.Scalar) -> String {
        var key = String.UnicodeScalarView()
        key.append(scalar)
        key.append(contentsOf: repeatElement("A", count: 4 - scalar.utf8.count))
        return String(key)
    }

    /// The class, not the rows above: every scalar, in a key of four bytes, is accepted exactly
    /// when it is printable ASCII. And, asked of the shared rule itself, no scalar
    /// `FaultText.isRemovedFromDisplay` removes is accepted: the acceptance #566 names, held
    /// against the predicate the description fields and both renderers read.
    ///
    /// **Mutation:** make `isSensorKeyScalar` `scalar.isASCII` alone. Run: red on
    /// `outsideNotRefused` and `removedButAdmitted`, naming U+0000 to U+001F and U+007F.
    /// **Mutation:** make it `!FaultText.isRemovedFromDisplay(scalar)` alone. Run: red on
    /// `outsideNotRefused` only, since nothing it admits is removed from display.
    @Test("A key is accepted exactly when its scalars are printable ASCII")
    func theAlphabetIsPrintableASCII() async {
        var outsideNotRefused: [Unicode.Scalar] = []
        var insideRefused: [Unicode.Scalar] = []
        var removedButAdmitted: [Unicode.Scalar] = []
        var removed = 0
        await CodeSpace.forEachRun { run in
            for scalar in run {
                let key = Self.fourBytes(around: scalar)
                let refusal = fault(from: { try AeolusXPCValidation.validateSensorKey(key) })
                let admitted = refusal == nil
                let refusedByTheAlphabet =
                    refusal == .invalidParameter(name: "sensorKeys", detail: Self.alphabetRefusal)
                if Self.inTheAlphabet(scalar) {
                    if !admitted { insideRefused.append(scalar) }
                } else if !refusedByTheAlphabet {
                    outsideNotRefused.append(scalar)
                }
                if FaultText.isRemovedFromDisplay(scalar) {
                    removed += 1
                    if admitted { removedButAdmitted.append(scalar) }
                }
            }
        }
        #expect(removed > 200)
        #expect(outsideNotRefused.isEmpty, "not refused: \(Self.named(outsideNotRefused))")
        #expect(insideRefused.isEmpty, "refused: \(Self.named(insideRefused))")
        #expect(removedButAdmitted.isEmpty, "admitted: \(Self.named(removedButAdmitted))")
    }

    private static func named(_ scalars: [Unicode.Scalar]) -> [String] {
        scalars.prefix(40).map { String(format: "U+%04X", $0.value) }
    }

    // MARK: - The list

    /// **Mutation:** delete the empty-list guard in `validateSensorKeys(_:)`. Run: red here.
    @Test("A curve naming no sensor is refused")
    func noSensorsIsRefused() {
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys([]) }) == Self.emptyRefusal)
    }

    /// Sixteen is accepted and seventeen refused, so the cap is the number and not one either
    /// side of it.
    ///
    /// **Mutation:** delete the count guard. Run: red on the seventeen. **Mutation:** make it
    /// `keys.count < maxSensorKeysPerCurve`. Run: red on the sixteen.
    @Test("A curve may name sixteen sensors and not seventeen")
    func theCountIsCapped() {
        let keys = (0..<17).map { String(format: "Tp%02d", $0) }
        #expect(AeolusXPCValidation.maxSensorKeysPerCurve == 16)
        #expect(
            fault(from: { try AeolusXPCValidation.validateSensorKeys(Array(keys.prefix(16))) })
                == nil)
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys(keys) }) == Self.countRefusal
        )
    }

    /// The count comes before any key is looked at: seventeen keys with a malformed one among
    /// them is refused for the count, which is what bounds the work on a hostile list.
    ///
    /// **Mutation:** move the count guard below the per-key loop. Run: red here, on the detail.
    @Test("The count is checked before the keys")
    func theCountComesFirst() {
        let keys = ["Tp0\n"] + (1..<17).map { String(format: "Tp%02d", $0) }
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys(keys) }) == Self.countRefusal
        )
    }

    /// **Mutation:** delete the repetition guard. Run: red on the first expectation.
    /// **Mutation:** move it above the per-key loop. Run: red on the second, which repeats a
    /// malformed key and must be refused for the key.
    @Test("A key named twice is refused, after the keys themselves")
    func aRepeatedKeyIsRefused() {
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys(["Tp09", "TC0P", "Tp09"]) })
                == Self.repeatRefusal)
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys(["Tp0\n", "Tp0\n"]) })
                == Self.alphabetRefusal)
    }

    // MARK: - The settings

    private static func curve(_ keys: [String]) -> FanSetting.Control {
        .curve(
            FanCurve(
                points: [FanCurve.Point(temperatureCelsius: 50, rpm: 2_000)],
                source: SensorGroup(sensorKeys: keys)))
    }

    /// Settings that carry no curve carry no key, and pass untouched.
    @Test("Fixed and automatic settings, and a well-formed curve, are accepted")
    func settingsWithoutAMalformedKeyAreAccepted() {
        let settings = [
            FanSetting(fanIndex: 0, control: .fixed(rpm: 2_000)),
            FanSetting(fanIndex: 1, control: .automatic),
            FanSetting(fanIndex: 2, control: Self.curve(["Tp09", "TC0P"])),
        ]
        #expect(fault(from: { try AeolusXPCValidation.validateSensorKeys(in: settings) }) == nil)
    }

    /// Every curve is checked, not the first: the malformed one is the second.
    ///
    /// **Mutation:** in `validateSensorKeys(in:)`, loop over `settings.prefix(1)`. Run: red here.
    @Test("A malformed key in any curve of the settings is refused")
    func everyCurveIsChecked() {
        let settings = [
            FanSetting(fanIndex: 0, control: Self.curve(["Tp09"])),
            FanSetting(fanIndex: 1, control: Self.curve(["Tp0\n"])),
        ]
        #expect(
            refusedDetail({ try AeolusXPCValidation.validateSensorKeys(in: settings) })
                == Self.alphabetRefusal)
    }
}
