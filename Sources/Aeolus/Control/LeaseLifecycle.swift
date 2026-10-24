import AeolusLeaseControl
import Foundation

/// Where the app's lifecycle reaches the lease: quit, logout, the Mac waking, this user's session
/// being switched away from, and closing the last control window (#155).
///
/// Each method is the one call site its event reaches, so `AppComposition` decides which events to
/// connect and this type decides what each one does. It needs no AppKit, so the suite drives it
/// with plain calls. `AppComposition` wires it:
///
/// - **Quit:** `AeolusAppDelegate.applicationShouldTerminate(_:)` returns `.terminateLater` and
///   passes `NSApplication.reply(toApplicationShouldTerminate:)` here as `reply`.
/// - **Logout, restart and shutdown:** `NSWorkspace.willPowerOffNotification` calls
///   `systemWillPowerOff()`.
/// - **Wake:** `NSWorkspace.didWakeNotification` calls `systemDidWake()`.
/// - **Fast user switching:** `NSWorkspace.sessionDidResignActiveNotification` calls
///   `sessionDidResignActive()`.
/// - **The last control window closing** calls `lastControlWindowClosed()`.
///
/// Nothing here takes a lease. Until a control calls `LeaseDriver.take(_:)`, each of these finds
/// nothing held and sends nothing.
///
/// ## Quit releases explicitly, and only then tears the connection down
///
/// A crashed app is covered by the helper's `connectionDidInvalidate` path, and that path is a
/// backstop, not the mechanism: a quit sends `releaseLease` and waits up to
/// `LeaseDriver.releaseBound` for it before the connection goes (`LeaseDriver.shutDown()`). The
/// reply is always "terminate": an unanswered release never holds a quit hostage, because the
/// teardown that follows ends the lease anyway.
///
/// ## Three defaults that are the maintainer's to change (#153)
///
/// - **Closing the last control window releases.** That is #155's text. The menu bar item keeps
///   running, so "set 75 %, close the window" puts the fans back on automatic; whether the lease
///   should instead live as long as the menu bar item is the maintainer's open question on #153,
///   and changing it is a change to which event reaches `lastControlWindowClosed()`, not to this
///   type.
/// - **Wake never asks for the fans again.** `systemDidWake()` brings the next renewal forward so
///   a lease that did not survive the sleep is reported at once, and that is all.
/// - **Fast user switching releases.** Giving the fans back is always safe. Switching back asks
///   for nothing.
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
    /// - Parameter reply: `NSApplication.reply(toApplicationShouldTerminate:)`, in the wiring.
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

    /// Logout, restart or shutdown: the lease is released, within the bound. The quit that
    /// follows finds nothing held and sends nothing more.
    public func systemWillPowerOff() async {
        await driver.releaseFans()
    }

    /// The Mac woke. A lease held across the sleep is renewed at once, so one that did not survive
    /// it is reported as lost now. **Never asks for the fans again** (#153's default).
    ///
    /// Can wait up to `HelperClientDeadlines.handshakeVerb` (`LeaseDriver.systemDidWake()`), so
    /// the wiring calls it from a task of its own.
    public func systemDidWake() async {
        await driver.systemDidWake()
    }

    /// This user's session stopped being the active one: the lease is released, within the bound
    /// (#153's default).
    public func sessionDidResignActive() async {
        await driver.releaseFans()
    }

    /// The last control window closed: the lease is released, within the bound.
    public func lastControlWindowClosed() async {
        await driver.releaseFans()
    }
}
