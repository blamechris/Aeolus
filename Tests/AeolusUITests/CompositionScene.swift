import AeolusXPC
import AeolusXPCClient
import AppKit
import FanKit
import Foundation
import Testing
import os

@testable import AeolusLeaseControl
@testable import AeolusUI

/// An `AppComposition` built as a build with a helper builds it, over doubles: the read connection
/// is a `FakeSnapshotHelper`, the control connection is a `LeaseScene`'s `FakeLeaseHelper`, the
/// driver is that scene's, workspace events are posted to a centre of the test's own, the
/// process's counters are a `FakeProcessLifetime`, and a quit's reply comes through a
/// `TestMainRunLoop`.
///
/// The root keeps the driver `private`, as it must (#419), so the scene hands the root the driver
/// it already holds through `makeDriver`, and a test takes a lease on it directly.
@MainActor
struct CompositionScene {

    let lease: LeaseScene
    let reader: FakeSnapshotHelper
    let workspace: NotificationCenter
    let process: FakeProcessLifetime
    let runLoop: TestMainRunLoop
    let root: AppComposition

    init(
        releaseBound: Duration = LeaseDriver.releaseBound,
        runLoop: TestMainRunLoop.Mode = .atOnce
    ) async {
        let lease = await LeaseScene(releaseBound: releaseBound)
        let reader = FakeSnapshotHelper()
        let workspace = NotificationCenter()
        let process = FakeProcessLifetime()
        let mainRunLoop = TestMainRunLoop(runLoop)
        self.lease = lease
        self.reader = reader
        self.workspace = workspace
        self.process = process
        self.runLoop = mainRunLoop
        root = AppComposition(
            preferencesController: PreferencesController(store: InMemoryPreferencesStore()),
            embedding: .embedded,
            connect: { HelperConnections(read: reader, control: lease.helper) },
            makeDriver: { _ in lease.driver },
            workspaceNotifications: workspace,
            process: process,
            mainRunLoop: mainRunLoop)
    }

    /// Posts `name` to the root's workspace centre, as `NSWorkspace` would.
    func post(_ name: Notification.Name) {
        workspace.post(name: name, object: nil)
    }

    /// Runs `click`, which must start exactly one call on the driver through the root's entry
    /// points, and returns once the driver has run that call (`AppComposition.latestDriverCall`).
    ///
    /// **Why `LeaseScene.settle()` is not enough after a click (#500).** The click's call reaches
    /// the driver only once the main actor runs the task the root started for it. `settle()`'s
    /// round trips are on the fake, the driver and the ledger, never on the main actor, so a test
    /// can finish them, and act again, before that task has started. In release-config runs of
    /// `AeolusUITests`, `autoWhileReleasingCancelsAQueuedTake` answered its parked release before
    /// Auto's task had started, and went red in 7 of 10 runs before this wait.
    ///
    /// The wait is on the ledger, through `LeaseScene.run`, so a call that never finishes is a red
    /// at the suite's time limit rather than a `swift test` that never exits.
    ///
    /// **What no test here shows.** With `DriverCall.finished()` made to return at once
    /// (M500b), `AeolusUITests` stayed green in 10 of 10 release-config runs, and in 10 of 10
    /// more with the waits written out in the test. So the suite does not show that the wait on
    /// the call is needed, only that this helper is enough where `settle()` was not (M500a). Why
    /// M500b survives was not found. The wait is what makes the order certain: `finished()`
    /// returns only after the task's one step, the driver's verb, has returned.
    func click(_ click: () -> Void) async throws {
        let before = root.latestDriverCall?.ordinal ?? 0
        click()
        let call = try #require(root.latestDriverCall, "the click started a call on the driver")
        try #require(call.ordinal == before + 1, "the click started exactly one call")
        await lease.run { await call.finished() }
    }

    /// Ends everything the scene started, so nothing is left waiting on a fake.
    func finish() async {
        await reader.close()
        await lease.finish()
    }
}

/// The main run loop, for the suite: every `perform` is counted, and its block is either queued as
/// a main-actor task as it is handed over (`.atOnce`; it runs soon after, not inside `perform`) or
/// waits for `runParked()` (`.parked`), so a test can look at what had happened by the time the
/// reply was handed over, before it is delivered.
final class TestMainRunLoop: MainRunLoopPerforming {

    enum Mode: Sendable {
        case atOnce, parked
    }

    private struct State: Sendable {
        var performed = 0
        var parked: [@MainActor @Sendable () -> Void] = []
    }

    private let mode: Mode
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(_ mode: Mode) {
        self.mode = mode
    }

    /// How many blocks have been handed to `perform`.
    var performed: Int { state.withLock { $0.performed } }

    func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        switch mode {
        case .atOnce:
            state.withLock { $0.performed += 1 }
            Task { @MainActor in block() }
        case .parked:
            state.withLock {
                $0.performed += 1
                $0.parked.append(block)
            }
        }
    }

    /// Runs every parked block, in the order it was handed over.
    @MainActor
    func runParked() {
        let blocks = state.withLock { state -> [@MainActor @Sendable () -> Void] in
            defer { state.parked = [] }
            return state.parked
        }
        for block in blocks { block() }
    }
}

/// Whatever takes a quit's reply, for the suite: every reply, through `record`.
@MainActor
final class RecordingReplier: TerminationReplying {
    private let record: @MainActor @Sendable (Bool) -> Void

    init(_ record: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.record = record
    }

    func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        record(shouldTerminate)
    }
}

extension [LeaseLedger.Entry] {

    /// The quit replies, in order.
    var terminationReplies: [Bool] {
        compactMap {
            if case .terminationReplied(let terminate) = $0.event { terminate } else { nil }
        }
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
        case disableAutomatic(String)
        case enableAutomatic(String)
        case beginActivity(ProcessInfo.ActivityOptions.RawValue, String)
        case endActivity
    }

    private final class Activity: NSObject {}

    private(set) var calls: [Call] = []
    private(set) var suddenDisabled = 0
    private(set) var automaticDisabled = 0
    /// The deepest each counter, and the activities, ever went: more than one is a second disable
    /// or a second activity while the first was still in force.
    private(set) var deepest = (sudden: 0, automatic: 0, activities: 0)
    private var activities: [ObjectIdentifier: Activity] = [:]

    /// Activities begun and not yet ended.
    var openActivities: Int { activities.count }

    func disableSuddenTermination() {
        calls.append(.disableSudden)
        suddenDisabled += 1
        deepest.sudden = max(deepest.sudden, suddenDisabled)
    }

    func enableSuddenTermination() {
        calls.append(.enableSudden)
        suddenDisabled -= 1
        if suddenDisabled < 0 { Issue.record("sudden termination enabled more than disabled") }
    }

    func disableAutomaticTermination(_ reason: String) {
        calls.append(.disableAutomatic(reason))
        automaticDisabled += 1
        deepest.automatic = max(deepest.automatic, automaticDisabled)
    }

    func enableAutomaticTermination(_ reason: String) {
        calls.append(.enableAutomatic(reason))
        automaticDisabled -= 1
        if automaticDisabled < 0 {
            Issue.record("automatic termination enabled more than disabled")
        }
    }

    func beginActivity(
        options: ProcessInfo.ActivityOptions, reason: String
    ) -> any NSObjectProtocol {
        calls.append(.beginActivity(options.rawValue, reason))
        let activity = Activity()
        activities[ObjectIdentifier(activity)] = activity
        deepest.activities = max(deepest.activities, activities.count)
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
