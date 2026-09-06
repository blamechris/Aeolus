import ServiceManagement

/// What Aeolus can truthfully say about whether it is registered to launch at login right
/// now.
///
/// A mirror of `SMAppService.Status`, for the same reason `HelperDaemonStatus` mirrors it
/// for the privileged helper: the system type is a closed set today and may not be
/// tomorrow, and a value this SDK does not know must surface as "cannot say" rather than
/// as a plausible-looking known case. The four named cases map one-to-one onto the
/// system's; `.unavailable` is the forward-tolerant remainder and the seam's honest
/// answer whenever the registrar cannot ask the system at all.
public enum LoginItemStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    /// The registrar cannot currently say — a status this build does not recognise, or a
    /// conformer that cannot reach the system. Never mapped onto `.enabled`: per
    /// `CLAUDE.md` rule 6, a UI must never report a control nothing is honouring.
    case unavailable(reason: String)

    /// The forward-tolerant mapping from the system's answer. An unrecognised value is
    /// carried onward with its raw value, never coerced onto a known case — the same
    /// decoding rule `docs/ADR/0005-xpc-authorisation.md` sets for the fault vocabulary.
    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .unavailable(
                reason:
                    "macOS reported a login-item status this build does not recognise "
                    + "(raw value \(status.rawValue)).")
        }
    }
}

/// The `SMAppService.mainApp` operations launch-at-login performs, behind a seam — the
/// same shape `HelperDaemonService` already uses for the privileged helper's own
/// `SMAppService.daemon(plistName:)` calls, so both of this app's `SMAppService` surfaces
/// are tested the same way: a fake conformer in tests, never the real system API.
///
/// `.mainApp` is the unprivileged, no-entitlement, no-daemon, no-root login-item API — see
/// `#64` and the ruling recorded on `#11` for why it is squarely in scope for this epic
/// despite `.claude/agents/implementer.md`'s `SMAppService` restriction, which is a
/// delegation boundary for one agent, not a project rule. The call site itself,
/// `SystemLoginItemRegistrar`, was written under direct review per that ruling.
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
