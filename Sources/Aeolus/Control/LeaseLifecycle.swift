import Foundation

/// Where the app's lifecycle gives the fans back: quit, logout, and closing the last control
/// window (#155).
///
/// **Not wired yet**, like `LeaseDriver`. Each method is the one call site its event reaches, so
/// the wiring decides which events to connect and this type decides what each one does. It needs
/// no AppKit, so the suite drives it with plain calls:
///
/// - **Quit:** the app delegate's `applicationShouldTerminate(_:)` returns `.terminateLater`
///   when `applicationShouldTerminate(reply:)` answers `.later`, and passes
///   `NSApp.reply(toApplicationShouldTerminate:)` as `reply`.
/// - **Logout:** an observer of `NSWorkspace.willPowerOffNotification` calls
///   `systemWillPowerOff()`.
/// - **The last control window closing** calls `lastControlWindowClosed()`.
///
/// ## Quit releases explicitly, and only then tears the connection down
///
/// A crashed app is covered by the helper's `connectionDidInvalidate` path, and that path is a
/// backstop, not the mechanism: a quit sends `releaseLease` and waits up to
/// `LeaseDriver.releaseBound` for it before the connection goes (`LeaseDriver.shutDown()`). The
/// reply is always "terminate": an unanswered release never holds a quit hostage, because the
/// teardown that follows ends the lease anyway.
///
/// ## Closing the window releases
///
/// That is #155's text. The menu bar item keeps running, so "set 75 %, close the window" puts the
/// fans back on automatic; whether the lease should instead live as long as the menu bar item is
/// the maintainer's open question on #153, and changing it is a change to which event reaches
/// `lastControlWindowClosed()`, not to this type.
@MainActor
public final class LeaseLifecycle {

    /// What a quit is answered with: always later, after the release.
    public enum TerminationAnswer: Sendable, Hashable {
        /// `NSApplication.TerminateReply.terminateLater`.
        case later
    }

    private let driver: LeaseDriver

    public init(driver: LeaseDriver) {
        self.driver = driver
    }

    /// Quit. Releases the lease, tears the control connection down, then calls `reply(true)`.
    ///
    /// - Parameter reply: `NSApp.reply(toApplicationShouldTerminate:)`, in the wiring.
    /// - Returns: `.later`, always: `NSApplication.TerminateReply.terminateLater`.
    @discardableResult
    public func applicationShouldTerminate(
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> TerminationAnswer {
        let driver = self.driver
        Task {
            await driver.shutDown()
            reply(true)
        }
        return .later
    }

    /// Logout: the lease is released, within the bound. The quit that follows finds nothing
    /// held and sends nothing more.
    public func systemWillPowerOff() async {
        await driver.releaseFans()
    }

    /// The last control window closed: the lease is released, within the bound.
    public func lastControlWindowClosed() async {
        await driver.releaseFans()
    }
}
