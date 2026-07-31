import SMCCore
import Testing

@testable import AeolusUI

@Suite("ReadingFormatting — shared display text for KeyedReading")
struct ReadingFormattingTests {

    @Test("An unavailable reading always renders as the placeholder, never a number")
    func unavailableRendersAsPlaceholder() {
        let reading = KeyedReading.unavailable(key: "F0Ac", reason: "no outcome returned")
        let text = ReadingFormatting.displayText(for: reading, kind: .rpm)
        #expect(text == ReadingFormatting.unavailablePlaceholder)
        #expect(text != "0")
        #expect(!text.isEmpty)
    }

    @Test(
        "Each SensorReading.Kind gets its own unit suffix",
        arguments: [
            (SensorReading.Kind.temperatureCelsius, "42\u{00B0}C"),
            (SensorReading.Kind.rpm, "42 RPM"),
            (SensorReading.Kind.watts, "42 W"),
            (SensorReading.Kind.volts, "42 V"),
            (SensorReading.Kind.amps, "42 A"),
            (SensorReading.Kind.percent, "42%"),
            (SensorReading.Kind.unknown, "42"),
        ]
    )
    func unitSuffixMatchesKind(_ pair: (SensorReading.Kind, String)) {
        let (kind, expected) = pair
        let reading = KeyedReading.value(key: "Tp09", 42)
        #expect(ReadingFormatting.displayText(for: reading, kind: kind) == expected)
    }

    @Test("A whole-number value renders with no decimal places")
    func wholeNumberHasNoDecimals() {
        #expect(ReadingFormatting.numberText(1712) == "1712")
    }

    @Test("A fractional value renders to exactly two decimal places")
    func fractionalValueRendersToTwoDecimals() {
        #expect(ReadingFormatting.numberText(44.2) == "44.20")
        #expect(ReadingFormatting.numberText(1343.07) == "1343.07")
    }

    @Test(
        "Non-finite values never trap and never render as a plausible number",
        arguments: [(Double.infinity, "Infinity"), (-Double.infinity, "-Infinity")]
    )
    func nonFiniteValuesRenderTheirSign(_ pair: (Double, String)) {
        let (value, expected) = pair
        #expect(ReadingFormatting.numberText(value) == expected)
    }

    @Test("NaN renders as NaN, never as 0 or a blank string")
    func nanRendersAsNaN() {
        #expect(ReadingFormatting.numberText(.nan) == "NaN")
    }
}
