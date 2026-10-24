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
/// - **One `LeaseDriver`**, on a **second** `HelperClient`: the control connection. `apply` may
///   take its whole 57 s deadline, and a `snapshot` sequenced behind it on one connection would
///   freeze the display for that long (`HelperLeaseControlling`).
/// - **One `LeaseLifecycle`**, the one place each lifecycle event reaches the driver.
/// - The preferences every window reads, so that `AeolusApp` and `AeolusAppDelegate` reach one
///   root through `running`.
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
/// nothing held: a quit is answered once, and nothing else happens.
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
/// SwiftUI cancels a `.task` when its view goes, and `onChange` runs inside an update. A view that
/// owned a driver await would cancel a call the driver means to finish, or wait in an update for a
/// release bounded at two seconds. So the driver and the lifecycle are `private` here, and nothing
/// a view can reach is `async`: every entry point is synchronous and starts its own unstructured
/// `Task`. That much the compiler holds. That a member added later stays synchronous is
/// documented here and not enforced.
@MainActor
final class AppComposition {

    /// The running app's root.
    ///
    /// A static, because SwiftUI constructs `AeolusAppDelegate` itself: nothing can hand the
    /// delegate the root `AeolusApp.init()` built. Both reach this one instead, and a `static let`
    /// is built once, on first use.
    static let running = AppComposition.forRunningApp(preferencesController: PreferencesController())

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

    /// Whether a quit has been asked for. Its one reply answers every later request too.
    private var quitting = false

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
    init(
        preferencesController: PreferencesController,
        embedding: HelperEmbedding,
        connect: () -> HelperConnections,
        makeDriver: (any HelperLeaseControlling) -> LeaseDriver,
        workspaceNotifications: NotificationCenter,
        process: any ProcessLifetimeControlling
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
            let lifecycle = LeaseLifecycle(driver: driver)
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
    /// Always `.terminateLater`, and `reply` is called exactly once per quit: after the driver's
    /// release and teardown when there is a driver (`LeaseLifecycle.applicationShouldTerminate`),
    /// and on the next turn of the main actor when there is none. A second request while a quit is
    /// already waiting sends nothing and replies to nothing; the reply already promised answers it.
    func applicationShouldTerminate(
        reply: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard !quitting else { return LeaseLifecycle.TerminationAnswer.later.terminateReply }
        quitting = true
        guard let lease else {
            Task { reply(true) }
            return LeaseLifecycle.TerminationAnswer.later.terminateReply
        }
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
    /// are `HelperClient`s on the default transport and pinning, and power, wake and session
    /// events come from `NSWorkspace`'s own centre.
    static func forRunningApp(preferencesController: PreferencesController) -> AppComposition {
        let bundle = Bundle.main
        let client = clientDescription(of: bundle)
        let holder = holderDescription(of: bundle)
        return AppComposition(
            preferencesController: preferencesController,
            embedding: HelperBundleLayout.embedding(inBundleAt: bundle.bundleURL),
            connect: { HelperConnections.make(clientDescription: client) },
            makeDriver: { LeaseDriver(control: $0, holderDescription: holder) },
            workspaceNotifications: workspaceNotificationCenter,
            process: SystemProcessLifetime())
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
