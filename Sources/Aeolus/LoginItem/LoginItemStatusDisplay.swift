/// Pure formatter for "what should Preferences say about launch-at-login", given a
/// `LoginItemStatus` — extracted from the view layer for the same reason
/// `HelperStatusDisplay` was: `CLAUDE.md` rule 6's honesty requirement then becomes
/// checkable by a unit test rather than by reading a `View` body.
enum LoginItemStatusDisplay {
    static func text(for status: LoginItemStatus) -> String {
        switch status {
        case .notRegistered:
            return "Not registered to launch at login."
        case .enabled:
            return "Launches at login."
        case .requiresApproval:
            return "Waiting for your approval in System Settings › Login Items & Extensions."
        case .notFound:
            return "macOS cannot find this registration."
        case .unavailable(let reason):
            return reason
        }
    }
}
