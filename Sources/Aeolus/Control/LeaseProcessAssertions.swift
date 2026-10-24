import AeolusLeaseControl
import Foundation

/// What the app asks of its own process while the lease is in play: `ProcessInfo`'s sudden and
/// automatic termination counters, and an activity that keeps App Nap away.
///
/// A seam so the suite can count the calls. The shipping conformance is `SystemProcessLifetime`,
/// which forwards each call to `ProcessInfo.processInfo` unchanged.
@MainActor
protocol ProcessLifetimeControlling: AnyObject {
    func disableSuddenTermination()
    func enableSuddenTermination()
    func disableAutomaticTermination(_ reason: String)
    func enableAutomaticTermination(_ reason: String)
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

/// The shipping conformance: `ProcessInfo.processInfo`, call for call.
@MainActor
final class SystemProcessLifetime: ProcessLifetimeControlling {

    func disableSuddenTermination() {
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func enableSuddenTermination() {
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    func disableAutomaticTermination(_ reason: String) {
        ProcessInfo.processInfo.disableAutomaticTermination(reason)
    }

    func enableAutomaticTermination(_ reason: String) {
        ProcessInfo.processInfo.enableAutomaticTermination(reason)
    }

    func beginActivity(
        options: ProcessInfo.ActivityOptions, reason: String
    ) -> any NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        ProcessInfo.processInfo.endActivity(activity)
    }
}

/// Keeps the process alive and awake for as long as the lease needs it, driven by
/// `LeaseDriver.stateUpdates()`.
///
/// ## Termination: while acquiring, held or releasing
///
/// Sudden termination lets the system end the app with `SIGKILL`, and no chance to run anything,
/// at logout among other times; automatic termination lets it end an app it judges idle without
/// the user asking. A lease ended by `SIGKILL` is ended by the helper's invalidation path, which
/// is the backstop and not the mechanism (#155): the explicit `releaseLease` never goes out. So
/// both are disabled from the moment a lease is asked for until the release has answered, and
/// enabled again once the state leaves those three cases.
///
/// ## App Nap: while held
///
/// A held lease is renewed every ten seconds (`LeaseDriver`), and App Nap can slow a hidden app's
/// timers. An activity with `.userInitiatedAllowingIdleSystemSleep` is held for as long as the
/// state is `held`, and ended when it leaves. That option still allows idle sleep, so it does not
/// keep the Mac awake. Whether renewals keep their pace while the app is hidden is a hardware row
/// on #153, not something the suite can show.
///
/// ## Balanced, because these are counters
///
/// `ProcessInfo` counts the termination calls process-wide, and an enable without its disable, or
/// a disable never enabled, outlives this type; an activity begun and never ended does too. So
/// each is called only on an edge: once when the state enters the set, once when it leaves. The
/// state can skip cases in between, so each edge is decided from the state alone, never from
/// which state came before it.
@MainActor
final class LeaseProcessAssertions {

    /// The reason given to `disableAutomaticTermination(_:)` and the activity, and the same string
    /// to the matching enable.
    static let reason = "Aeolus is holding, taking or giving back manual control of the fans"

    /// The activity's options: user-initiated work that lets the Mac sleep when idle.
    static let activityOptions: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    private let process: any ProcessLifetimeControlling
    private var terminationDisabled = false
    private var activity: (any NSObjectProtocol)?

    /// Starts watching `states`, from its first value.
    init(process: any ProcessLifetimeControlling, states: AsyncStream<LeaseDriverState>) {
        self.process = process
        Task { [weak self] in
            for await state in states {
                self?.apply(state)
            }
        }
    }

    /// Whether `state` must keep the process from being ended without warning.
    static func blocksTermination(_ state: LeaseDriverState) -> Bool {
        switch state {
        case .acquiring, .held, .releasing:
            return true
        case .idle, .released, .lost, .refused:
            return false
        }
    }

    /// Takes termination, then the activity; gives them back in the reverse order.
    private func apply(_ state: LeaseDriverState) {
        if !state.isHeld, let held = activity {
            activity = nil
            process.endActivity(held)
        }

        let blocks = Self.blocksTermination(state)
        if blocks, !terminationDisabled {
            terminationDisabled = true
            process.disableSuddenTermination()
            process.disableAutomaticTermination(Self.reason)
        } else if !blocks, terminationDisabled {
            terminationDisabled = false
            process.enableAutomaticTermination(Self.reason)
            process.enableSuddenTermination()
        }

        if state.isHeld, activity == nil {
            activity = process.beginActivity(options: Self.activityOptions, reason: Self.reason)
        }
    }
}
