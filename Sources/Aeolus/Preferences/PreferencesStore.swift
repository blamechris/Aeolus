import Foundation

/// Where a `Preferences` value durably lives between launches, behind a seam — the same
/// pattern this project already uses for every other real system side effect
/// (`HelperDaemonService` for `SMAppService`, `WatchClock` for wall-clock time): tests
/// drive an in-memory double, never the real store.
///
/// Not `Sendable`: every conformer is used exclusively from `PreferencesController`,
/// which is itself `@MainActor` — the same reasoning `HelperDaemonService` already
/// applies to its own seam rather than adding a concurrency requirement no conformer
/// needs.
public protocol PreferencesStore {
    /// Loads the persisted value, or `Preferences.default` if nothing has been saved yet,
    /// or what was saved cannot be read at all. Never throws and never traps: a
    /// preferences store that could fail to launch the app is worse than one that quietly
    /// resets to defaults.
    func load() -> Preferences

    /// Persists `preferences`. A failure to persist is not surfaced here — the in-memory
    /// value this session is using is unaffected either way, and the next launch simply
    /// falls back to whatever was last durably written, exactly as `load()` already
    /// handles that case.
    func save(_ preferences: Preferences)
}

/// The real store: one JSON blob under a single `UserDefaults` key.
///
/// JSON rather than individual `UserDefaults` keys per field: `Preferences.init(from:)`
/// already carries the per-field fallback behaviour this type needs, so decoding one blob
/// through it is what makes "a corrupt stored value falls back to the default, never
/// traps" true for the whole struct at once rather than something this type has to
/// reimplement per key.
public struct UserDefaultsPreferencesStore: PreferencesStore {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.blamechris.Aeolus.preferences"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Preferences {
        guard let data = defaults.data(forKey: key) else { return .default }
        guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
