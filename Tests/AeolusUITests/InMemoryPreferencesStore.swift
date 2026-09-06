@testable import AeolusUI

/// An in-memory `PreferencesStore` double — no real `UserDefaults`, no disk, no shared
/// state across test runs. Matches this project's established pattern of a plain-class
/// fake per seam (`FakeHelperDaemonService`); used only from `@MainActor` tests, exactly
/// like that fake.
final class InMemoryPreferencesStore: PreferencesStore {
    private var stored: Preferences?

    /// How many times `save(_:)` was called — lets a test assert persistence happened
    /// without inspecting `stored` directly.
    private(set) var saveCallCount = 0

    init(stored: Preferences? = nil) {
        self.stored = stored
    }

    func load() -> Preferences {
        stored ?? .default
    }

    func save(_ preferences: Preferences) {
        stored = preferences
        saveCallCount += 1
    }
}
