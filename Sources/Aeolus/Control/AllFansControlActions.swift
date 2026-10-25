import AeolusLeaseControl

/// What the all-fans control does when it is clicked: the only calls `FanListView` makes, each
/// synchronous, each reaching one of the root's entry points (#153's PR 6b).
///
/// A value over the app's one root, so the view holds no driver and nothing `async`: every call
/// here returns at once, and the root starts the driver's work on a task of its own
/// (`AppComposition`, #419).
///
/// **A click selects nothing itself.** It asks the driver, and what is drawn as selected is
/// whatever the driver and the next snapshot then say (`AllFansControlPresentation`).
@MainActor
struct AllFansControlActions {

    /// The root this control acts through.
    let composition: AppComposition

    /// A percentage segment: **`take`**, the deliberate user action, whatever the driver holds. From
    /// `idle`, `released`, `refused` or `lost` it acquires; while the same fans are held it is a
    /// re-apply, so 50 % then 75 % is a second `take` (`LeaseDriver.take(_:)`). Never `adjust`,
    /// which acquires nothing and would leave a click from `idle` doing nothing.
    ///
    /// The target is built now, at the click, from one read of what `polling` has on screen and
    /// the driver's state as the window draws it: not from what was on screen when the control
    /// was last drawn. If it cannot be built for every fan, or any fan's control is not enabled
    /// now, **nothing is sent** (`AllFansControlPresentation.target(for:fans:snapshot:)`).
    func choose(_ percent: FanSpeedPercent, on polling: PollingViewModel) {
        let fans = FanControlPresentation.onScreen(
            in: polling, driver: composition.leaseState.current)
        guard
            let target = AllFansControlPresentation.target(
                for: percent, fans: fans, snapshot: polling.renderedSnapshot)
        else { return }
        composition.take(target)
    }

    /// Auto, and the release offer: the lease is released. Always safe, so it is never refused
    /// here, whatever the control's affordance says.
    func chooseAutomatic() {
        composition.selectAutomatic()
    }
}
