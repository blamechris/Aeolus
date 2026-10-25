import AeolusLeaseControl
import Combine

/// The lease driver's state on the main actor, for views to read in `body` (#153's PR 6b).
///
/// `AppComposition` owns the app's one instance. In a build with a helper it follows
/// `LeaseDriver.stateUpdates()` from a task of its own, so a change of the driver's state with no
/// new snapshot still re-renders every view that reads it: a refused renewal turning `held` into
/// `lost` takes Custom off screen at once, rather than at the next snapshot, which can be a minute
/// away (`FanControlPresentation`'s contract: recompute whenever the driver's state changes as
/// well). In a build with no helper it is `.idle`, for good.
///
/// **Views read `current`; no view subscribes to the driver.** A view's `.task { for await … }`
/// would be a second reader per window, each started and cancelled by SwiftUI, and a view that
/// read `driver.state` once would keep that answer.
///
/// `current` is get-only and computed, over a `private` stored value, so its key path is a plain
/// `KeyPath`: no other file can write the state views are shown, by a dynamic cast or otherwise
/// (SR-5218, as `PollingViewModel.renderedSnapshot`).
@MainActor
final class LeaseStateModel: ObservableObject {

    private var stored: LeaseDriverState = .idle

    /// The driver's state, as last delivered to the main actor.
    var current: LeaseDriverState { stored }

    /// A build with no driver: `.idle`, and nothing ever changes it.
    init() {}

    /// Follows `states` from its first value, until this model goes.
    init(following states: AsyncStream<LeaseDriverState>) {
        Task { [weak self] in
            for await state in states {
                // Ends with this model: the driver's stream does not finish on its own.
                guard let self else { return }
                self.publish(state)
            }
        }
    }

    private func publish(_ state: LeaseDriverState) {
        guard state != stored else { return }
        objectWillChange.send()
        stored = state
    }
}
