import AppKit

/// The app delegate SwiftUI constructs for `AeolusApp` (`@NSApplicationDelegateAdaptor`), for the
/// one AppKit callback the lease needs: the quit.
///
/// It hands the quit to the composition root, which decides everything
/// (`AppComposition.applicationShouldTerminate(reply:)`):
///
/// - **With a driver:** `.terminateLater`, and one `reply(toApplicationShouldTerminate: true)`
///   after the lease's explicit release and teardown.
/// - **With none:** `.terminateNow`, and no reply.
///
/// ## The trap this avoids
///
/// After `.terminateLater`, AppKit spins the run loop inside the callout that asked to quit, until
/// the reply arrives. When that callout is a main-queue job, a `@MainActor` task or a
/// `DispatchQueue.main` block, nothing else on the main actor runs meanwhile. So nothing the quit
/// waits for may run on the main actor: the release runs on a detached task, and the reply comes
/// back through the main run loop's common modes (`MainRunLoop`), which do run there. That makes a
/// quit safe from wherever on the main thread it is asked for. What must still never happen is a
/// reply, or anything the reply waits for, scheduled through the main actor.
@MainActor
final class AeolusAppDelegate: NSObject, NSApplicationDelegate {

    /// The root a quit is answered by: `AppComposition.running`, unless the suite names another.
    private let root: @MainActor () -> AppComposition

    /// SwiftUI's: the running app's root.
    override init() {
        root = { AppComposition.running }
        super.init()
    }

    /// The suite's: a root of its own.
    init(root: @escaping @MainActor () -> AppComposition) {
        self.root = root
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationShouldTerminate(replyingTo: sender)
    }

    /// What `applicationShouldTerminate(_:)` does, for any sender that takes AppKit's reply, so the
    /// suite can drive it without a second `NSApplication`.
    func applicationShouldTerminate(
        replyingTo sender: some TerminationReplying
    ) -> NSApplication.TerminateReply {
        root().applicationShouldTerminate { terminate in
            sender.reply(toApplicationShouldTerminate: terminate)
        }
    }
}

/// Whatever takes a quit's reply: `NSApplication`, in the app.
@MainActor
protocol TerminationReplying: AnyObject, Sendable {
    func reply(toApplicationShouldTerminate shouldTerminate: Bool)
}

extension NSApplication: TerminationReplying {}

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
