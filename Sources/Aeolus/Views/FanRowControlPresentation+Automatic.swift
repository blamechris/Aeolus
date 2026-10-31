import AeolusLeaseControl

// MARK: - Per-fan Auto, and how it is recorded (#509, #154's ruling Q5)

extension FanRowControlPresentation {

    /// What per-fan Auto asks the driver for, and how the root records the request.
    enum AutomaticRoute: Equatable {
        /// The report says which fans are in Custom and names none but this one:
        /// `selectAutomatic()`, recorded as the user's Auto
        /// (`LeaseStateModel.userAskedForAutomatic()`). With this fan the only one in Custom, that
        /// is the release `releaseFan(_:)` would end in. With none, it is what Auto for all fans
        /// does, and changes nothing.
        case selectAutomatic
        /// Other fans are still in Custom, or, while releasing, the report cannot say which are:
        /// `releaseFan(_:)`, recorded as a request for control (`userAskedForControl()`). The
        /// driver takes the other fans again, which is not the user choosing Auto, and where the
        /// report cannot say, the record fails safe: it never claims Auto as the user's choice.
        case releaseFan
    }

    /// Keyed on the fans the report names in Custom (`LeaseDriverState.fansInCustom`), never on
    /// any fan's `canRelease`: that is true for every fan while releasing, whatever the driver
    /// will acquire next, and it is read only for the fans on screen.
    static func automaticRoute(forFan index: Int, in state: LeaseDriverState) -> AutomaticRoute {
        guard let custom = state.fansInCustom else { return .releaseFan }
        return custom.allSatisfy { $0 == index } ? .selectAutomatic : .releaseFan
    }
}
