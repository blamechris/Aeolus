import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import SwiftUI
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// `AppComposition`: what the bundle ships decides what the app talks to, the read and control
/// connections are two clients, and the lease's holder is the bundle's version.
///
/// The `Monitor` guarantee moved here from `HelperSnapshotSource+Bundle.swift` with the decision
/// it rests on: the root now builds the read client, the control client and the driver together,
/// or none of them.
@Suite("AppComposition — what the build talks to", .timeLimit(.minutes(1)))
@MainActor
struct AppCompositionTests {

    // MARK: - No helper in the build

    /// **Mutation (C1):** in `AppComposition.init`, give `.absent` the `.embedded` arm's body.
    /// Red at `connected == 0`, `driven == 0`, `!hasLeaseControl` and the
    /// `.noHelperInThisBuild` expectation.
    @Test("The Monitor build constructs no client and no driver")
    func theMonitorBuildConstructsNoDriver() async {
        var connected = 0
        var driven = 0
        let process = FakeProcessLifetime()
        let workspace = NotificationCenter()
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent,
            connect: {
                connected += 1
                return Self.doubles()
            },
            makeDriver: { control in
                driven += 1
                return LeaseDriver(control: control, holderDescription: "unused")
            },
            workspaceNotifications: workspace,
            process: process, mainRunLoop: TestMainRunLoop(.atOnce))

        #expect(connected == 0)
        #expect(driven == 0)
        #expect(!root.hasLeaseControl)
        #expect(root.snapshots.authority() == .readDirectly(.noHelperInThisBuild))

        // Every entry point is inert: nothing reaches a driver that does not exist.
        for name in Self.workspaceEvents { workspace.post(name: name, object: nil) }
        let window = UUID()
        root.windowAppeared(.main, id: window)
        root.windowDisappeared(.main, id: window)
        #expect(process.calls.isEmpty, "nothing was held, so nothing was asked of the process")
    }

    @Test(
        "A damaged bundle constructs no client and no driver either",
        arguments: [HelperEmbeddingDefect.missingExecutable, .missingDaemonPlist])
    func aDamagedBundleConstructsNoDriver(_ defect: HelperEmbeddingDefect) {
        var connected = 0
        var driven = 0
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .incomplete(defect),
            connect: {
                connected += 1
                return Self.doubles()
            },
            makeDriver: { control in
                driven += 1
                return LeaseDriver(control: control, holderDescription: "unused")
            },
            workspaceNotifications: NotificationCenter(),
            process: FakeProcessLifetime(), mainRunLoop: TestMainRunLoop(.atOnce))

        #expect(connected == 0)
        #expect(driven == 0)
        #expect(!root.hasLeaseControl)
        #expect(root.snapshots.authority() == .readDirectly(.helperInstallIncomplete))
    }

    /// The control: both factories are reachable, so the zeros above are findings and not
    /// closures nothing could call.
    @Test("A bundle that ships a helper constructs one pair of clients and one driver")
    func anEmbeddedHelperConstructsOneOfEach() {
        var connected = 0
        var driven = 0
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .embedded,
            connect: {
                connected += 1
                return Self.doubles()
            },
            makeDriver: { control in
                driven += 1
                return LeaseDriver(control: control, holderDescription: "Aeolus.app")
            },
            workspaceNotifications: NotificationCenter(),
            process: FakeProcessLifetime(), mainRunLoop: TestMainRunLoop(.atOnce))

        #expect(connected == 1)
        #expect(driven == 1)
        #expect(root.hasLeaseControl)
        #expect(root.snapshots.authority() == .awaitHelper(.helperConnection(.idle)))
    }

    // MARK: - Two connections

    /// The production connections are two `HelperClient` instances. Constructing them connects
    /// nothing: a client builds its connection when it first sends.
    ///
    /// **Mutation (C2):** in `HelperConnections.make`, build one `HelperClient` and pass it as
    /// both. Red at `!==`.
    @Test("The read connection and the control connection are two clients")
    func readAndControlAreTwoClients() throws {
        let connections = HelperConnections.make(clientDescription: "Aeolus.app 0.0.0")
        let read = try #require(connections.read as? HelperClient)
        let control = try #require(connections.control as? HelperClient)

        #expect(read !== control, "one client would queue a snapshot behind an apply")
    }

    // MARK: - The running app

    /// The running app's root asks the running bundle, which under the test runner ships no
    /// helper, and listens on `NSWorkspace`'s centre, which is where power, wake and session events
    /// are posted.
    ///
    /// **Mutation (C3, "the default centre"):** in `AppComposition.forRunningApp`, pass
    /// `NotificationCenter.default` as `workspaceNotifications`. Red at the first identity
    /// expectation. The same mutation in `workspaceNotificationCenter` is red there too.
    /// **Mutation (C4):** pass `.embedded` instead of reading `Bundle.main`. Red at
    /// `!hasLeaseControl`.
    @Test("The running app's root reads its own bundle and NSWorkspace's centre")
    func forRunningAppReadsTheRunningBundle() {
        let root = AppComposition.forRunningApp(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()))

        #expect(root.workspaceNotifications === NSWorkspace.shared.notificationCenter)
        #expect(root.workspaceNotifications !== NotificationCenter.default)
        #expect(!root.hasLeaseControl)
        #expect(root.snapshots.authority() == .readDirectly(.noHelperInThisBuild))
    }

    @Test("Both connections and the lease name the app and its version, and the helper accepts it")
    func theDescriptionsCarryTheVersion() throws {
        let fixtures = BundleFixtures()
        defer { fixtures.remove() }

        let cases: [(version: String?, expected: String)] = [
            ("0.3.0", "Aeolus.app 0.3.0"), ("", "Aeolus.app"), (nil, "Aeolus.app"),
        ]
        for (version, expected) in cases {
            let source = try fixtures.bundle(version: version)
            let holder = AppComposition.holderDescription(of: source)
            #expect(holder == expected)
            #expect(holder == LeaseDriver.holderDescription(shortVersion: version))
            #expect(throws: Never.self) {
                try AeolusXPCValidation.validateHolderDescription(holder)
            }
            #expect(AppComposition.clientDescription(of: source) == expected)
        }
    }

    /// The running app's root over a bundle that ships a helper: a fixture with the helper's two
    /// files in place, so the arm a Full build takes runs without one. What it builds is read back
    /// by reflection, because the root keeps all of it `private` (#419).
    ///
    /// **Mutation (E7, "forRunningApp shares one client"):** in `forRunningApp`'s `connect`, build
    /// one `HelperClient` and pass it as both. Red at `read !== control`.
    /// **Mutation (E8):** pass `Bundle.main`'s embedding instead of `bundle`'s. Red at
    /// `hasLeaseControl`.
    @Test("The running app's root, over a bundle with a helper, builds the real pieces")
    func forRunningAppOverABundleWithAHelper() throws {
        let fixtures = BundleFixtures()
        defer { fixtures.remove() }
        let root = AppComposition.forRunningApp(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            bundle: try fixtures.bundle(version: "0.3.0", shipsHelper: true))

        #expect(root.hasLeaseControl)
        #expect(root.snapshots.authority() == .awaitHelper(.helperConnection(.idle)))
        let read = try #require(Reflection.value(of: root, at: "snapshots", "reading", "helper"))
        let control = try #require(
            Reflection.value(of: root, at: "lease", "lifecycle", "driver", "control"))
        let readClient = try #require(read as? HelperClient)
        let controlClient = try #require(control as? HelperClient)
        #expect(readClient !== controlClient, "one client would queue a snapshot behind an apply")
        let process = try #require(Reflection.value(of: root, at: "lease", "assertions", "process"))
        #expect((process as? ProcessInfo) === ProcessInfo.processInfo)
        let runLoop = Reflection.value(of: root, at: "lease", "lifecycle", "mainRunLoop")
        #expect(runLoop is MainRunLoop)
    }

    // MARK: - The App, the delegate, and the windows

    /// `running` is one root, `AeolusApp` holds it, and `AeolusApp` declares the delegate adaptor.
    ///
    /// **Mutation (E2, "the adaptor deleted"):** delete `@NSApplicationDelegateAdaptor` from
    /// `AeolusApp`. Red at the adaptor expectation.
    /// **Mutation (E3, "running built afresh"):** make `running` a computed property that builds a
    /// new root on each access. Red at both identity expectations.
    @Test("The running root is one root, and the App holds it beside its delegate adaptor")
    func theAppHoldsTheRunningRoot() {
        #expect(AppComposition.running === AppComposition.running)
        let children = Mirror(reflecting: AeolusApp()).children
        let composition = children.first { $0.label == "composition" }?.value as? AppComposition
        #expect(composition === AppComposition.running)
        let adaptor = children.first { $0.label == "_appDelegate" }?.value
        #expect(adaptor is NSApplicationDelegateAdaptor<AeolusAppDelegate>)
    }

    /// The delegate hands the quit to its root and passes AppKit's reply through, from the run
    /// loop. That the teardown is in the ledger once the hand-over is seen is a sample, not a
    /// pin. The order the quit keeps is held by
    /// `AppCompositionLeaseTests.quitRepliesOnlyAfterTheRelease`, which parks the release, and by
    /// `LeaseLifecycleTests.quitIsBounded`.
    ///
    /// **Mutation (E1, "the delegate bypasses the root"):** in
    /// `AeolusAppDelegate.applicationShouldTerminate(replyingTo:)`, return `.terminateNow`. Red at
    /// `== .terminateLater` and at the requirement that the reply was handed over.
    @Test("The delegate answers through the root, and the reply reaches the sender")
    func theDelegateAnswersThroughTheRoot() async throws {
        let scene = await CompositionScene(runLoop: .parked)
        _ = try #require(await scene.lease.take(LeaseScene.target([0: 3000])))
        let root = scene.root
        let delegate = AeolusAppDelegate(root: { root })
        let sender = RecordingReplier(scene.lease.recordReply)

        #expect(delegate.applicationShouldTerminate(replyingTo: sender) == .terminateLater)
        try #require(
            await SnapshotTestSupport.eventually { scene.runLoop.performed == 1 },
            "the reply was handed to the main run loop")
        // Read before the test delivers anything, so the test's delivery does not decide it. It
        // follows the poll above, so it is a sample.
        #expect(
            await scene.lease.entries.index(of: .disconnect) != nil,
            "the connection was not torn down by the time the hand-over was seen")
        scene.runLoop.runParked()
        await scene.lease.ledger.waitFor { !$0.terminationReplies.isEmpty }

        #expect(await scene.lease.entries.terminationReplies == [true])
        await scene.finish()
    }

    /// With no driver the delegate answers `.terminateNow` and replies to nothing. SwiftUI's own
    /// initialiser answers through `running`, which under the test runner has no helper.
    @Test("With no driver, the delegate terminates now, and so does the shipping one here")
    func theDelegateWithNoDriverTerminatesNow() async {
        let scene = await LeaseScene()
        let root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .absent, connect: { Self.doubles() },
            makeDriver: { LeaseDriver(control: $0, holderDescription: "unused") },
            workspaceNotifications: NotificationCenter(), process: FakeProcessLifetime(),
            mainRunLoop: TestMainRunLoop(.atOnce))
        let sender = RecordingReplier(scene.recordReply)

        #expect(
            AeolusAppDelegate(root: { root }).applicationShouldTerminate(replyingTo: sender)
                == .terminateNow)
        #expect(AeolusAppDelegate().applicationShouldTerminate(replyingTo: sender) == .terminateNow)
        let replied = await SnapshotTestSupport.eventually(turns: 2_000) {
            !(await scene.entries.terminationReplies.isEmpty)
        }
        #expect(!replied)
        await scene.finish()
    }

    /// Each window's root view reports its presence as its own kind, so the kind cannot be paired
    /// with the wrong window where the scene is declared. What no test here can see is the
    /// modifier itself being removed from a view's `body`, or its `onDisappear`: that needs a
    /// hosted window, which takes seconds a run here does not have (#493's review, probe B).
    ///
    /// **Mutation (E4):** make `MainView.window` `.settings`. Red here.
    @Test("Each window's root view is its own kind of window")
    func eachRootViewIsItsOwnKind() {
        #expect(MainView.window == .main)
        #expect(MainView.window.isControlWindow)
        #expect(PreferencesView.window == .settings)
        #expect(MenuBarContentView.window == .menuBarPanel)
    }

    // MARK: - Fixtures

    static let workspaceEvents = [
        NSWorkspace.willPowerOffNotification, NSWorkspace.didWakeNotification,
        NSWorkspace.sessionDidResignActiveNotification,
    ]

    /// Two doubles, for a factory a test counts the calls to.
    static func doubles() -> HelperConnections {
        let clock = HandWoundClock()
        return HelperConnections(
            read: FakeSnapshotHelper(),
            control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()))
    }
}

/// App bundles on disk, for the suite: a version, and optionally the helper's two files.
struct BundleFixtures {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("aeolus-composition-\(UUID().uuidString)")

    func bundle(version: String?, shipsHelper: Bool = false) throws -> Bundle {
        let url = root.appendingPathComponent("\(UUID().uuidString).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)"]
        if let version { info["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if shipsHelper {
            for file in [
                HelperBundleLayout.executableURL(inBundleAt: url),
                HelperBundleLayout.daemonPlistURL(inBundleAt: url),
            ] {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
        }
        return try #require(Bundle(url: url))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Reads a value a type keeps `private` by its stored property names, for a test that has to see
/// which object a composition wired where. Reflection only reads; it reaches nothing a view could.
enum Reflection {

    static func value(of subject: Any, at path: String...) -> Any? {
        var current = subject
        for label in path {
            guard
                let child = Mirror(reflecting: current).children.first(where: { $0.label == label })
            else { return nil }
            current = unwrapped(child.value)
        }
        return current
    }

    private static func unwrapped(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first else { return value }
        return unwrapped(wrapped.value)
    }
}
