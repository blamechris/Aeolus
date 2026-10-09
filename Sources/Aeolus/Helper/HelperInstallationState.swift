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

    /// A helper is embedded and macOS has no record of it at all: `SMAppService` reports
    /// `.notFound`, and Aeolus has not asked macOS to install it since.
    ///
    /// This is what a first launch looks like, not damage. Background Task Management
    /// creates its record when `register()` is called and not before, so until then the
    /// answer is "not found" rather than "not registered" — the system log at that launch
    /// reads `effectiveItemDisposition: record not found` for the embedded plist. Observed
    /// on hardware (Mac16,5, macOS 27.0.1) with a Developer ID build in /Applications, #337.
    ///
    /// Kept apart from `.notRegistered` because they are different answers from macOS, and
    /// the UI says what macOS said. They offer the same way forward.
    case unknownToSystem

    /// macOS has accepted the registration and is waiting for the user to approve the
    /// background item in System Settings.
    ///
    /// The state most likely to look like a hang: `SMAppService` cannot show a password
    /// prompt at registration time, so from the app's side nothing at all happens after
    /// `register()` returns until the user acts somewhere else entirely.
    case awaitingApproval

    /// macOS reports the daemon as installed and enabled.
    case enabled

    /// Something is wrong with the installation itself. For a missing file in the bundle
    /// retrying cannot help and none is offered; for `.systemCannotFindService`, asking
    /// macOS to register again is the one thing the app can still do, so it is offered.
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
    ///   - registrationAttempted: Whether Aeolus has asked macOS to register the helper
    ///     and has not since seen any answer but `.notFound`. It changes the reading of
    ///     `.notFound` and nothing else: before any attempt, "no record" is what a first
    ///     launch looks like; after one, macOS had the chance to create a record and did
    ///     not, which is worth reporting as broken. Required rather than defaulted so a
    ///     caller cannot pick a reading by omission.
    /// - Returns: The one state that is true of both the bundle and the system.
    static func resolve(
        embedding: HelperEmbedding,
        status: @autoclosure () -> HelperDaemonStatus,
        registrationAttempted: Bool
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
            // Both files are on disk — this probe just checked — and macOS has no record
            // of the service. On its own that is a first launch, not damage: the record
            // is created by `register()`, so before one has been made `.notFound` is the
            // expected answer, and reporting it as broken left nothing to click and made
            // a first install impossible (#337).
            //
            // After an attempt it is different. macOS was asked, had the chance to create
            // the record, and still reports none: moved while registered, damaged, or
            // signed in a way registration will not accept. That is reported as broken —
            // and still retryable, because registering again is something the app can do.
            return registrationAttempted
                ? .brokenInstall(.systemCannotFindService) : .unknownToSystem
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
    /// Both are embedded, and macOS still reports the service as not found after Aeolus
    /// asked it to register the helper.
    ///
    /// Only ever the result of an attempt. `.notFound` before one is `.unknownToSystem`:
    /// the same status, and not evidence of anything wrong.
    case systemCannotFindService
}
