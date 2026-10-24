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
///   passes `NSApplication.reply(toApplicationShouldTerminate:)` here as `reply`. A build with no
///   driver never reaches here: it answers `.terminateNow`, because there is nothing to release.
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
/// ## The quit never waits for the main actor
///
/// After `.terminateLater` AppKit spins the run loop *inside* the callout that asked to quit. When
/// that callout is a main-queue job, a `@MainActor` task or a `DispatchQueue.main` block, no other
/// main-queue work runs until the reply arrives, so a quit task on the main actor would never
/// start: no release, a heartbeat still renewing off the main actor, and a process that never
/// exits (`MainRunLoop`). So the shutdown runs on a detached task, and only the reply comes back to
/// the main thread, through `MainRunLoopPerforming` rather than the main actor.
///
/// What that makes safe: a quit asked for from anywhere on the main thread, inside a main-queue job
/// or not. What must still never happen: anything the quit waits for being put on the main actor,
/// and the reply being sent before the teardown it follows.
///
/// ## A signal is not a quit
///
/// `kill`, `launchctl` and a root `shutdown` send `SIGTERM`, which ends the process without asking
/// it to quit: `applicationShouldTerminate(_:)` is never called, none of this runs, and the
/// helper's connection-invalidation backstop ends the lease. Nothing here handles `SIGTERM`; doing
/// so would be a design change for the architect, not wiring.
///
/// ## Three defaults that are the maintainer's to change (#153)
///
/// Each is #153's default, pending the maintainer's decision, and is not that decision.
///
/// - **Closing the last control window releases.** That is #155's text. The menu bar item keeps
///   running, so "set 75 %, close the window" puts the fans back on automatic; whether the lease
///   should instead live as long as the menu bar item is the maintainer's open question on #153,
///   and changing it is a change to which event reaches `lastControlWindowClosed()`, not to this
///   type.
/// - **Wake never asks for the fans again.** `systemDidWake()` brings the next renewal forward so
///   a lease that did not survive the sleep is reported at once, and that is all. Changing this is
///   a change to the driver and a safety review, not a flag: `LeaseLoss` carries no target to ask
///   for again.
/// - **Fast user switching releases.** Giving the fans back is always safe, and switching back
///   asks for nothing. The alternative, holding the lease across the switch, would leave the user
///   at the console refused with `leaseHeldByAnotherClient`.
@MainActor
public final class LeaseLifecycle {

    /// What a quit is answered with: always later, after the release.
    public enum TerminationAnswer: Sendable, Hashable {
        /// `NSApplication.TerminateReply.terminateLater`.
        case later
    }

    private let driver: LeaseDriver
    private let mainRunLoop: any MainRunLoopPerforming

    /// - Parameters:
    ///   - driver: The app's one lease driver.
    ///   - mainRunLoop: How a quit's reply reaches the main thread. The shipping one is the main
    ///     run loop itself; the suite names one it drives.
    public init(driver: LeaseDriver, mainRunLoop: any MainRunLoopPerforming = MainRunLoop()) {
        self.driver = driver
        self.mainRunLoop = mainRunLoop
    }

    /// Quit. Releases the lease and tears the control connection down, on a detached task, then
    /// calls `reply(true)` from the main run loop.
    ///
    /// - Parameter reply: `NSApplication.reply(toApplicationShouldTerminate:)`, in the wiring.
    /// - Returns: `.later`, always: `NSApplication.TerminateReply.terminateLater`.
    @discardableResult
    public func applicationShouldTerminate(
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> TerminationAnswer {
        let driver = self.driver
        let mainRunLoop = self.mainRunLoop
        // Detached: a task created here would inherit the main actor, and the main actor may be
        // held by the very job that asked to quit (see this type's documentation).
        Task.detached {
            await driver.shutDown()
            mainRunLoop.perform { reply(true) }
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
