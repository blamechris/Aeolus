import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
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
            process: process)

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
            process: FakeProcessLifetime())

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
            process: FakeProcessLifetime())

        #expect(connected == 1)
        #expect(driven == 1)
        #expect(root.hasLeaseControl)
        #expect(root.snapshots.authority() == .awaitHelper(.helperConnection(.idle)))
    }

    // MARK: - Two connections

    /// The production connections are two `HelperClient` instances. Constructing them connects
    /// nothing: a client builds its connection when it first sends.
    ///
    /// **Mutation (C2):** in `HelperConnections.make`, build one `HelperClient` and pass it as both.
    /// Red at `!==`.
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeolus-composition-description-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func bundle(version: String?) throws -> Bundle {
            let url = root.appendingPathComponent("\(UUID().uuidString).bundle")
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.example.\(UUID().uuidString)"]
            if let version { info["CFBundleShortVersionString"] = version }
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return try #require(Bundle(url: url))
        }

        let cases: [(version: String?, expected: String)] = [
            ("0.3.0", "Aeolus.app 0.3.0"), ("", "Aeolus.app"), (nil, "Aeolus.app"),
        ]
        for (version, expected) in cases {
            let source = try bundle(version: version)
            let holder = AppComposition.holderDescription(of: source)
            #expect(holder == expected)
            #expect(holder == LeaseDriver.holderDescription(shortVersion: version))
            #expect(throws: Never.self) { try AeolusXPCValidation.validateHolderDescription(holder) }
            #expect(AppComposition.clientDescription(of: source) == expected)
        }
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
            read: FakeSnapshotHelper(), control: FakeLeaseHelper(clock: clock, ledger: LeaseLedger()))
    }
}
