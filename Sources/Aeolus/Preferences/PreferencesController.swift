import Combine
import Foundation

/// The observable layer Preferences views (`PreferencesView` and friends) bind to: the
/// current `Preferences` value, backed by a `PreferencesStore`, with one typed mutator per
/// field so every write path clamps and persists the same way regardless of which control
/// changed it.
///
/// `@MainActor`: bound directly by SwiftUI views, matching `HelperLifecycleController`'s
/// and `PollingViewModel`'s own concurrency shape.
@MainActor
public final class PreferencesController: ObservableObject {
    @Published public private(set) var preferences: Preferences

    private let store: any PreferencesStore

    /// - Parameter store: Defaults to the real `UserDefaults`-backed store. Tests inject
    ///   an in-memory double.
    public init(store: any PreferencesStore = UserDefaultsPreferencesStore()) {
        self.store = store
        self.preferences = store.load()
    }

    /// Replaces which sensors, by raw key, show in the main window's sensor list. See
    /// `Preferences.selectedSensorKeys`'s documentation for why an empty set means "show
    /// everything," not "show nothing."
    public func setSelectedSensorKeys(_ keys: Set<String>) {
        preferences.selectedSensorKeys = keys
        persist()
    }

    /// Changes the display unit. Never touches decoding — see `TemperatureUnit`'s own
    /// documentation.
    public func setTemperatureUnit(_ unit: TemperatureUnit) {
        preferences.temperatureUnit = unit
        persist()
    }

    /// Changes the refresh cadence. Clamped here — not merely by whatever control called
    /// this — so the bound is the control regardless of caller.
    public func setRefreshInterval(_ interval: TimeInterval) {
        preferences.refreshInterval = PreferencesRefreshInterval.clamped(interval)
        persist()
    }

    /// Replaces the menu bar's readout selection. `nil` restores "compute a sensible
    /// default from live data" — see `Preferences.menuBarReadouts`'s documentation for why
    /// that is distinct from `[]`.
    public func setMenuBarReadouts(_ readouts: [MenuBarReadout]?) {
        preferences.menuBarReadouts = readouts
        persist()
    }

    /// Records the user's launch-at-login intent. This alone never makes Aeolus actually
    /// registered — see `LaunchAtLoginController`, which is what asks
    /// `LoginItemRegistering` to act on this and publishes what the system actually
    /// reports.
    public func setLaunchAtLogin(_ enabled: Bool) {
        preferences.launchAtLogin = enabled
        persist()
    }

    private func persist() {
        store.save(preferences)
    }
}
