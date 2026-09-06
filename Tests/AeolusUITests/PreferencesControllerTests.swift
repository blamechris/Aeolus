import Foundation
import Testing

@testable import AeolusUI

@Suite("PreferencesController — every mutator clamps and persists the same way")
@MainActor
struct PreferencesControllerTests {

    @Test("Loads whatever the store already had at construction")
    func loadsFromStoreAtConstruction() {
        let saved = Preferences(temperatureUnit: .fahrenheit, launchAtLogin: true)
        let store = InMemoryPreferencesStore(stored: saved)
        let controller = PreferencesController(store: store)

        #expect(controller.preferences == saved)
    }

    @Test("setSelectedSensorKeys updates and persists")
    func setSelectedSensorKeysPersists() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setSelectedSensorKeys(["Tp09", "F0Ac"])

        #expect(controller.preferences.selectedSensorKeys == ["Tp09", "F0Ac"])
        #expect(store.saveCallCount == 1)
        #expect(store.load().selectedSensorKeys == ["Tp09", "F0Ac"])
    }

    @Test("setTemperatureUnit updates and persists")
    func setTemperatureUnitPersists() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setTemperatureUnit(.fahrenheit)

        #expect(controller.preferences.temperatureUnit == .fahrenheit)
        #expect(store.load().temperatureUnit == .fahrenheit)
    }

    @Test("setRefreshInterval clamps before it ever reaches the store")
    func setRefreshIntervalClampsBeforePersisting() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setRefreshInterval(9999)

        #expect(controller.preferences.refreshInterval == PreferencesRefreshInterval.maximum)
        #expect(store.load().refreshInterval == PreferencesRefreshInterval.maximum)
    }

    @Test("setRefreshInterval clamps a non-finite value to the default, not to a bound")
    func setRefreshIntervalClampsNonFiniteToDefault() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setRefreshInterval(.nan)

        #expect(controller.preferences.refreshInterval == PreferencesRefreshInterval.defaultValue)
    }

    @Test("setMenuBarReadouts distinguishes nil from an explicit empty selection")
    func setMenuBarReadoutsDistinguishesNilFromEmpty() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setMenuBarReadouts([])
        #expect(controller.preferences.menuBarReadouts == [])

        controller.setMenuBarReadouts(nil)
        #expect(controller.preferences.menuBarReadouts == nil)
    }

    @Test("setLaunchAtLogin updates and persists the intent only")
    func setLaunchAtLoginPersists() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setLaunchAtLogin(true)

        #expect(controller.preferences.launchAtLogin == true)
        #expect(store.load().launchAtLogin == true)
    }

    @Test("Every mutator persists exactly once per call, never batched or dropped")
    func everyMutatorPersistsExactlyOnce() {
        let store = InMemoryPreferencesStore()
        let controller = PreferencesController(store: store)

        controller.setTemperatureUnit(.fahrenheit)
        controller.setRefreshInterval(2)
        controller.setLaunchAtLogin(true)

        #expect(store.saveCallCount == 3)
    }
}
