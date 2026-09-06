/// The real `SMAppService.mainApp` conformer for launch-at-login — **deliberately not
/// implemented here**.
///
/// ## Why this file exists in this shape
///
/// `#64` builds the preference toggle, its persisted state, `LoginItemRegistering`, and
/// an in-memory test double — all ordinary application work. The ruling recorded on
/// `#11` is explicit that the actual `SMAppService.mainApp.register()`/`.unregister()`
/// call site is written under direct review, not by an unsupervised implementer agent,
/// even though `.mainApp` itself (unprivileged, no entitlement, no daemon, no root) is
/// squarely in this epic's scope. This type is that call site's placeholder: the
/// reviewed shape will fill in the bodies below, never a working implementation an agent
/// produced anyway under a different name.
///
/// ## What "truthful" means for a stub
///
/// Per `CLAUDE.md` rule 6 — never claim control that is not held — `status` must not
/// report `.enabled`, `.notRegistered`, or any other system-confirmed state it never
/// actually asked `SMAppService` for. It reports `.unavailable` unconditionally, and
/// `register()`/`unregister()` both throw rather than silently succeeding: a caller that
/// ignored the thrown error and assumed success is exactly the failure this stub exists
/// to prevent. See `LaunchAtLoginController`, which never treats a thrown error here as
/// anything other than a failure to report.
@MainActor
public final class SystemLoginItemRegistrar: LoginItemRegistering {
    public init() {}

    public var status: LoginItemStatus {
        // Filled in under direct review (#64): read SMAppService.mainApp.status here and
        // map it through a mirrored status enum — the same way HelperDaemonStatus mirrors
        // SMAppService.Status for the privileged helper's own daemon(plistName:) surface.
        .unavailable(
            reason: "Launch-at-login is not yet wired to SMAppService.mainApp; see #64.")
    }

    public func register() throws {
        // Filled in under direct review (#64): call SMAppService.mainApp.register() here.
        throw LoginItemRegistrationError.notImplemented
    }

    public func unregister() throws {
        // Filled in under direct review (#64): call SMAppService.mainApp.unregister()
        // here.
        throw LoginItemRegistrationError.notImplemented
    }
}

/// Why `SystemLoginItemRegistrar` refused a request. `notImplemented` is its only case
/// today — see that type's documentation for why.
public enum LoginItemRegistrationError: Error, Sendable, Hashable {
    case notImplemented
}
