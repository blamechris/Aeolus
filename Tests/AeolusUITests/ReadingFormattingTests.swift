import Testing

@testable import AeolusUI

@Suite("ReadingFormatting — number rendering and the unavailable-vs-value split")
struct ReadingFormattingTests {

    @Test("A whole number renders without a decimal point")
    func wholeNumberRendersPlain() {
        #expect(ReadingFormatting.number(1712) == "1712")
    }

    @Test("A fractional value renders to two decimal places")
    func fractionalValueRendersToTwoPlaces() {
        // The exact figure measured on this project's development hardware: F0Ac at
        // 1343.07 against a declared F0Mn of 1350 — see docs/SMC-RESEARCH.md.
        #expect(ReadingFormatting.number(1343.07) == "1343.07")
    }

    @Test("Non-finite values never trap and never render as a number")
    func nonFiniteValuesRenderDescriptively() {
        #expect(ReadingFormatting.number(.nan) == "NaN")
        #expect(ReadingFormatting.number(.infinity) == "Infinity")
        #expect(ReadingFormatting.number(-.infinity) == "-Infinity")
    }

    @Test("A .value reading renders as the formatted number, with the unit appended")
    func valueReadingRendersWithUnit() {
        let reading = KeyedReading.value(key: "F0Ac", 1712)
        #expect(ReadingFormatting.text(for: reading, unit: "RPM") == "1712 RPM")
    }

    @Test("A .value reading with no unit renders the bare number")
    func valueReadingRendersWithoutUnit() {
        let reading = KeyedReading.value(key: "Tp09", 44.2)
        #expect(ReadingFormatting.text(for: reading) == ReadingFormatting.number(44.2))
    }

    @Test(
        "An .unavailable reading never renders as 0, an empty string, or a bare dash — it says why"
    )
    func unavailableReadingRendersItsReason() {
        let reading = KeyedReading.unavailable(
            key: "F9Ac", reason: "F9Ac is not present on this machine")
        let text = ReadingFormatting.text(for: reading, unit: "RPM")

        #expect(text.contains("unavailable"))
        #expect(text.contains("F9Ac is not present on this machine"))
        #expect(text != "0")
        #expect(text != "0 RPM")
        #expect(text != "—")
        #expect(!text.isEmpty)
    }
}
