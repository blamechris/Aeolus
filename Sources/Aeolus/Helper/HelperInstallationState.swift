import Foundation
import ServiceManagement

/// Aeolus's own mirror of `SMAppService.Status`.
///
/// It exists for one reason: `SMAppService.Status` is a closed set today and may not be
/// tomorrow, and `SMAppService.Status(rawValue:)` cannot be made to produce a case this
/// SDK does not know — so the "macOS told us something we do not recognise" branch is
/// unreachable from a test through the system type. Mirroring makes that branch
/// exercisable, which is the difference between the honest-reporting requirement
/// (`CLAUDE.md` rule 6) being verified and being asserted.
///
/// Same forward-tolerant decoding shape `docs/ADR/0005-xpc-authorisation.md` specifies
/// for the fault vocabulary: an unrecognised value decodes to a case that carries the raw
/// value onward, never to a plausible-looking known one.
enum HelperDaemonStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unrecognised(rawValue: Int)

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
            self = .unrecognised(rawValue: status.rawValue)
        }
    }
}

/// What Aeolus can truthfully say about its privileged helper right now.
///
/// This describes *installation*, and nothing else. Whether a fan can actually be
/// controlled is a separate question with a separate answer —
/// `FanState.manualControlAvailability`, which the helper owns — and conflating the two
/// is how a UI ends up reporting a capability nobody is honouring. A registered, enabled
/// helper with no write path behind it is `.enabled` here and still cannot move a fan.
enum HelperInstallationState: Sendable, Hashable {
    /// This build ships no helper and never will: the `Monitor` configuration.
    ///
    /// Distinct from `.notRegistered` on purpose: "not registered" invites the user to
    /// register something, and there is nothing here to register.
    case unavailableInThisBuild

    /// A helper is embedded but macOS has never been asked to install it.
    case notRegistered

    /// macOS has accepted the registration and is waiting for the user to approve the
    /// background item in System Settings.
    ///
    /// The state most likely to look like a hang: `SMAppService` cannot show a password
    /// prompt at registration time, so from the app's side nothing at all happens after
    /// `register()` returns until the user acts somewhere else entirely.
    case awaitingApproval

    /// macOS reports the daemon as installed and enabled.
    case enabled

    /// Something is wrong with the installation itself, and retrying will not fix it.
    case brokenInstall(HelperInstallDefect)

    /// macOS reported a status this version of Aeolus does not know. Reported as unknown
    /// rather than mapped onto the nearest familiar case.
    case unrecognisedStatus(rawValue: Int)

    /// Combines what the bundle contains with what macOS says about it.
    ///
    /// - Parameters:
    ///   - embedding: What this build actually ships. See `HelperBundleLayout`.
    ///   - status: The system's answer — `@autoclosure` so it is **never evaluated** for
    ///     a build with no helper in it. A `Monitor` build must not query `SMAppService`
    ///     about a daemon it does not contain: the answer would be meaningless, and the
    ///     act of asking is how "not registered" ends up on screen in a build where
    ///     registering is impossible.
    /// - Returns: The one state that is true of both the bundle and the system.
    static func resolve(
        embedding: HelperEmbedding,
        status: @autoclosure () -> HelperDaemonStatus
    ) -> HelperInstallationState {
        switch embedding {
        case .absent:
            return .unavailableInThisBuild
        case .incomplete(.missingExecutable):
            return .brokenInstall(.helperExecutableMissing)
        case .incomplete(.missingDaemonPlist):
            return .brokenInstall(.daemonPlistMissing)
        case .embedded:
            break
        }

        switch status() {
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .awaitingApproval
        case .enabled:
            return .enabled
        case .notFound:
            // Both files are on disk — this probe just checked — and macOS still cannot
            // find the service. That is a broken install (moved while registered,
            // damaged, or signed in a way registration will not accept), not a state a
            // retry resolves, so it is reported as one rather than retried silently.
            return .brokenInstall(.systemCannotFindService)
        case .unrecognised(let rawValue):
            return .unrecognisedStatus(rawValue: rawValue)
        }
    }
}

/// Why an installation is broken. Each of these is reported to the user as broken; none
/// of them is retried automatically.
enum HelperInstallDefect: Sendable, Hashable {
    /// The launchd description is embedded; the executable it names is not.
    case helperExecutableMissing
    /// The executable is embedded; its launchd description is not.
    case daemonPlistMissing
    /// Both are embedded, and macOS reports the service as not found anyway.
    case systemCannotFindService
}
