import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import AppKit
import Foundation

/// The app's one composition root: what this build talks to, and every event that reaches the
/// lease (#153, #155).
///
/// ## What it owns
///
/// - **The app's one `HelperSnapshotSource`**, on a read `HelperClient` that sends only
///   `snapshot`, shared by every `PollingViewModel`.
/// - **One `LeaseDriver`**, on a **second** `HelperClient`: the control connection. One `apply`
///   may take its whole deadline, 57 s for one fan, and a `snapshot` sequenced behind it on one
///   connection would freeze the display for that long (`HelperLeaseControlling`).
/// - **One `LeaseLifecycle`**, the one place each lifecycle event reaches the driver.
/// - The `PreferencesController` every window reads. The source reads its refresh interval, and
///   `running` builds both, so `AeolusApp` and `AeolusAppDelegate` share one of each.
///
/// The source reports every read to the driver through a `HelperSnapshotObserver`: a ticket taken
/// before `snapshot` is sent, and each reply judged with it. The source never holds the driver.
///
/// ## A build with no helper constructs no driver
///
/// Both clients, the driver, the lifecycle, the workspace observers and the process assertions
/// exist only when the bundle ships a helper (`HelperEmbedding.embedded`). A `Monitor` build, and
/// a damaged bundle, gets a source with no reader and none of the rest, and cannot reach the
/// helper's mach name even by accident. Every entry point below then does what it would do with
/// nothing held: a quit is answered `.terminateNow`, and nothing else happens.
///
/// ## Inert: nothing here takes a lease
///
/// Nothing in this type calls `LeaseDriver.take(_:)` or `adjust(_:)`, so the app still asks for no
/// fans. Every hook is in place for the control that will (#153's PR 6b): quit, logout, wake, fast
/// user switching and the last control window each reach the driver now, and each finds nothing
/// held and sends nothing.
///
/// ## Every driver call is on a task this type spawns (#419)
///
/// SwiftUI cancels a `.task` when its view goes away, and a `.task(id:)` each time its id
/// changes, so a view that owned a driver await would cancel calls the driver means to finish. So
/// the driver is held only inside `private` members here, through the lifecycle, and nothing a
/// view can reach on this type is `async`: every entry point is synchronous and starts its own
/// unstructured `Task`. That much the compiler holds. That a member added later stays synchronous
/// is documented here and not enforced.
@MainActor
final class AppComposition {

    /// The running app's root.
    ///
    /// A static, because SwiftUI constructs `AeolusAppDelegate` itself: nothing can hand the
    /// delegate the root `AeolusApp.init()` built. Both reach this one instead, and a `static let`
    /// is built once, on first use.
    static let running = AppComposition.forRunningApp(
        preferencesController: PreferencesController())

    /// The centre `NSWorkspace` posts power, wake and session notifications on. They are never
    /// posted to `NotificationCenter.default`.
    static var workspaceNotificationCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }

    let preferencesController: PreferencesController

    /// The app's one reader of helper snapshots.
    let snapshots: HelperSnapshotSource

    /// Where this root listens for power, wake and session events.
    let workspaceNotifications: NotificationCenter

    /// The driver and everything that reaches it, or `nil` in a build with no helper.
    private let lease: LeaseWiring?

    /// The control windows open now, by the identifier each reported.
    private var controlWindows: Set<UUID> = []

    private struct LeaseWiring {
        let lifecycle: LeaseLifecycle
        let assertions: LeaseProcessAssertions
        let workspaceObservers: [any NSObjectProtocol]
    }

    /// - Parameters:
    ///   - preferencesController: The preferences every window reads; the source reads its refresh
    ///     interval live.
    ///   - embedding: What the bundle ships (`HelperBundleLayout.embedding`).
    ///   - connect: Builds the read and control connections. **Never called** unless `embedding`
    ///     is `.embedded`.
    ///   - makeDriver: Builds the driver over the control connection. Never called unless
    ///     `embedding` is `.embedded`.
    ///   - workspaceNotifications: Where power, wake and session events are posted.
    ///   - process: The process's termination counters and activities.
    ///   - mainRunLoop: How a quit's reply reaches the main thread (`LeaseLifecycle`).
    init(
        preferencesController: PreferencesController,
        embedding: HelperEmbedding,
        connect: () -> HelperConnections,
        makeDriver: (any HelperLeaseControlling) -> LeaseDriver,
        workspaceNotifications: NotificationCenter,
        process: any ProcessLifetimeControlling,
        mainRunLoop: any MainRunLoopPerforming
    ) {
        self.preferencesController = preferencesController
        self.workspaceNotifications = workspaceNotifications
        let refreshInterval: @MainActor () -> TimeInterval = {
            preferencesController.preferences.refreshInterval
        }
        switch embedding {
        case .absent:
            snapshots = HelperSnapshotSource(withoutHelper: .noHelperInThisBuild)
            lease = nil
        case .incomplete:
            snapshots = HelperSnapshotSource(withoutHelper: .helperInstallIncomplete)
            lease = nil
        case .embedded:
            let connections = connect()
            let driver = makeDriver(connections.control)
            let lifecycle = LeaseLifecycle(driver: driver, mainRunLoop: mainRunLoop)
            snapshots = HelperSnapshotSource(
                reader: connections.read, observer: .judging(with: driver),
                refreshInterval: refreshInterval)
            lease = LeaseWiring(
                lifecycle: lifecycle,
                assertions: LeaseProcessAssertions(process: process, states: driver.stateUpdates()),
                workspaceObservers: Self.observeWorkspace(workspaceNotifications, for: lifecycle))
        }
    }

    /// Whether this build has a lease driver at all.
    var hasLeaseControl: Bool { lease != nil }

    // MARK: - Quit

    /// Quit, from `AeolusAppDelegate.applicationShouldTerminate(_:)`.
    ///
    /// - **With a driver:** `.terminateLater`, and `reply(true)` exactly once, from the main run
    ///   loop, after the driver's release and teardown
    ///   (`LeaseLifecycle.applicationShouldTerminate`). Nothing it waits for runs on the main
    ///   actor, because AppKit's nested loop after `.terminateLater` can hold the main actor until
    ///   the reply comes (`MainRunLoop`).
    /// - **With none:** `.terminateNow`, and `reply` is never called. There is nothing to release,
    ///   so there is nothing to wait for and nothing that could wait on the main actor.
    ///
    /// **A second quit does not reach here.** A second `terminate(_:)` while a quit waits does not
    /// ask again: AppKit runs `applicationWillTerminate(_:)` and exits (probed on macOS 27 from a
    /// main-actor task, a timer and a dispatched event). The process can therefore exit
    /// mid-release, and so can one sent `SIGTERM`; either way the helper's connection-invalidation
    /// backstop ends the lease. There is no guard against a second request here, because none
    /// arrives.
    func applicationShouldTerminate(
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let lease else { return .terminateNow }
        return lease.lifecycle.applicationShouldTerminate(reply: reply).terminateReply
    }

    // MARK: - Windows

    /// A window appeared. Each window reports its own identifier, kept for as long as it lives.
    func windowAppeared(_ window: AppWindow, id: UUID) {
        guard window.isControlWindow else { return }
        controlWindows.insert(id)
    }

    /// A window went. When it was the last control window open, the lease is released, from a
    /// task of its own (#155's text, the maintainer's to change: see `LeaseLifecycle`).
    func windowDisappeared(_ window: AppWindow, id: UUID) {
        guard window.isControlWindow, controlWindows.remove(id) != nil, controlWindows.isEmpty,
            let lifecycle = lease?.lifecycle
        else { return }
        Task { await lifecycle.lastControlWindowClosed() }
    }

    // MARK: - Power, wake and session

    /// Routes each workspace event to the lifecycle, each on an unstructured task of its own, so
    /// none waits behind another: a wake can wait up to `HelperClientDeadlines.handshakeVerb`
    /// (`LeaseDriver.systemDidWake()`), and a logout must not wait behind it.
    private static func observeWorkspace(
        _ center: NotificationCenter, for lifecycle: LeaseLifecycle
    ) -> [any NSObjectProtocol] {
        [
            center.addObserver(
                forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil
            ) { _ in
                Task { await lifecycle.systemWillPowerOff() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { _ in
                Task { await lifecycle.systemDidWake() }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
            ) { _ in
                Task { await lifecycle.sessionDidResignActive() }
            },
        ]
    }
}

// MARK: - The running app

extension AppComposition {

    /// The root for this process: its own bundle decides whether there is a helper, both clients
    /// are `HelperClient`s on the default transport and pinning, power, wake and session events
    /// come from `NSWorkspace`'s own centre, and a quit's reply comes from the main run loop.
    ///
    /// - Parameters:
    ///   - preferencesController: The preferences every window reads.
    ///   - bundle: `Bundle.main` in the app. The suite names a fixture, so the arm a bundle with a
    ///     helper takes is exercised without one.
    /// - Returns: The root, with a driver only if `bundle` ships a helper.
    static func forRunningApp(
        preferencesController: PreferencesController, bundle: Bundle = .main
    ) -> AppComposition {
        let client = clientDescription(of: bundle)
        let holder = holderDescription(of: bundle)
        return AppComposition(
            preferencesController: preferencesController,
            embedding: HelperBundleLayout.embedding(inBundleAt: bundle.bundleURL),
            connect: { HelperConnections.make(clientDescription: client) },
            makeDriver: { LeaseDriver(control: $0, holderDescription: holder) },
            workspaceNotifications: workspaceNotificationCenter,
            process: ProcessInfo.processInfo,
            mainRunLoop: MainRunLoop())
    }

    /// What the app calls itself in the helper's log, on both connections: `Aeolus.app <version>`.
    static func clientDescription(of bundle: Bundle) -> String {
        guard let version = shortVersion(of: bundle) else { return "Aeolus.app" }
        return "Aeolus.app \(version)"
    }

    /// What the app calls itself in a lease (`LeaseDriver.holderDescription(shortVersion:)`).
    static func holderDescription(of bundle: Bundle) -> String {
        LeaseDriver.holderDescription(shortVersion: shortVersion(of: bundle))
    }

    private static func shortVersion(of bundle: Bundle) -> String? {
        guard
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            !version.isEmpty
        else { return nil }
        return version
    }
}

/// The two connections a build with a helper talks on.
struct HelperConnections {

    /// Sends only `snapshot`.
    let read: any HelperSnapshotReading

    /// Acquires, applies, renews and releases.
    let control: any HelperLeaseControlling

    /// Two `HelperClient`s, never one: a client is one connection, and one connection would queue
    /// a `snapshot` behind an `apply` for up to its whole deadline.
    static func make(clientDescription: String) -> HelperConnections {
        HelperConnections(
            read: HelperClient(clientDescription: clientDescription),
            control: HelperClient(clientDescription: clientDescription))
    }
}

/// The app's windows, as the root counts them.
enum AppWindow: Sendable, Hashable, CaseIterable {

    /// The `WindowGroup`'s window (`MainView`): a control window. There can be several.
    case main

    /// The Settings window. Not a control window.
    case settings

    /// The `MenuBarExtra(.window)` panel. Not a control window: it closes on every click elsewhere,
    /// so a release on its close would give the fans back whenever the user clicked away.
    case menuBarPanel

    /// Whether closing the last window of this kind releases the lease.
    var isControlWindow: Bool {
        switch self {
        case .main:
            return true
        case .settings, .menuBarPanel:
            return false
        }
    }
}
