import Combine
import Foundation

/// Owns the launch-at-login toggle's two halves: the user's persisted *intent*
/// (`PreferencesController.preferences.launchAtLogin`) and the system's actual, honest
/// answer (`LoginItemRegistering.status`) — kept from being conflated the same way
/// `HelperLifecycleController` keeps helper-installation intent separate from what
/// `SMAppService` actually reports for the privileged helper.
///
/// `registrationStatus` is never derived from the stored intent: a preference that says
/// "on" while the registrar has never actually registered anything — true of every build
/// today, since `SystemLoginItemRegistrar` is a stub awaiting direct review, see that
/// type's documentation — must still show the honest answer, not the wish. Per
/// `CLAUDE.md` rule 6.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    /// The system's own answer, sourced from `LoginItemRegistering.status` alone.
    @Published public private(set) var registrationStatus: LoginItemStatus
    /// The most recent failed request, if the last one failed. Cleared when a new request
    /// starts, so a stale complaint cannot linger next to a status that has since changed.
    @Published public private(set) var lastFailure: String?

    private let registrar: any LoginItemRegistering
    private let preferences: PreferencesController

    /// - Parameters:
    ///   - registrar: The `SMAppService.mainApp` seam. Defaults to the real (stubbed)
    ///     conformer. Tests inject an in-memory double.
    ///   - preferences: Where the user's intent is persisted. Not owned by this type —
    ///     `PreferencesController` already owns every other preference, and intent here
    ///     is exactly that: a preference, not launch-at-login-specific state.
    public init(
        registrar: any LoginItemRegistering = SystemLoginItemRegistrar(),
        preferences: PreferencesController
    ) {
        self.registrar = registrar
        self.preferences = preferences
        self.registrationStatus = registrar.status
    }

    /// The user's persisted intent — what a Preferences toggle shows as on/off. Distinct
    /// from `registrationStatus`; see this type's own documentation.
    public var isEnabled: Bool { preferences.preferences.launchAtLogin }

    /// Applies a toggle change: persists the intent, asks `registrar` to match it, then
    /// republishes the system's own answer — never the call's outcome. Identical contract
    /// to `HelperLifecycleController.register()`/`.unregister()`.
    public func setEnabled(_ enabled: Bool) {
        lastFailure = nil
        preferences.setLaunchAtLogin(enabled)

        do {
            if enabled {
                try registrar.register()
            } else {
                try registrar.unregister()
            }
        } catch {
            lastFailure = String(describing: error)
        }

        registrationStatus = registrar.status
    }

    /// Re-reads the registrar's status without changing anything — the same
    /// "the approval affordance lives somewhere else" refresh hook
    /// `HelperLifecycleController.refresh()` provides for the privileged helper.
    public func refresh() {
        registrationStatus = registrar.status
    }
}
