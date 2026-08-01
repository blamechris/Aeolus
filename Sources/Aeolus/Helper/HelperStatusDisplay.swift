import Foundation

/// Pure formatter for "what should the app say about its privileged helper", given a
/// `HelperInstallationState`.
///
/// Extracted from the view layer for the same reason `PollingStatusDisplay` was: the
/// honesty `CLAUDE.md` rule 6 requires — never report a state you do not have — is then
/// checkable by a unit test rather than by launching two differently-signed builds.
///
/// Two wordings this type exists to keep apart:
///
/// * A `Monitor` build has **no helper and never will**, so it says so. It must not say
///   "the helper is not running", which implies one exists and could be started.
/// * A registered, enabled helper is described as *registered and enabled*, never as
///   "fan control is available". Installation is not capability; what a fan will accept
///   is `FanState.manualControlAvailability`, and it is the helper's answer to give.
enum HelperStatusDisplay {

    enum Severity: Sendable, Hashable {
        /// Nothing is wrong and nothing is expected of the user.
        case normal
        /// Working as designed, but stalled until the user does something.
        case actionNeeded
        /// Broken, or not understood. Either way, not something a retry fixes.
        case warning
    }

    /// The one thing the user can do about the current state, if there is one.
    enum Action: Sendable, Hashable {
        case register
        case openLoginItemsSettings
        case unregister

        var title: String {
            switch self {
            case .register:
                return "Install Helper…"
            case .openLoginItemsSettings:
                return "Open Login Items Settings"
            case .unregister:
                return "Remove Helper"
            }
        }
    }

    struct Text: Sendable, Hashable {
        let title: String
        let detail: String
        let action: Action?
        let severity: Severity
    }

    static func text(for state: HelperInstallationState) -> Text {
        switch state {
        case .unavailableInThisBuild:
            return Text(
                title: "No privileged helper in this build",
                detail:
                    "This build of Aeolus reads fans and sensors and ships no privileged "
                    + "helper, so it cannot change fan speeds. That is what lets it be built "
                    + "and run without an Apple Developer account — see CONTRIBUTING.md.",
                action: nil,
                severity: .normal)

        case .notRegistered:
            return Text(
                title: "Helper not installed yet",
                detail:
                    "Aeolus ships a privileged helper but has not asked macOS to install it. "
                    + "Installing it needs your approval in System Settings afterwards.",
                action: .register,
                severity: .actionNeeded)

        case .awaitingApproval:
            return Text(
                title: "Waiting for your approval in System Settings",
                detail:
                    "macOS has accepted Aeolus's helper and will not enable it until you turn "
                    + "it on in System Settings › General › Login Items & Extensions. macOS "
                    + "shows no password prompt for this, so nothing further happens until you "
                    + "approve it there.",
                action: .openLoginItemsSettings,
                severity: .actionNeeded)

        case .enabled:
            return Text(
                title: "Helper installed and enabled",
                detail:
                    "macOS reports Aeolus's privileged helper as installed and enabled. What "
                    + "each fan will actually accept is reported per fan.",
                action: .unregister,
                severity: .normal)

        case .brokenInstall(let defect):
            return text(forBrokenInstall: defect)

        case .unrecognisedStatus(let rawValue):
            return Text(
                title: "Aeolus cannot tell whether its helper is installed",
                detail:
                    "macOS reported a helper status this version of Aeolus does not recognise "
                    + "(code \(rawValue)). Rather than guess at what it means, Aeolus is "
                    + "reporting that it does not know.",
                action: nil,
                severity: .warning)
        }
    }

    /// Split out only to keep `text(for:)` readable; every one of these is reported as
    /// broken and none of them offers a retry.
    private static func text(forBrokenInstall defect: HelperInstallDefect) -> Text {
        switch defect {
        case .helperExecutableMissing:
            return Text(
                title: "This copy of Aeolus is damaged",
                detail:
                    "The helper's launchd description is inside the app but the helper itself "
                    + "is missing. Reinstall Aeolus; nothing Aeolus can do from here repairs "
                    + "its own bundle.",
                action: nil,
                severity: .warning)

        case .daemonPlistMissing:
            return Text(
                title: "This copy of Aeolus is damaged",
                detail:
                    "The helper is inside the app but the launchd description that tells macOS "
                    + "how to run it is missing. Reinstall Aeolus; nothing Aeolus can do from "
                    + "here repairs its own bundle.",
                action: nil,
                severity: .warning)

        case .systemCannotFindService:
            return Text(
                title: "macOS cannot find Aeolus's helper",
                detail:
                    "The helper and its launchd description are both inside the app, and macOS "
                    + "reports the service as not found. That usually means Aeolus was moved "
                    + "while installed, is damaged, or is not signed the way installation "
                    + "requires. Reinstall it in /Applications rather than retrying from here.",
                action: nil,
                severity: .warning)
        }
    }
}
