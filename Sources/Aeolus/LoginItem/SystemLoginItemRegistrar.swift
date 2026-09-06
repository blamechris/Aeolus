import ServiceManagement

/// The real `SMAppService.mainApp` conformer for launch-at-login.
///
/// ## Written under direct review
///
/// `#64` built everything around this type — the preference toggle, its persisted intent,
/// `LoginItemRegistering`, `LaunchAtLoginController`, and an in-memory test double — as
/// ordinary application work. The ruling recorded on `#11` reserves this one call site
/// for direct review rather than an unsupervised implementer, even though `.mainApp` is
/// the unprivileged login-item API: no entitlement, no daemon, no root, and structurally
/// unrelated to the privileged helper's `SMAppService.daemon(plistName:)` registration.
/// The bodies below are that reviewed call site.
///
/// ## What it claims, and what it does not
///
/// `status` is `SMAppService.mainApp.status` mapped through `LoginItemStatus.init(_:)`,
/// the same forward-tolerant mirror shape `HelperDaemonStatus` uses for the daemon: a
/// value this SDK does not recognise is reported as `.unavailable` carrying the raw value,
/// never as a plausible-looking known case (`CLAUDE.md` rule 6).
///
/// `register()` and `unregister()` returning without throwing means macOS accepted the
/// request — not that the item is enabled. `status` is the only answer to that, and
/// `LaunchAtLoginController` republishes it after every call rather than inferring it
/// from the call's outcome. A build macOS declines to register — an ad-hoc-signed
/// development build is the usual case — surfaces as a thrown error and an honest status,
/// which is exactly what the controller's `lastFailure` exists to show.
@MainActor
public final class SystemLoginItemRegistrar: LoginItemRegistering {
    private let service: SMAppService

    public init() {
        service = .mainApp
    }

    public var status: LoginItemStatus { LoginItemStatus(service.status) }

    public func register() throws { try service.register() }

    public func unregister() throws { try service.unregister() }
}
