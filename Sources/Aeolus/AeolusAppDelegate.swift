import AppKit

/// The app delegate SwiftUI constructs for `AeolusApp` (`@NSApplicationDelegateAdaptor`), for the
/// one AppKit callback the lease needs: the quit.
///
/// It answers `.terminateLater` and hands `NSApplication.reply(toApplicationShouldTerminate:)` to
/// the composition root, which replies exactly once, after the lease's explicit release
/// (`AppComposition.applicationShouldTerminate(reply:)`). Everything it decides is there, where the
/// suite can drive it without an `NSApplication`.
final class AeolusAppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppComposition.running.applicationShouldTerminate { terminate in
            sender.reply(toApplicationShouldTerminate: terminate)
        }
    }
}

extension LeaseLifecycle.TerminationAnswer {

    /// What `applicationShouldTerminate(_:)` returns for this answer. Pure, and exhaustive with no
    /// `default:`, so an answer added later has to be mapped here.
    ///
    /// `.later` is `.terminateLater`, never `.terminateNow`: a release is pending, and
    /// `.terminateNow` would end the process before it was sent.
    var terminateReply: NSApplication.TerminateReply {
        switch self {
        case .later:
            return .terminateLater
        }
    }
}
