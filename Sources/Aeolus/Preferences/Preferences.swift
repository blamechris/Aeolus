import Foundation

/// Everything a user can configure about how Aeolus monitors and presents this machine —
/// `#64`'s preferences model. Pure data: no I/O, no `SMAppService`, no `UserDefaults` —
/// see `PreferencesStore` for persistence and `PreferencesController` for the observable
/// layer views bind to.
public struct Preferences: Sendable, Hashable, Codable {
    /// Which sensors, by raw SMC key, a user has chosen to see in the main window's
    /// sensor list. **Never labels** — a label is catalog decoration, and E6 exists
    /// precisely so a wrong one can never silently stand in for the key it decorates.
    ///
    /// Empty means "no filter": every discovered sensor shows, which is this app's
    /// behaviour before this preference existed and stays the default so a first launch
    /// is never a blank pane a user has to know how to populate. See
    /// `SensorSelectionFilter`, the one place this set is applied.
    public var selectedSensorKeys: Set<String>

    /// Display-only — see `TemperatureUnit`'s own documentation for why changing this
    /// never re-decodes anything.
    public var temperatureUnit: TemperatureUnit

    /// Seconds between refresh ticks. Always within
    /// `PreferencesRefreshInterval.minimum...maximum` — enforced by this type's `init`
    /// and by every mutator on `PreferencesController`, never merely by the control that
    /// happens to be bound to it.
    public var refreshInterval: TimeInterval

    /// Which readouts show in the menu bar, in order — `MenuBarViewModel`'s own selection
    /// type, reused rather than duplicated.
    ///
    /// `nil` means "no explicit choice yet": `MenuBarViewModel` computes a sensible
    /// default from live data, exactly as it does today with no preference wired in at
    /// all. `[]` means a user explicitly chose to show nothing in the menu bar. These are
    /// not the same state — see `MenuBarViewModel.selection`'s own documentation — and
    /// collapsing them to a single `[]` default here would silently overwrite a real
    /// choice with "nothing decided yet" on every relaunch.
    public var menuBarReadouts: [MenuBarReadout]?

    /// The user's persisted *intent* to launch Aeolus at login. This is never, by itself,
    /// evidence that Aeolus is actually registered to do so — see
    /// `LaunchAtLoginController.registrationStatus`, which is the only honest answer to
    /// that question, sourced from `LoginItemRegistering` and never from this value.
    public var launchAtLogin: Bool

    public static let `default` = Preferences()

    public init(
        selectedSensorKeys: Set<String> = [],
        temperatureUnit: TemperatureUnit = .celsius,
        refreshInterval: TimeInterval = PreferencesRefreshInterval.defaultValue,
        menuBarReadouts: [MenuBarReadout]? = nil,
        launchAtLogin: Bool = false
    ) {
        self.selectedSensorKeys = selectedSensorKeys
        self.temperatureUnit = temperatureUnit
        self.refreshInterval = PreferencesRefreshInterval.clamped(refreshInterval)
        self.menuBarReadouts = menuBarReadouts
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSensorKeys
        case temperatureUnit
        case refreshInterval
        case menuBarReadouts
        case launchAtLogin
    }

    /// A hand-rolled decode, not the synthesized one, because every field here must
    /// tolerate a corrupt or out-of-range stored value without trapping — see this
    /// type's own "Done when" criterion. Each field falls back to `init`'s own default
    /// independently on its own decode failure, rather than one bad field invalidating
    /// the whole stored blob: a corrupted `refreshInterval` should not also erase a
    /// perfectly good `selectedSensorKeys`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let selectedSensorKeys =
            (try? container.decode(Set<String>.self, forKey: .selectedSensorKeys)) ?? []
        let temperatureUnit =
            (try? container.decode(TemperatureUnit.self, forKey: .temperatureUnit)) ?? .celsius
        let refreshInterval =
            (try? container.decode(TimeInterval.self, forKey: .refreshInterval))
            ?? PreferencesRefreshInterval.defaultValue
        // `try?` on an already-`Optional`-returning call flattens automatically (SE-0230),
        // so this is already `[MenuBarReadout]?`, not `[MenuBarReadout]??` — a decode
        // failure here is treated exactly like a missing key: "no explicit choice yet,"
        // never a trap.
        let menuBarReadouts =
            try? container.decodeIfPresent([MenuBarReadout].self, forKey: .menuBarReadouts)
        let launchAtLogin = (try? container.decode(Bool.self, forKey: .launchAtLogin)) ?? false

        self.init(
            selectedSensorKeys: selectedSensorKeys,
            temperatureUnit: temperatureUnit,
            refreshInterval: refreshInterval,
            menuBarReadouts: menuBarReadouts,
            launchAtLogin: launchAtLogin)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedSensorKeys, forKey: .selectedSensorKeys)
        try container.encode(temperatureUnit, forKey: .temperatureUnit)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encodeIfPresent(menuBarReadouts, forKey: .menuBarReadouts)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
    }
}
