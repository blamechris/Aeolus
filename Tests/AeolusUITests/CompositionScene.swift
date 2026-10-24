import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing

@testable import AeolusLeaseControl
@testable import AeolusUI

/// An `AppComposition` built as a build with a helper builds it, over doubles: the read connection
/// is a `FakeSnapshotHelper`, the control connection is a `LeaseScene`'s `FakeLeaseHelper`, the
/// driver is that scene's, workspace events are posted to a centre of the test's own, and the
/// process's counters are a `FakeProcessLifetime`.
///
/// The root keeps the driver `private`, as it must (#419), so the scene hands the root the driver it
/// already holds through `makeDriver`, and a test takes a lease on it directly.
@MainActor
struct CompositionScene {

    let lease: LeaseScene
    let reader: FakeSnapshotHelper
    let workspace: NotificationCenter
    let process: FakeProcessLifetime
    let root: AppComposition

    init(releaseBound: Duration = LeaseDriver.releaseBound) async {
        let lease = await LeaseScene(releaseBound: releaseBound)
        let reader = FakeSnapshotHelper()
        let workspace = NotificationCenter()
        let process = FakeProcessLifetime()
        self.lease = lease
        self.reader = reader
        self.workspace = workspace
        self.process = process
        root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .embedded,
            connect: { HelperConnections(read: reader, control: lease.helper) },
            makeDriver: { _ in lease.driver },
            workspaceNotifications: workspace,
            process: process)
    }

    /// Posts `name` to the root's workspace centre, as `NSWorkspace` would.
    func post(_ name: Notification.Name) {
        workspace.post(name: name, object: nil)
    }

    /// Ends everything the scene started, so nothing is left waiting on a fake.
    func finish() async {
        await reader.close()
        await lease.finish()
    }
}

/// A bounded wait for an actor-held condition, for a step a mutation can stop from happening, so
/// the mutation is a red at the next line rather than a minute's wait. Spends no wall-clock time
/// against a budget: it counts turns.
@MainActor
func becomes(turns: Int = 20_000, _ condition: () async -> Bool) async -> Bool {
    await SnapshotTestSupport.eventually(turns: turns, condition)
}

/// The quit replies one test received, counted on the main actor as `NSApplication` would get them.
@MainActor
final class ReplyCounter {
    private(set) var replies: [Bool] = []

    var reply: @MainActor @Sendable (Bool) -> Void {
        { [weak self] terminate in self?.replies.append(terminate) }
    }
}

/// `ProcessLifetimeControlling` for the suite: every call in order, and the depth of each counter.
///
/// A depth below zero is an enable with no disable before it, and is recorded as an issue the
/// moment it happens, as an unbalanced `ProcessInfo` call would be a defect the moment it was made.
@MainActor
final class FakeProcessLifetime: ProcessLifetimeControlling {

    enum Call: Equatable {
        case disableSudden, enableSudden
        case disableAutomatic(String), enableAutomatic(String)
        case beginActivity(ProcessInfo.ActivityOptions.RawValue, String)
        case endActivity
    }

    private final class Activity: NSObject {}

    private(set) var calls: [Call] = []
    private(set) var suddenDisabled = 0
    private(set) var automaticDisabled = 0
    private var activities: [ObjectIdentifier: Activity] = [:]

    /// Activities begun and not yet ended.
    var openActivities: Int { activities.count }

    func disableSuddenTermination() {
        calls.append(.disableSudden)
        suddenDisabled += 1
    }

    func enableSuddenTermination() {
        calls.append(.enableSudden)
        suddenDisabled -= 1
        if suddenDisabled < 0 { Issue.record("sudden termination enabled more than disabled") }
    }

    func disableAutomaticTermination(_ reason: String) {
        calls.append(.disableAutomatic(reason))
        automaticDisabled += 1
    }

    func enableAutomaticTermination(_ reason: String) {
        calls.append(.enableAutomatic(reason))
        automaticDisabled -= 1
        if automaticDisabled < 0 { Issue.record("automatic termination enabled more than disabled") }
    }

    func beginActivity(
        options: ProcessInfo.ActivityOptions, reason: String
    ) -> any NSObjectProtocol {
        calls.append(.beginActivity(options.rawValue, reason))
        let activity = Activity()
        activities[ObjectIdentifier(activity)] = activity
        return activity
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        calls.append(.endActivity)
        guard let activity = activity as? Activity,
            activities.removeValue(forKey: ObjectIdentifier(activity)) != nil
        else {
            Issue.record("ended an activity that was not open")
            return
        }
    }
}
