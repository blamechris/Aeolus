import Foundation
import Testing

@testable import AeolusUI

@Suite("Preferences — a corrupt or out-of-range stored value falls back and clamps, never traps")
struct PreferencesTests {

    // MARK: - Defaults

    @Test("The default value never allows an unreachable refresh interval")
    func defaultRefreshIntervalIsClamped() {
        #expect(Preferences.default.refreshInterval == PreferencesRefreshInterval.defaultValue)
    }

    @Test("The default has no explicit menu bar selection and no sensor filter")
    func defaultsAreUnconfigured() {
        #expect(Preferences.default.menuBarReadouts == nil)
        #expect(Preferences.default.selectedSensorKeys.isEmpty)
        #expect(Preferences.default.launchAtLogin == false)
        #expect(Preferences.default.temperatureUnit == .celsius)
    }

    // MARK: - init clamps regardless of caller

    @Test("init clamps an out-of-range refresh interval rather than accepting it")
    func initClampsOutOfRangeInterval() {
        let preferences = Preferences(refreshInterval: 999)
        #expect(preferences.refreshInterval == PreferencesRefreshInterval.maximum)
    }

    @Test("init clamps a non-finite refresh interval to the default")
    func initClampsNonFiniteInterval() {
        let preferences = Preferences(refreshInterval: .nan)
        #expect(preferences.refreshInterval == PreferencesRefreshInterval.defaultValue)
    }

    // MARK: - Codable round-trip

    @Test("A fully-populated value round-trips through JSON exactly")
    func fullyPopulatedRoundTrips() throws {
        let original = Preferences(
            selectedSensorKeys: ["Tp09", "TC0P"],
            temperatureUnit: .fahrenheit,
            refreshInterval: 5,
            menuBarReadouts: [MenuBarReadout(key: "F0Ac", source: .fan)],
            launchAtLogin: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        #expect(decoded == original)
    }

    @Test("An empty menu bar selection round-trips as empty, never as nil")
    func emptyMenuBarSelectionRoundTrips() throws {
        let original = Preferences(menuBarReadouts: [])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        #expect(decoded.menuBarReadouts != nil)
        #expect(decoded.menuBarReadouts == [])
    }

    // MARK: - Corrupt storage never traps

    @Test(
        """
        Garbage JSON that is not even an object decodes to nothing usable and must be \
        treated as absent by the store
        """
    )
    func garbageIsNotDecodable() {
        let garbage = Data("not json at all".utf8)
        #expect(throws: Error.self) {
            try JSONDecoder().decode(Preferences.self, from: garbage)
        }
    }

    @Test("An out-of-range refresh interval in the stored JSON is clamped on decode, not rejected")
    func outOfRangeStoredIntervalIsClampedOnDecode() throws {
        let json = """
            {
                "selectedSensorKeys": [],
                "temperatureUnit": "celsius",
                "refreshInterval": 86400,
                "launchAtLogin": false
            }
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(decoded.refreshInterval == PreferencesRefreshInterval.maximum)
    }

    @Test(
        "A non-numeric refresh interval in the stored JSON falls back to the default, never traps")
    func nonNumericStoredIntervalFallsBackToDefault() throws {
        let json = """
            {
                "selectedSensorKeys": [],
                "temperatureUnit": "celsius",
                "refreshInterval": "not a number",
                "launchAtLogin": false
            }
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(decoded.refreshInterval == PreferencesRefreshInterval.defaultValue)
    }

    @Test("An unrecognised temperature unit in the stored JSON falls back to Celsius")
    func unrecognisedTemperatureUnitFallsBackToCelsius() throws {
        let json = """
            {
                "selectedSensorKeys": [],
                "temperatureUnit": "kelvin",
                "refreshInterval": 1,
                "launchAtLogin": false
            }
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(decoded.temperatureUnit == .celsius)
    }

    @Test("A completely empty JSON object decodes to every field's own default")
    func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(decoded == Preferences.default)
    }

    @Test(
        """
        A malformed selectedSensorKeys field falls back to empty rather than failing the \
        whole decode
        """
    )
    func malformedSensorKeysFallsBackToEmpty() throws {
        let json = """
            {
                "selectedSensorKeys": "not-an-array",
                "temperatureUnit": "celsius",
                "refreshInterval": 1,
                "launchAtLogin": false
            }
            """
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(decoded.selectedSensorKeys.isEmpty)
    }
}
