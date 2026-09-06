import Foundation
import Testing

@testable import AeolusUI

@Suite("TemperatureUnit — display formatting only, never a re-decode")
struct TemperatureUnitTests {

    @Test("Celsius is the identity conversion")
    func celsiusIsIdentity() {
        #expect(TemperatureUnit.celsius.displayValue(fromCelsius: 44.2) == 44.2)
        #expect(TemperatureUnit.celsius.displayValue(fromCelsius: 0) == 0)
        #expect(TemperatureUnit.celsius.displayValue(fromCelsius: -40) == -40)
    }

    @Test(
        "Fahrenheit applies the standard conversion",
        arguments: [
            (0.0, 32.0),
            (100.0, 212.0),
            (-40.0, -40.0),
            (37.0, 98.6),
        ]
    )
    func fahrenheitConverts(_ pair: (Double, Double)) {
        let (celsius, expectedFahrenheit) = pair
        let converted = TemperatureUnit.fahrenheit.displayValue(fromCelsius: celsius)
        #expect(abs(converted - expectedFahrenheit) < 0.0001)
    }

    @Test("Each unit carries its own suffix")
    func suffixesAreDistinct() {
        #expect(TemperatureUnit.celsius.suffix == "°C")
        #expect(TemperatureUnit.fahrenheit.suffix == "°F")
    }

    @Test("Both units round-trip through JSON")
    func codableRoundTrips() throws {
        for unit in TemperatureUnit.allCases {
            let data = try JSONEncoder().encode(unit)
            let decoded = try JSONDecoder().decode(TemperatureUnit.self, from: data)
            #expect(decoded == unit)
        }
    }
}
