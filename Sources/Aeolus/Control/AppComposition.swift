import AeolusLeaseControl
import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
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
/// - **One `LeaseStateModel`**, the driver's reports on the main actor, for views to read.
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
/// nothing held: a quit is answered `.terminateNow`, every control entry point does nothing, the
/// lease state is `.idle` for good, and nothing else happens.
///
/// ## A click takes a lease; the helper decides whether it is granted
///
/// The main window's control for all fans (`FanListView`, through `AllFansControlActions`) calls
/// `take(_:)` for a percentage and `selectAutomatic()` for Auto. Each fan's row (through
/// `FanRowControlActions`, #154) calls `takeFan(_:at:)` for Custom and for a speed typed while the
/// fan's control cannot release (`FanControlPresentation.canRelease`), `adjustFan(_:to:)` for its
/// stepper and for a speed typed while it can, and `releaseFan(_:)` for its Auto. So the app asks
/// for the fans when the user clicks, and only then. `adjust(_:)` has no caller in the app. Quit,
/// logout, wake, fast user switching and the last control window each reach the driver too.
///
/// Today's helper refuses every grant until the write plane exists (#9): its `acquireLease`
/// refuses a plane that cannot write before it asks anything else, and its snapshot reports each
/// fan `.unavailable(.writePathNotBuilt)`, or `.foreignManualControl` for a fan another program
/// holds (`AvailabilityRestatement.swift`, `ReadOnlyFanReport`). So the control is drawn disabled
/// with that reason, and no percentage can be clicked. Once the helper reports every fan
/// `.available`, the same code takes the lease, with no change to the app.
///
/// ## Every driver call is on a task this type spawns (#419)
///
/// SwiftUI cancels a `.task` when its view goes away, and a `.task(id:)` each time its id
/// changes, so a view that owned a driver await would cancel calls the driver means to finish. So
/// the driver is held only inside `private` members here, and no entry point is `async`: each one
/// that reaches the driver is synchronous and starts its own unstructured `Task`, which a caller's
/// cancellation does not reach. That much the compiler holds: a view's action is synchronous,
/// and could not call an `async` entry point without a task of its own. That a member added later
/// stays synchronous is documented here and not enforced.
///
/// `DriverCall.finished()`, through the suite's `latestDriverCall`, is awaitable from anywhere in
/// this module, but it holds no `Task`, so it cancels nothing; awaiting it reaches no driver verb.
///
/// This is the app's half of #419's choice, that the UI never cancels a sequenced verb it means
/// to send again. The driver's half is that it never cancels `acquireLease` or `apply` itself
/// (`LeaseDriver`, "It never cancels a sequenced verb"), and puts each on a task of its own.
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

    /// The driver's reports on the main actor, for views to read in `body`: the driver's, followed
    /// from a task of its own, in a build with a helper; `.idle` for good in one without.
    let leaseState: LeaseStateModel

    /// The driver and everything that reaches it, or `nil` in a build with no helper.
    private let lease: LeaseWiring?

    /// The control windows open now, by the identifier each reported.
    private var controlWindows: Set<UUID> = []

    /// The last call a control entry point started, and how many they have started
    /// (`latestDriverCall`).
    private var latestCall: DriverCall?
    private var callsStarted = 0

    private struct LeaseWiring {
        /// Reached only through this type's entry points, each on a task of its own (#419).
        let driver: LeaseDriver
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
            leaseState = LeaseStateModel()
            lease = nil
        case .incomplete:
            snapshots = HelperSnapshotSource(withoutHelper: .helperInstallIncomplete)
            leaseState = LeaseStateModel()
            lease = nil
        case .embedded:
            let connections = connect()
            let driver = makeDriver(connections.control)
            let lifecycle = LeaseLifecycle(driver: driver, mainRunLoop: mainRunLoop)
            let source = HelperSnapshotSource(
                reader: connections.read, observer: .judging(with: driver),
                refreshInterval: refreshInterval)
            snapshots = source
            leaseState = LeaseStateModel(
                following: driver.reportUpdates(),
                askForARead: { [weak source] in source?.readSoon() })
            lease = LeaseWiring(
                driver: driver,
                lifecycle: lifecycle,
                assertions: LeaseProcessAssertions(process: process, states: driver.stateUpdates()),
                workspaceObservers: Self.observeWorkspace(workspaceNotifications, for: lifecycle))
        }
    }

    /// Whether this build has a lease driver at all.
    var hasLeaseControl: Bool { lease != nil }

    // MARK: - Control

    /// Takes control of `target`'s fans at its speeds: a deliberate user action, from a click
    /// (`LeaseDriver.take(_:)`). Returns at once; the driver's work runs on a task of its own, so
    /// cancelling the caller cancels nothing the driver sends (#419). Does nothing in a build with
    /// no helper.
    ///
    /// Each entry point starts a separate unstructured `Task`. Two calls reach the driver in the
    /// order they were made because the main actor runs its jobs first in, first out, not because
    /// the language promises it; a user's clicks are many run-loop turns apart. A call reaches the
    /// driver only once the main actor runs its task, after this has returned (#500).
    func take(_ target: LeaseTarget) {
        guard let driver = lease?.driver else { return }
        leaseState.userAskedForControl()
        let call = Task { await driver.take(target) }
        started(call)
    }

    /// Moves the speed of a lease that is acquiring or held, over the same fans, and **never
    /// acquires** (`LeaseDriver.adjust(_:)`). Nothing in the app calls it: a row's stepper moves
    /// one fan through `adjustFan(_:to:)`. Returns at once, as `take(_:)` does.
    func adjust(_ target: LeaseTarget) {
        guard let driver = lease?.driver else { return }
        leaseState.userAskedForControl()
        let call = Task { await driver.adjust(target) }
        started(call)
    }

    /// Auto, and the release offer: the lease is released, whatever is in flight
    /// (`LeaseDriver.selectAutomatic()`). Returns at once, as `take(_:)` does. Each entry point
    /// records its request in `leaseState` before its task, so in click order (#157, #509 S1).
    func selectAutomatic() {
        guard let driver = lease?.driver else { return }
        leaseState.userAskedForAutomatic()
        let call = Task { await driver.selectAutomatic() }
        started(call)
    }

    // MARK: - One fan at a time (#154)

    /// Puts fan `index` in Custom at `speed`, every other fan in Custom keeping its speed
    /// (`LeaseDriver.takeFan(_:at:)`): a deliberate user action, the Custom segment or a speed
    /// typed while the fan's control cannot release. The driver composes the target from what is
    /// Custom on its own actor, never from what the window shows. Returns at once, as `take(_:)`
    /// does.
    func takeFan(_ index: Int, at speed: FanTargetRPM) {
        guard let driver = lease?.driver else { return }
        leaseState.userAskedForControl()
        let call = Task { await driver.takeFan(index, at: speed) }
        started(call)
    }

    /// Moves fan `index`'s speed when it is in Custom, and **never acquires and never changes which
    /// fans are held** (`LeaseDriver.adjustFan(_:to:)`): a row's stepper, and a speed typed while
    /// the fan's control can release. Returns at once, as `take(_:)` does.
    func adjustFan(_ index: Int, to speed: FanTargetRPM) {
        guard let driver = lease?.driver else { return }
        leaseState.userAskedForControl()
        let call = Task { await driver.adjustFan(index, to: speed) }
        started(call)
    }

    /// A row's Auto: fan `index` back to automatic control. Returns at once, as `take(_:)` does.
    ///
    /// Keyed on the fans the driver's report on screen names in Custom
    /// (`FanRowControlPresentation.automaticRoute(forFan:in:)`, #154's ruling Q5, as corrected in
    /// #515's first round):
    ///
    /// - **No fan but this one:** `selectAutomatic()`, a release, recorded as the user's Auto, so
    ///   the banner may say "as you chose" once the release is answered and every fan reads
    ///   Automatic. With nothing in Custom it is what Auto for all fans does then: nothing.
    /// - **Other fans too, or no answer:** `releaseFan(_:)`, recorded as a request for control.
    ///   With other fans still in Custom the driver releases and takes them again, which is not the
    ///   user choosing Auto. While releasing the report does not say what is in Custom, so the
    ///   record fails safe: it never claims a choice of Auto the user may not have made.
    ///
    /// **The report can be behind the driver.** Each click's task reaches the driver after this
    /// returns, so two quick clicks can both be read against the same report. Both errors fail
    /// safe. A report naming other fans when the driver holds only this one records a request for
    /// control, and `releaseFan(_:)` still releases on the driver's actor. A report naming this fan
    /// alone when the driver has since taken another records Auto, and `selectAutomatic()`
    /// releases every fan, the one taken since included: the fans end on automatic control, and the
    /// user's last click was Auto.
    func releaseFan(_ index: Int) {
        guard let driver = lease?.driver else { return }
        let route = FanRowControlPresentation.automaticRoute(
            forFan: index, in: leaseState.current.state)
        let call: Task<Void, Never>
        switch route {
        case .selectAutomatic:
            leaseState.userAskedForAutomatic()
            call = Task { await driver.selectAutomatic() }
        case .releaseFan:
            leaseState.userAskedForControl()
            call = Task { await driver.releaseFan(index) }
        }
        started(call)
    }

    // MARK: - The suite's seam

    /// A call one of the entry points above started on the driver, as a handle that can only be
    /// waited for. **It holds no `Task`**, as `LeaseDriver.HeartbeatHandle` holds none: a `Task`
    /// would hand its holder `cancel()`, and these calls are on tasks of their own so that nothing
    /// a caller does can cancel them (#419). Only this file can make one.
    struct DriverCall: Sendable {

        /// How many calls the entry points had started when this one began, this one included.
        let ordinal: Int

        private let wait: @Sendable () async -> Void

        fileprivate init(ordinal: Int, task: Task<Void, Never>) {
            self.ordinal = ordinal
            wait = { await task.value }
        }

        /// Returns once the driver has run the call: the task's one step is the driver's verb.
        /// **Not cancellable:** it waits on the task's `value`. Call it from a task of its own
        /// (`LeaseScene.run`), never directly from a test.
        func finished() async { await wait() }
    }

    /// The last call a control entry point started on the driver, or `nil` if none has: **a seam
    /// for the suite**, which nothing in the app reads.
    ///
    /// **Why (#500).** In release-config runs, the pre-PR shape (a click, then `settle()`) was red
    /// at `!reacquired`. Why was not established (`CompositionScene.click(_:)` has the counts). A
    /// test that must know a click has reached the driver waits on this. Always `nil` with no
    /// helper.
    var latestDriverCall: DriverCall? { latestCall }

    private func started(_ task: Task<Void, Never>) {
        callsStarted += 1
        latestCall = DriverCall(ordinal: callsStarted, task: task)
    }

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
