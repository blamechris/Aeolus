/// What Aeolus can truthfully say about whether it is registered to launch at login right
/// now.
///
/// Deliberately not a mirror of `SMAppService.Status` the way `HelperDaemonStatus` mirrors
/// it for the privileged helper: the production conformer of `LoginItemRegistering`
/// (`SystemLoginItemRegistrar`) does not call `SMAppService` at all yet — see that type's
/// documentation for why — so there is nothing from the system to mirror. `.unavailable`
/// is that conformer's only truthful answer today; the other cases exist so this seam is
/// already shaped for the day a reviewed call site can report them for real, without a
/// second protocol change.
public enum LoginItemStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    /// The registrar cannot currently say — includes "this build's call site is not
    /// implemented yet." Never mapped onto `.enabled`: per `CLAUDE.md` rule 6, a UI must
    /// never report a control nothing is honouring.
    case unavailable(reason: String)
}

/// The `SMAppService.mainApp` operations launch-at-login performs, behind a seam — the
/// same shape `HelperDaemonService` already uses for the privileged helper's own
/// `SMAppService.daemon(plistName:)` calls, so both of this app's `SMAppService` surfaces
/// are tested the same way: a fake conformer in tests, never the real system API.
///
/// `.mainApp` is the unprivileged, no-entitlement, no-daemon, no-root login-item API — see
/// `#64` and the ruling recorded on `#11` for why it is squarely in scope for this epic
/// despite `.claude/agents/implementer.md`'s `SMAppService` restriction, which is a
/// delegation boundary for one agent, not a project rule. What is *not* in scope for an
/// unsupervised implementer is the call site itself — see `SystemLoginItemRegistrar`.
@MainActor
public protocol LoginItemRegistering: AnyObject {
    /// What macOS currently reports, or the honest "cannot say" answer — never
    /// optimistic, and never inferred from a preference toggle.
    var status: LoginItemStatus { get }

    /// Asks macOS to register this app as a login item. Returning without throwing means
    /// the request was accepted, not that it is enabled — identical contract to
    /// `HelperDaemonService.register()`.
    func register() throws

    /// Removes the login-item registration.
    func unregister() throws
}
