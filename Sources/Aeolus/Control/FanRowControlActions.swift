import AeolusLeaseControl

/// What a fan row's per-fan control does when it is used: the only calls `FanListView` makes for a
/// row, each synchronous, each reaching one of the root's per-fan entry points (#154, #153's PR
/// 8b).
///
/// A value over the app's one root, as `AllFansControlActions` is, so the view holds no driver and
/// nothing `async`, and the root starts the driver's work on a task of its own (#419).
///
/// **Every call reads the screen again when it is made.** It holds nothing but the root: the fan's
/// inputs are read at the click, from what `polling` has on screen and the driver's report as the
/// window draws it (`FanRowControlPresentation.Inputs.onScreen(fan:in:driver:)`), never from what
/// was on screen when the row was last drawn. What to send is decided by the presentation's pure
/// functions, and when they name nothing, nothing is sent.
///
/// **A click selects nothing itself.** What is drawn as selected is whatever the driver and the
/// next snapshot then say.
@MainActor
struct FanRowControlActions {

    /// The root this control acts through.
    let composition: AppComposition

    /// The Custom segment: `takeFan` at the fan's default speed, or nothing
    /// (`FanRowControlPresentation.custom(_:)`).
    func chooseCustom(fan index: Int, on polling: PollingViewModel) {
        guard let inputs = inputs(fan: index, on: polling),
            let request = FanRowControlPresentation.custom(inputs)
        else { return }
        send(request)
    }

    /// Auto: this fan back to automatic control. Always safe, so never refused here, whatever the
    /// control's affordance says. Which driver verb that is, and how the request is recorded, is
    /// the root's to decide from the driver's report (`AppComposition.releaseFan(_:)`).
    func chooseAutomatic(fan index: Int) {
        composition.releaseFan(index)
    }

    /// Return in the field: `adjustFan` while the fan's `canRelease` is true, `takeFan` otherwise,
    /// or nothing (`FanRowControlPresentation.submit(_:_:)`).
    ///
    /// - Returns: What the field holds afterwards. The edit ends whatever was sent; a fan no longer
    ///   on screen sends nothing and keeps no draft.
    func submit(
        _ text: String, fan index: Int, on polling: PollingViewModel
    ) -> FanRowControlPresentation.FieldState {
        guard let inputs = inputs(fan: index, on: polling) else {
            return FanRowControlPresentation.FieldState()
        }
        let (request, field) = FanRowControlPresentation.submit(text, inputs)
        if let request { send(request) }
        return field
    }

    /// A stepper click: always `adjustFan`, or nothing (`FanRowControlPresentation.step`).
    func step(
        _ direction: FanRowControlPresentation.StepDirection,
        from field: FanRowControlPresentation.FieldState, fan index: Int,
        on polling: PollingViewModel
    ) {
        guard let inputs = inputs(fan: index, on: polling),
            let request = FanRowControlPresentation.step(direction, from: field, inputs)
        else { return }
        send(request)
    }

    private func inputs(
        fan index: Int, on polling: PollingViewModel
    ) -> FanRowControlPresentation.Inputs? {
        FanRowControlPresentation.Inputs.onScreen(
            fan: index, in: polling, driver: composition.leaseState.current)
    }

    /// The one place a request reaches the root.
    private func send(_ request: FanRowControlPresentation.Request) {
        switch request {
        case .takeFan(let index, let speed):
            composition.takeFan(index, at: speed)
        case .adjustFan(let index, let speed):
            composition.adjustFan(index, to: speed)
        }
    }
}
