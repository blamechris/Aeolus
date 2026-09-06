import Foundation
import Testing

@testable import AeolusUI

@Suite("UserDefaultsPreferencesStore — a corrupt payload is absent, never a trap")
struct PreferencesStoreTests {

    private func freshDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.blamechris.Aeolus.tests.\(UUID().uuidString)"
        // A nil suite here is a broken test environment, not a case this suite is meant
        // to exercise — `#require` fails the test with a clear message instead of a
        // force-unwrap crash.
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test("Nothing saved yet loads as the default")
    func nothingSavedLoadsAsDefault() throws {
        let (defaults, suiteName) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)

        #expect(store.load() == .default)
    }

    @Test("A saved value round-trips through the real store")
    func savedValueRoundTrips() throws {
        let (defaults, suiteName) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPreferencesStore(defaults: defaults)
        let saved = Preferences(
            selectedSensorKeys: ["Tp09"], temperatureUnit: .fahrenheit, refreshInterval: 5,
            launchAtLogin: true)

        store.save(saved)

        #expect(store.load() == saved)
    }

    @Test("Garbage bytes under the key load as the default, never trap")
    func garbageBytesLoadAsDefault() throws {
        let (defaults, suiteName) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "test.preferences"
        defaults.set(Data("not json".utf8), forKey: key)
        let store = UserDefaultsPreferencesStore(defaults: defaults, key: key)

        #expect(store.load() == .default)
    }

    @Test("An out-of-range stored refresh interval loads clamped, not rejected")
    func outOfRangeStoredIntervalLoadsClamped() throws {
        let (defaults, suiteName) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "test.preferences"
        let json = """
            {"selectedSensorKeys": [], "temperatureUnit": "celsius", "refreshInterval": 500, \
            "launchAtLogin": false}
            """
        defaults.set(Data(json.utf8), forKey: key)
        let store = UserDefaultsPreferencesStore(defaults: defaults, key: key)

        #expect(store.load().refreshInterval == PreferencesRefreshInterval.maximum)
    }
}
