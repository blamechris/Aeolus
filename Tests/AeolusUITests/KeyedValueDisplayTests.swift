import Testing

@testable import AeolusUI

@Suite("KeyedValueDisplay — the raw key always survives into the row")
struct KeyedValueDisplayTests {

    @Test("A value reading carries its key, its formatted text, and isAvailable == true")
    func valueReadingProjectsCorrectly() {
        let display = KeyedValueDisplay(reading: .value(key: "F0Ac", 1712), unit: "RPM")

        #expect(display.key == "F0Ac")
        #expect(display.text == "1712 RPM")
        #expect(display.isAvailable)
    }

    @Test(
        """
        An unavailable reading still carries its raw key — the key is never dropped just \
        because the value is missing
        """
    )
    func unavailableReadingStillCarriesKey() {
        let display = KeyedValueDisplay(
            reading: .unavailable(key: "F1Ac", reason: "F1Ac is not present on this machine"),
            unit: "RPM")

        #expect(display.key == "F1Ac")
        #expect(!display.isAvailable)
        #expect(display.text.contains("unavailable"))
        #expect(display.text.contains("F1Ac is not present on this machine"))
    }

    @Test("A value below the declared firmware minimum still renders as available")
    func belowMinimumStillRendersAsAvailable() {
        // F0Ac measured at 1343.07 against a declared F0Mn of 1350 on this project's
        // development hardware — a legitimate observation, not a fault. See
        // docs/SMC-RESEARCH.md.
        let display = KeyedValueDisplay(reading: .value(key: "F0Ac", 1343.07), unit: "RPM")

        #expect(display.isAvailable)
        #expect(display.text == "1343.07 RPM")
    }
}
