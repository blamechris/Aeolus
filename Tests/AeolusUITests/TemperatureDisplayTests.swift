import SMCCore
import Testing

@testable import AeolusUI

@Suite("TemperatureDisplay — converts a decoded value for display, never re-decodes")
struct TemperatureDisplayTests {

    @Test("A temperature reading converts to the chosen unit")
    func temperatureReadingConverts() {
        let reading = KeyedReading.value(key: "Tp09", 0)
        let converted = TemperatureDisplay.convert(
            reading, kind: .temperatureCelsius, to: .fahrenheit)

        #expect(converted.value == 32)
        #expect(converted.key == "Tp09", "The raw key must survive conversion unchanged")
    }

    @Test("Celsius is a no-op conversion, byte for byte the same value")
    func celsiusIsUnchanged() {
        let reading = KeyedReading.value(key: "Tp09", 44.2)
        let converted = TemperatureDisplay.convert(
            reading, kind: .temperatureCelsius, to: .celsius)

        #expect(converted.value == 44.2)
    }

    @Test(
        "A non-temperature kind is never converted, regardless of unit",
        arguments: [
            SensorReading.Kind.rpm, .watts, .volts, .amps, .percent, .unknown,
        ]
    )
    func nonTemperatureKindsAreUntouched(_ kind: SensorReading.Kind) {
        let reading = KeyedReading.value(key: "F0Ac", 2000)
        let converted = TemperatureDisplay.convert(reading, kind: kind, to: .fahrenheit)

        #expect(converted.value == 2000, "A non-temperature reading must never be converted")
    }

    @Test("An unavailable reading passes through unchanged — there is nothing to convert")
    func unavailableReadingPassesThrough() {
        let reading = KeyedReading.unavailable(key: "Tp09", reason: "read failed")
        let converted = TemperatureDisplay.convert(
            reading, kind: .temperatureCelsius, to: .fahrenheit)

        #expect(converted == reading)
    }

    @Test("The unit suffix is only ever supplied for temperature kinds")
    func unitSuffixOnlyForTemperature() {
        #expect(
            TemperatureDisplay.unit(for: .temperatureCelsius, temperatureUnit: .fahrenheit) == "°F")
        #expect(TemperatureDisplay.unit(for: .rpm, temperatureUnit: .fahrenheit) == nil)
        #expect(TemperatureDisplay.unit(for: .unknown, temperatureUnit: .celsius) == nil)
    }
}
