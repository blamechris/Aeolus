import Foundation

/// Bounds on the refresh cadence a user may configure through Preferences (`#64`).
///
/// ## Why both ends are load-bearing, not just polite defaults
///
/// These bounds tie a config file to firmware's own truth, not the other way around: a
/// preference is a courtesy over the SMC, never a promise to hammer it.
/// `fanctl watch --interval` (`Sources/fanctl/FanctlCommand.swift`) bounds itself the
/// same way for the same reason — see `Fanctl.Watch.validate()` and its own
/// `maxIntervalSeconds` — and this type is that same discipline applied to the app's own
/// preference instead of a CLI flag.
///
/// A clamp here is **the control, not a courtesy**: every call site that constructs a
/// live `PollingViewModel` from a stored preference (`AeolusApp`, `MainView`) runs the
/// stored value through `clamped(_:)` again, so a hand-edited or corrupted
/// `UserDefaults` value can never reach the refresh loop unclamped.
public enum PreferencesRefreshInterval {
    /// The fastest cadence a user may configure.
    ///
    /// Identical to `PollingViewModel.minimumRefreshInterval` — deliberately the *same*
    /// value, not merely a similar one. That is the floor `PollingViewModel` already
    /// enforces on every refresh loop it runs, in service of E7.1's targeted-subset-read
    /// design (a full `readAll()` costs ~0.6 s warm, ~4.5 s cold, measured on
    /// `Mac16,5` — see #11's decomposition comment): a preference bound that permitted
    /// anything faster would be a promise this app cannot keep, and one that chose a
    /// *different* number would only invite the two to drift apart.
    public static let minimum: TimeInterval = PollingViewModel.minimumRefreshInterval

    /// The slowest cadence a user may configure.
    ///
    /// A minute, not `fanctl watch`'s day-long allowance: that command is a one-off
    /// terminal session where "check back tomorrow" is a legitimate ask. This preference
    /// governs a background monitor whose entire purpose is answering "how hot is this
    /// machine right now" — a bound that let it go quiet for hours would defeat the
    /// reason someone opened Aeolus in the first place.
    public static let maximum: TimeInterval = 60

    /// Matches `PollingViewModel`'s own default, so a preference nobody has ever touched
    /// behaves identically to not having one at all.
    public static let defaultValue: TimeInterval = 1

    /// Clamps `interval` into `[minimum, maximum]`.
    ///
    /// A non-finite value (`NaN`, `.infinity`, `-.infinity`) is never reachable from this
    /// app's own controls, which bind a bounded `Slider` — but it is always reachable
    /// from a hand-edited or corrupted `UserDefaults` payload. It falls back to
    /// `defaultValue` rather than clamping toward either bound: neither bound is a more
    /// honest guess than the other for a value that was never a real number.
    public static func clamped(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultValue }
        return min(max(interval, minimum), maximum)
    }
}
